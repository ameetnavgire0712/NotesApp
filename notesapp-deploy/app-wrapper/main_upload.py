"""
Upload Service Main - Full FastAPI app for upload endpoints.

This wrapper imports from the existing NotesApp but:
1. Only includes upload-related routes
2. Uses Supabase logging instead of file logging
3. KEEPS local ML models for document embedding (not query embedding)
4. Syncs vectors to Cloudflare Vectorize after upload
"""

import os
import sys
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

# Add parent directory to path to import from existing app
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(__file__))))

from app.core.config import get_settings
from app.core.middleware import RequestLoggingMiddleware
from app.core.exceptions import AppException, ErrorCode
from app.core.log_context import current_user_id, current_correlation_id

# Import existing routers (upload/mutation routes)
from app.api.v1 import upload, notes, admin, auth, logs


# =============================================================================
# LOGGING SETUP - Supabase-based logging for distributed environment
# =============================================================================

from services.supabase_logger import SupabaseLogHandler, get_supabase_logger
from datetime import datetime, timezone, timedelta

# IST timezone (UTC+5:30)
IST = timezone(timedelta(hours=5, minutes=30))

class UserContextFormatter(logging.Formatter):
    """Custom formatter that adds user_id and correlation_id from context variables."""
    
    def formatTime(self, record, datefmt=None):
        """Override to use IST timezone instead of local/UTC."""
        ct = datetime.fromtimestamp(record.created, tz=IST)
        if datefmt:
            return ct.strftime(datefmt)
        return ct.strftime('%Y-%m-%d %H:%M:%S,%f')[:-3]  # Match default format
    
    def format(self, record):
        if not hasattr(record, 'user_id'):
            record.user_id = current_user_id.get()
        if not hasattr(record, 'correlation_id'):
            record.correlation_id = current_correlation_id.get()
        return super().format(record)


def setup_logging():
    """Configure logging with Supabase handler for distributed logging."""
    # Format matches existing notesapp.log format
    log_format = '%(asctime)s | %(levelname)-5s | %(correlation_id)s | %(user_id)s | %(name)s | %(filename)s:%(lineno)d | %(funcName)s | %(message)s'
    
    # Set up root logger
    logging.basicConfig(level=logging.DEBUG)
    root_logger = logging.getLogger()
    root_logger.handlers.clear()
    
    # Console handler (INFO level)
    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.INFO)
    console_handler.setFormatter(UserContextFormatter(log_format))
    root_logger.addHandler(console_handler)
    
    # Supabase handler (DEBUG level for app logs)
    supabase_handler = SupabaseLogHandler()
    supabase_handler.setLevel(logging.DEBUG)
    supabase_handler.setFormatter(UserContextFormatter(log_format))
    root_logger.addHandler(supabase_handler)
    
    # Quiet noisy third-party loggers
    for noisy_logger in ['httpx', 'httpcore', 'hpack', 'azure', 'urllib3', 'numexpr', 'sentence_transformers']:
        logging.getLogger(noisy_logger).setLevel(logging.WARNING)
    
    return logging.getLogger(__name__)


logger = setup_logging()


# =============================================================================
# VECTORIZE SYNC HOOK - Sync embeddings to Cloudflare after upload
# =============================================================================

async def sync_vectors_to_cloudflare(note_id: str, chunks: list[dict]):
    """
    Sync note/chunk embeddings to Cloudflare Vectorize after upload.
    
    Called as a post-upload hook to ensure vectors are in both:
    - Supabase (primary storage)
    - Cloudflare Vectorize (edge search)
    """
    try:
        from services.worker_client import get_worker_client
        
        worker = get_worker_client()
        
        # Prepare vectors for upsert
        vectors = []
        for chunk in chunks:
            vectors.append({
                "id": chunk.get("chunk_id", chunk.get("id")),
                "values": chunk["embedding"],
                "metadata": {
                    "note_id": note_id,
                    "user_id": chunk.get("user_id"),
                    "chunk_index": chunk.get("chunk_index", 0),
                    "content_preview": chunk.get("content", "")[:200]
                }
            })
        
        # Upsert to Vectorize
        result = await worker.upsert_vectors(vectors, namespace=f"user-{chunks[0].get('user_id', 'default')}")
        logger.info(f"✅ Synced {len(vectors)} vectors to Vectorize for note {note_id[:8]}...")
        
        return result
    except Exception as e:
        # Don't fail upload if Vectorize sync fails - it's secondary storage
        logger.warning(f"⚠️ Failed to sync vectors to Cloudflare: {e}")
        return None


