from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, HTMLResponse, FileResponse
from fastapi.staticfiles import StaticFiles
import logging
import os
import traceback

from app.core.config import get_settings
from app.core.middleware import RequestLoggingMiddleware
from app.core.exceptions import AppException, ErrorCode
from app.core.log_context import current_user_id, current_correlation_id  # Import from shared module
from app.api.v1 import upload, notes, logs, log_export, dashboard, admin, search, evaluation, auth, chat


class UserContextFormatter(logging.Formatter):
    """Custom formatter that adds user_id and correlation_id from context variables."""
    def format(self, record):
        # Add user_id to record if not present
        if not hasattr(record, 'user_id'):
            record.user_id = current_user_id.get()
        # Add correlation_id to record if not present
        if not hasattr(record, 'correlation_id'):
            record.correlation_id = current_correlation_id.get()
        return super().format(record)


# Configure logging - single centralized log file
LOG_FILE = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'notesapp.log')

# Create formatters - include correlation_id and user_id in logs
# Format: timestamp | level | correlation_id | user_id | service | file:line | function | message
console_format = '%(asctime)s | %(levelname)-5s | %(correlation_id)s | %(user_id)s | %(name)s | %(message)s'
file_format = '%(asctime)s | %(levelname)-5s | %(correlation_id)s | %(user_id)s | %(name)s | %(filename)s:%(lineno)d | %(funcName)s | %(message)s'

# Set up root logger
logging.basicConfig(level=logging.DEBUG)
root_logger = logging.getLogger()
root_logger.handlers.clear()

# Console handler (INFO level - less verbose)
console_handler = logging.StreamHandler()
console_handler.setLevel(logging.INFO)
console_handler.setFormatter(UserContextFormatter(console_format))
root_logger.addHandler(console_handler)

# Single centralized file handler (DEBUG level for app, WARNING for third-party)
file_handler = logging.FileHandler(LOG_FILE, encoding='utf-8')
file_handler.setLevel(logging.DEBUG)
file_handler.setFormatter(UserContextFormatter(file_format))
root_logger.addHandler(file_handler)

# Quiet noisy third-party loggers
for noisy_logger in ['httpx', 'httpcore', 'hpack', 'azure', 'urllib3', 'numexpr', 'sentence_transformers']:
    logging.getLogger(noisy_logger).setLevel(logging.WARNING)

logger = logging.getLogger(__name__)

