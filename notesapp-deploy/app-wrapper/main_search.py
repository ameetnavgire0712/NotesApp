"""
Search Service Main - Lightweight FastAPI app for search endpoints.

This wrapper imports from the existing NotesApp but:
1. Only includes search-related routes
2. Uses Supabase logging instead of file logging
3. Uses Cloudflare Worker for embeddings/search/reranking
"""

import os
import sys
import logging
from contextlib import asynccontextmanager

# Add parent directory to path to import from existing app
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(__file__))))


# =============================================================================
# NOTE: No fake module injection needed!
# The real reranker.py now uses httpx + Jina API (no sentence-transformers)
# =============================================================================


# =============================================================================
# NOW SAFE TO IMPORT APP MODULES
# =============================================================================

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.core.config import get_settings
from app.core.middleware import RequestLoggingMiddleware
from app.core.exceptions import AppException, ErrorCode
from app.core.log_context import current_user_id, current_correlation_id

# Import existing routers (read-only/search routes)
from app.api.v1 import notes, search, chat, logs, dashboard, auth, mcp


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
    for noisy_logger in ['httpx', 'httpcore', 'hpack', 'azure', 'urllib3']:
        logging.getLogger(noisy_logger).setLevel(logging.WARNING)
    
    return logging.getLogger(__name__)


logger = setup_logging()


# =============================================================================
# SERVICE OVERRIDES - Use Worker instead of local models
# =============================================================================

def override_embeddings_service():
    """
    Override the embeddings service to use Cloudflare Worker.
    
    This injects our Worker-based service instead of loading sentence-transformers.
    """
    from services.worker_client import get_worker_client
    import app.services.embeddings as embeddings_module
    
    class WorkerEmbeddingsService:
        """Embeddings service that delegates to Cloudflare Worker."""
        
        def __init__(self):
            self.client = get_worker_client()
            self._model_name = "workers-ai/bge-base-en-v1.5"
        
        async def generate_embedding(self, text: str) -> list[float]:
            """Generate embedding using Worker's Workers AI."""
            from app.core.middleware import get_user_id
            import httpx
            
            # Include user_id from context for logging/tracing
            payload = {"text": text}
            user_id = get_user_id()
            if user_id:
                payload["user_id"] = user_id
            
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(
                    f"{self.client.worker_url}/embed",
                    headers={"Authorization": f"Bearer {self.client.worker_secret}"},
                    json=payload
                )
                response.raise_for_status()
                return response.json()["embedding"]
        
        async def generate_embeddings(self, texts: list[str]) -> list[list[float]]:
            """Generate embeddings for multiple texts."""
            from app.core.middleware import get_user_id
            import httpx
            
            # Include user_id from context for logging/tracing
            payload = {"texts": texts}
            user_id = get_user_id()
            if user_id:
                payload["user_id"] = user_id
            
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(
                    f"{self.client.worker_url}/embed-batch",
                    headers={"Authorization": f"Bearer {self.client.worker_secret}"},
                    json=payload
                )
                response.raise_for_status()
                return response.json()["embeddings"]
        
        @property
        def model_name(self) -> str:
            return self._model_name
    
    # Create singleton instance
    _worker_embeddings_service = None
    
    def get_worker_embeddings_service():
        nonlocal _worker_embeddings_service
        if _worker_embeddings_service is None:
            _worker_embeddings_service = WorkerEmbeddingsService()
        return _worker_embeddings_service
    
    # Override the module's getter
    embeddings_module.get_embeddings_service = get_worker_embeddings_service
    logger.info("✅ Embeddings service overridden to use Cloudflare Worker")