# =============================================================================
# LIFESPAN MANAGEMENT - Full startup with ML models
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Full startup including ML model loading.
    
    Upload service needs:
    - Embedding model (for document/chunk embeddings)
    - Semantic chunker (for document processing)
    - TensorLake (for PDF/document conversion)
    """
    logger.info("Starting Upload Service...")
    
    # Initialize Supabase logger (starts background flush task)
    supabase_logger = get_supabase_logger()
    await supabase_logger.start()
    logger.info("✅ Supabase logging initialized")
    
    # Warmup services
    try:
        logger.info("🔥 Warming up services...")
        
        # 1. Load embedding service (Worker or local)
        from app.services.embeddings import get_embeddings_service
        embeddings_service = get_embeddings_service()
        await embeddings_service.generate_embedding("warmup")
        logger.info("✅ Embedding service ready")
        
        # 2. Initialize semantic chunker (Docling)
        try:
            from app.services.semantic_chunker import warmup_semantic_chunker
            is_available = await warmup_semantic_chunker()
            if is_available:
                logger.info("✅ Semantic chunker (Docling) loaded")
            else:
                logger.info("ℹ️ Semantic chunker not available")
        except Exception as e:
            logger.warning(f"⚠️ Semantic chunker warmup failed: {e}")
        
        # 3. Verify TensorLake connectivity
        try:
            from app.services.tensorlake import get_tensorlake_service
            tensorlake = get_tensorlake_service()
            logger.info("✅ TensorLake service initialized")
        except Exception as e:
            logger.warning(f"⚠️ TensorLake init failed: {e}")
        
        # 4. Warm up Supabase connection
        try:
            from app.services.notes_db import get_notes_db_service
            notes_db = get_notes_db_service()
            notes_db.client.table("notes").select("id").limit(1).execute()
            logger.info("✅ Supabase connection warmed up")
        except Exception as e:
            logger.warning(f"⚠️ Supabase warmup failed: {e}")
        
        # 5. Verify Worker connectivity (for vector sync)
        try:
            from services.worker_client import get_worker_client
            worker = get_worker_client()
            health = await worker.health_check()
            if health.get("status") == "healthy":
                logger.info("✅ Cloudflare Worker connected")
            else:
                logger.warning(f"⚠️ Worker health: {health}")
        except Exception as e:
            logger.warning(f"⚠️ Worker connectivity check failed: {e}")
        
        logger.info("🔥 All services warmed up and ready!")
        
    except Exception as e:
        logger.warning(f"⚠️ Service warmup failed: {e}")
    
    logger.info("✅ Upload Service startup complete")
    
    yield
    
    # Shutdown
    logger.info("Shutting down Upload Service...")
    
    # Flush remaining logs
    await supabase_logger.stop()
    logger.info("✅ Upload Service shutdown complete")


# =============================================================================
# APPLICATION SETUP
# =============================================================================

app = FastAPI(
    title="NotesApp Upload Service",
    description="Full upload service with local ML models for document processing",
    version="0.2.0-upload",
    lifespan=lifespan
)

# Middleware
app.add_middleware(RequestLoggingMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# =============================================================================
# EXCEPTION HANDLERS
# =============================================================================

@app.exception_handler(AppException)
async def app_exception_handler(request: Request, exc: AppException):
    """Handle custom application exceptions."""
    from app.core.middleware import get_correlation_id
    
    logger.error(f"AppException: {exc.error_code.value} - {exc.message}")
    
    return JSONResponse(
        status_code=exc.http_status,
        content={
            "error": True,
            "error_code": exc.error_code.value,
            "message": exc.message,
            "details": exc.context if exc.context else None,
            "correlation_id": str(get_correlation_id()) if get_correlation_id() else None
        }
    )


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    """Handle unexpected exceptions."""
    from app.core.middleware import get_correlation_id
    
    logger.exception(f"Unhandled exception: {exc}")
    
    return JSONResponse(
        status_code=500,
        content={
            "error": True,
            "error_code": ErrorCode.UNEXPECTED_ERROR.value,
            "message": "An unexpected error occurred",
            "correlation_id": str(get_correlation_id()) if get_correlation_id() else None
        }
    )


# =============================================================================
# ROUTERS - Upload-related endpoints
# =============================================================================

# Authentication
app.include_router(auth.router, prefix="/api/v1")

# Upload operations (write)
app.include_router(upload.router, prefix="/api/v1")

# Notes mutations (create, update, delete)
# We need a custom router that only exposes mutation endpoints
from fastapi import APIRouter
notes_mutations_router = APIRouter(prefix="/notes", tags=["Notes Mutations"])

# Import specific mutation endpoints from notes router
# The notes.router includes both read and write - we'll include full router
# but Search Service will be primary for reads
app.include_router(notes.router, prefix="/api/v1")

# Admin operations
app.include_router(admin.router, prefix="/api/v1")

# Logs (for debugging uploads)
app.include_router(logs.router, prefix="/api/v1")


# =============================================================================
# HEALTH CHECK
# =============================================================================

@app.get("/health")
async def health_check():
    """Health check endpoint for Fly.io."""
    settings = get_settings()
    
    # Check embedding service (Worker or local)
    embeddings_status = "unknown"
    try:
        from app.services.embeddings import get_embeddings_service
        embeddings = get_embeddings_service()
        embeddings_status = "worker" if hasattr(embeddings, 'worker_url') else "local"
    except Exception as e:
        embeddings_status = f"error: {str(e)[:50]}"
    
    # Check Worker status
    worker_status = "unknown"
    try:
        from services.worker_client import get_worker_client
        worker = get_worker_client()
        health = await worker.health_check()
        worker_status = health.get("status", "unknown")
    except Exception as e:
        worker_status = f"error: {str(e)[:50]}"
    
    # Get machine info
    machine_id = os.environ.get("FLY_MACHINE_ID", "local")
    region = os.environ.get("FLY_REGION", "local")
    
    return {
        "status": "healthy",
        "service": "upload",
        "version": "0.2.0-upload",
        "machine_id": machine_id,
        "region": region,
        "embeddings_status": embeddings_status,
        "worker_status": worker_status,
        "features": {
            "embeddings": "local-bge-base-en-v1.5",
            "chunking": "docling-semantic",
            "vectorize_sync": "enabled"
        }
    }


@app.get("/")
async def root():
    """Root endpoint with service info."""
    return {
        "service": "NotesApp Upload Service",
        "version": "0.2.0-upload",
        "docs": "/docs",
        "health": "/health"
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