# =============================================================================
# LIFESPAN MANAGEMENT - Startup and Shutdown
# =============================================================================
@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Manage application lifecycle - initialize and cleanup logging service.
    """
    # Startup
    logger.info("Starting up NotesApp...")
    
    # Initialize the logging service (starts background flush task)
    try:
        from app.services.logging_service import init_logging_service
        await init_logging_service()
        logger.info("✅ Logging service initialized")
    except Exception as e:
        logger.error(f"⚠️ Failed to initialize logging service: {e}")
    
    # Eagerly load services and models to warm up caches
    # This ensures first request is fast (no cold start penalty)
    try:
        logger.info("🔥 Warming up services...")
        
        # 1. Load embedding model (takes 2-3 seconds on first load)
        from app.services.local_embeddings import get_local_embeddings_service
        embeddings_service = get_local_embeddings_service()
        # Trigger model loading by generating a test embedding
        await embeddings_service.generate_embedding("warmup")
        logger.info("✅ Embedding model loaded")
        
        # 2. Initialize retrieval tools (database connections)
        from app.services.retrieval_tools import get_retrieval_tools_service
        retrieval_tools = get_retrieval_tools_service()
        logger.info("✅ Retrieval tools initialized")
        
        # 2.5. Warm up Supabase connection with a simple query
        # This establishes the connection pool, avoiding cold start on first request
        try:
            from app.services.notes_db import get_notes_db_service
            notes_db = get_notes_db_service()
            # Simple query to warm up connection
            notes_db.client.table("notes").select("id").limit(1).execute()
            logger.info("✅ Supabase connection warmed up")
        except Exception as e:
            logger.warning(f"⚠️ Supabase warmup failed: {e}")
        
        # 3. Initialize RAG agent (Groq client)
        from app.services.rag_agent import get_rag_agent_service
        _ = get_rag_agent_service()
        logger.info("✅ RAG agent initialized")
        
        # 4. Load reranker model (takes 4-5 seconds on first load)
        from app.services.reranker import get_reranker_service
        _ = get_reranker_service()
        logger.info("✅ Reranker model loaded")
        
        # 5. Initialize semantic chunker (Docling - optional, may not be installed)
        try:
            from app.services.semantic_chunker import warmup_semantic_chunker
            is_available = await warmup_semantic_chunker()
            if is_available:
                logger.info("✅ Semantic chunker (Docling) loaded")
            else:
                logger.info("ℹ️ Semantic chunker not available (Docling not installed)")
        except Exception as e:
            logger.warning(f"⚠️ Semantic chunker warmup failed: {e}")
        
        # 6. Verify Vectorize Worker connectivity
        try:
            from app.services.vectorize_worker_service import get_vectorize_worker_service
            worker_service = get_vectorize_worker_service()
            health = await worker_service.health_check()
            if health.get("status") == "healthy":
                logger.info("✅ Vectorize Worker connected")
            else:
                logger.warning(f"⚠️ Vectorize Worker unhealthy: {health}")
        except Exception as e:
            logger.warning(f"⚠️ Vectorize Worker check failed: {e}")
        
        # 7. Warm up API key cache (pre-load all active keys to avoid cold-start auth latency)
        try:
            from app.services.auth_service import warm_api_key_cache, get_api_key_cache_stats
            loaded_count = await warm_api_key_cache()
            cache_stats = get_api_key_cache_stats()
            logger.info(f"✅ API key cache warmed: {cache_stats}")
        except Exception as e:
            logger.warning(f"⚠️ API key cache warmup failed: {e}")
        
        # 8. Initialize scheduled tasks (log exports, etc.)
        try:
            from app.services.scheduled_tasks import task_manager
            await task_manager.start_scheduler()
            await task_manager.add_daily_log_export()
            logger.info("✅ Scheduled tasks initialized")
        except Exception as e:
            logger.warning(f"⚠️ Scheduled tasks initialization failed: {e}")
        
        logger.info("🔥 All services warmed up and ready!")
    except Exception as e:
        logger.warning(f"⚠️ Service warmup failed (will load on first request): {e}")
    
    # Log startup
    logging.info(f"Logging initialized. Log file: {LOG_FILE}")
    logger.info("✅ NotesApp startup complete")
    
    yield
    
    # Shutdown
    logger.info("Shutting down NotesApp...")
    
    # Shutdown scheduled tasks
    try:
        from app.services.scheduled_tasks import task_manager
        await task_manager.stop_scheduler()
        logger.info("✅ Scheduled tasks shutdown")
    except Exception as e:
        logger.error(f"⚠️ Error during scheduled tasks shutdown: {e}")
    
    # Shutdown logging service (flushes remaining logs)
    try:
        from app.services.logging_service import shutdown_logging_service
        await shutdown_logging_service()
        logger.info("✅ Logging service shutdown complete")
    except Exception as e:
        logger.error(f"⚠️ Error during logging service shutdown: {e}")
    
    logger.info("✅ NotesApp shutdown complete")


app = FastAPI(
    title="Notes App API",
    description="AI-powered notes storage and retrieval with comprehensive logging",
    version="0.2.0",
    lifespan=lifespan
)


# =============================================================================
# MIDDLEWARE - Order matters! Last added = first executed
# =============================================================================

# Request logging middleware (adds correlation ID, logs request/response)
app.add_middleware(RequestLoggingMiddleware)

# CORS middleware - Configure origins for production security
# In production, set CORS_ORIGINS env var to comma-separated list of allowed origins
# e.g., CORS_ORIGINS="https://secondbrain.pages.dev,https://app.secondbrain.com"
settings = get_settings()
cors_origins = settings.cors_origins
if cors_origins == "*":
    # Development mode - allow all origins
    allowed_origins = ["*"]
else:
    # Production mode - parse comma-separated origins
    allowed_origins = [origin.strip() for origin in cors_origins.split(",") if origin.strip()]
    
app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["X-Correlation-ID"],  # Expose correlation ID for debugging
)


# =============================================================================
# EXCEPTION HANDLERS - Global error handling
# =============================================================================

@app.exception_handler(AppException)
async def app_exception_handler(request: Request, exc: AppException):
    """
    Handle custom application exceptions with structured error logging.
    """
    from app.core.middleware import get_correlation_id, get_user_id
    
    # Log the error
    try:
        from app.services.logging_service import get_logging_service
        logging_service = get_logging_service()
        if logging_service:
            await logging_service.log_error(
                error_code=exc.error_code.value,
                error_type=type(exc).__name__,
                message=exc.message,
                stack_trace=exc.original_error and traceback.format_exception(
                    type(exc.original_error), exc.original_error, exc.original_error.__traceback__
                ),
                context=exc.context
            )
    except Exception as e:
        logger.error(f"Failed to log error: {e}")
    
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
    """
    Handle unexpected exceptions with full error logging.
    """
    from app.core.middleware import get_correlation_id
    
    # Log the unhandled error
    try:
        from app.services.logging_service import get_logging_service
        logging_service = get_logging_service()
        if logging_service:
            await logging_service.log_error(
                error_code=ErrorCode.UNEXPECTED_ERROR.value,
                error_type=type(exc).__name__,
                message=str(exc),
                stack_trace="".join(traceback.format_exception(type(exc), exc, exc.__traceback__)),
                context={
                    "path": str(request.url.path),
                    "method": request.method
                }
            )
    except Exception as e:
        logger.error(f"Failed to log unhandled error: {e}")
    
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
# ROUTERS - API Endpoints
# =============================================================================

# Authentication (must come before protected routes)
app.include_router(auth.router, prefix="/api/v1")

# Core functionality
app.include_router(upload.router, prefix="/api/v1")
app.include_router(notes.router, prefix="/api/v1")
app.include_router(search.router, prefix="/api/v1")  # Phase 2 RAG search
app.include_router(chat.router, prefix="/api/v1")  # LangGraph chat agent

# Logging & Monitoring
app.include_router(logs.router, prefix="/api/v1")
app.include_router(log_export.router, prefix="/api/v1")
app.include_router(dashboard.router, prefix="/api/v1")
app.include_router(admin.router, prefix="/api/v1")

# RAG Evaluation (RAGAS)
app.include_router(evaluation.router, prefix="/api/v1")


@app.get("/health")
async def health_check():
    """Health check endpoint with logging service status"""
    settings = get_settings()
    
    # Check logging service status
    logging_status = "unknown"
    try:
        from app.services.logging_service import get_logging_service
        logging_service = get_logging_service()
        if logging_service:
            # Count entries in all buffers
            activity_count = sum(len(v) for v in logging_service.activity_buffer._buffers.values())
            operation_count = sum(len(v) for v in logging_service.operation_buffer._buffers.values())
            error_count = sum(len(v) for v in logging_service.error_buffer._buffers.values())
            buffer_size = activity_count + operation_count + error_count
            logging_status = f"active (buffer: {buffer_size})"
        else:
            logging_status = "not initialized"
    except Exception as e:
        logging_status = f"error: {str(e)}"
    
    return {
        "status": "healthy",
        "version": "0.2.0",
        "services": {
            "azure_blob": "configured" if settings.azure_storage_connection_string else "missing",
            "supabase": "configured" if settings.supabase_url else "missing",
            "tensorlake": "configured" if settings.tensorlake_api_key else "missing",
            "openai": "configured" if settings.openai_api_key else "missing",
            "logging": logging_status
        }
    }


@app.get("/api")
async def api_info():
    """API information endpoint."""
    return {
        "message": "Notes App API",
        "docs": "/docs",
        "auth_test": "/test-auth",
        "endpoints": {
            "upload_file": "POST /api/v1/upload/file",
            "upload_screenshot": "POST /api/v1/upload/screenshot",
            "create_quick_note": "POST /api/v1/upload/quick-note",
            "search_notes": "POST /api/v1/notes/search",
            "list_notes": "GET /api/v1/notes/",
            "get_note": "GET /api/v1/notes/{note_id}",
            "delete_note": "DELETE /api/v1/notes/{note_id}",
            "logs": "GET /api/v1/logs/*",
            "dashboard": "GET /api/v1/dashboard/*",
            "admin": "POST /api/v1/admin/*"
        }
    }


@app.get("/test-auth", response_class=HTMLResponse)
async def serve_auth_test():
    """Serve the authentication test page."""
    import os
    html_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "test_auth.html")
    with open(html_path, "r", encoding="utf-8") as f:
        return f.read()


# =============================================================================
# STATIC FILES - Frontend serving
# =============================================================================

# Get the frontend directory path
FRONTEND_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "frontend")

# Serve dashboard.html
@app.get("/dashboard.html", response_class=HTMLResponse)
@app.get("/dashboard", response_class=HTMLResponse)
async def serve_dashboard():
    """Serve the dashboard page."""
    html_path = os.path.join(FRONTEND_DIR, "dashboard.html")
    with open(html_path, "r", encoding="utf-8") as f:
        return f.read()

# Serve index.html at root (landing page with auth)
@app.get("/", response_class=HTMLResponse)
async def serve_index():
    """Serve the landing page."""
    html_path = os.path.join(FRONTEND_DIR, "index.html")
    with open(html_path, "r", encoding="utf-8") as f:
        return f.read()

# Mount static files (CSS, JS) - must be after specific routes
app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")

# Log viewer page
@app.get("/logs", response_class=HTMLResponse)
async def serve_log_viewer():
    """Serve the log viewer HTML page."""
    html_path = os.path.join(FRONTEND_DIR, "log-viewer.html")
    if not os.path.exists(html_path):
        return HTMLResponse(content="<h1>Log viewer not found</h1>", status_code=404)
    return FileResponse(html_path, media_type="text/html")

# Also serve JS and CSS files directly from root
@app.get("/auth.js")
async def serve_auth_js():
    return FileResponse(os.path.join(FRONTEND_DIR, "auth.js"), media_type="application/javascript")

@app.get("/dashboard.js")
async def serve_dashboard_js():
    return FileResponse(os.path.join(FRONTEND_DIR, "dashboard.js"), media_type="application/javascript")

@app.get("/dashboard-chat.js")
async def serve_dashboard_chat_js():
    return FileResponse(os.path.join(FRONTEND_DIR, "dashboard-chat.js"), media_type="application/javascript")

@app.get("/styles.css")
async def serve_styles_css():
    return FileResponse(os.path.join(FRONTEND_DIR, "styles.css"), media_type="text/css")

@app.get("/dashboard-styles.css")
async def serve_dashboard_styles_css():
    return FileResponse(os.path.join(FRONTEND_DIR, "dashboard-styles.css"), media_type="text/css")