# =============================================================================
# LIFESPAN MANAGEMENT - Lightweight startup
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Lightweight startup - no ML model loading.
    Reranker fake module is already injected at module load time.
    """
    logger.info("Starting Search Service...")
    
    # Apply embeddings service override
    override_embeddings_service()
    
    # Note: reranker was already injected via _inject_fake_reranker() at module load
    logger.info("✅ Reranker service using Worker/Jina (injected at load time)")
    
    # Initialize Supabase logger (starts background flush task)
    supabase_logger = get_supabase_logger()
    await supabase_logger.start()
    logger.info("✅ Supabase logging initialized")
    
    # Verify Worker connectivity
    try:
        from services.worker_client import get_worker_client
        worker = get_worker_client()
        health = await worker.health_check()
        if health.get("status") == "healthy":
            logger.info("✅ Cloudflare Worker connected")
        else:
            logger.warning(f"⚠️ Worker health check: {health}")
    except Exception as e:
        logger.warning(f"⚠️ Worker connectivity check failed: {e}")
    
    # Warm up Supabase connection
    try:
        from app.services.notes_db import get_notes_db_service
        notes_db = get_notes_db_service()
        notes_db.client.table("notes").select("id").limit(1).execute()
        logger.info("✅ Supabase connection warmed up")
    except Exception as e:
        logger.warning(f"⚠️ Supabase warmup failed: {e}")
    
    # Initialize RAG agent (Groq client - lightweight)
    try:
        from app.services.rag_agent import get_rag_agent_service
        _ = get_rag_agent_service()
        logger.info("✅ RAG agent initialized")
    except Exception as e:
        logger.warning(f"⚠️ RAG agent init failed: {e}")
    
    # Warm up API key cache (pre-load all active keys to avoid cold-start auth latency)
    try:
        from app.services.auth_service import warm_api_key_cache, get_api_key_cache_stats
        loaded_count = await warm_api_key_cache()
        cache_stats = get_api_key_cache_stats()
        logger.info(f"✅ API key cache warmed: {cache_stats}")
    except Exception as e:
        logger.warning(f"⚠️ API key cache warmup failed: {e}")
    
    logger.info("✅ Search Service startup complete (no ML models loaded)")
    
    yield
    
    # Shutdown
    logger.info("Shutting down Search Service...")
    
    # Flush remaining logs
    await supabase_logger.stop()
    logger.info("✅ Search Service shutdown complete")


# =============================================================================
# APPLICATION SETUP
# =============================================================================

app = FastAPI(
    title="NotesApp Search Service",
    description="Lightweight search service - embeddings & reranking via Cloudflare Worker",
    version="0.2.0-search",
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
# ROUTERS - Search-related endpoints only
# =============================================================================

# Authentication
app.include_router(auth.router, prefix="/api/v1")

# Search & retrieval (read-only)
app.include_router(notes.router, prefix="/api/v1")   # /notes/search, /notes/{id}, etc.
app.include_router(search.router, prefix="/api/v1")  # Phase 2 RAG search
app.include_router(chat.router, prefix="/api/v1")    # LangGraph chat agent

# Monitoring (read-only)
app.include_router(logs.router, prefix="/api/v1")
app.include_router(dashboard.router, prefix="/api/v1")

# MCP (Model Context Protocol) - Remote server for Claude Desktop
app.include_router(mcp.router, prefix="/api/v1")


# =============================================================================
# HEALTH CHECK
# =============================================================================

@app.get("/health")
async def health_check():
    """Health check endpoint for Fly.io."""
    settings = get_settings()
    
    # Check Worker status
    worker_status = "unknown"
    try:
        from services.worker_client import get_worker_client
        worker = get_worker_client()
        health = await worker.health_check()
        worker_status = health.get("status", "unknown")
    except Exception as e:
        worker_status = f"error: {str(e)[:50]}"
    
    # Get machine info from environment
    machine_id = os.environ.get("FLY_MACHINE_ID", "local")
    region = os.environ.get("FLY_REGION", "local")
    
    return {
        "status": "healthy",
        "service": "search",
        "version": "0.2.0-search",
        "machine_id": machine_id,
        "region": region,
        "worker_status": worker_status,
        "features": {
            "embeddings": "cloudflare-worker",
            "reranking": "jina-via-worker",
            "vector_search": "cloudflare-vectorize"
        }
    }


@app.get("/")
async def root():
    """Root endpoint with service info."""
    return {
        "service": "NotesApp Search Service",
        "version": "0.2.0-search",
        "docs": "/docs",
        "health": "/health"
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
