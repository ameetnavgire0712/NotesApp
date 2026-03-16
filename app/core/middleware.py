"""
Request logging middleware for FastAPI.
Captures request/response metadata, generates correlation IDs,
and triggers activity logging.
"""
import time
import uuid
import logging
from typing import Callable, Optional
from contextvars import ContextVar
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response
from fastapi import FastAPI

# Context variable to store correlation ID across async contexts
correlation_id_ctx: ContextVar[Optional[str]] = ContextVar("correlation_id", default=None)
user_id_ctx: ContextVar[Optional[str]] = ContextVar("user_id", default=None)
request_context_ctx: ContextVar[Optional[dict]] = ContextVar("request_context", default=None)

logger = logging.getLogger(__name__)


def get_correlation_id() -> Optional[str]:
    """Get the current correlation ID from context."""
    return correlation_id_ctx.get()


def get_user_id() -> Optional[str]:
    """Get the current user ID from context."""
    return user_id_ctx.get()


def get_request_context() -> Optional[dict]:
    """Get the current request context."""
    return request_context_ctx.get()


def set_correlation_id(correlation_id: str) -> None:
    """Set the correlation ID in context."""
    correlation_id_ctx.set(correlation_id)


def set_user_id(user_id: str) -> None:
    """Set the user ID in context."""
    user_id_ctx.set(user_id)


# Context variable for client source
client_source_ctx: ContextVar[Optional[str]] = ContextVar("client_source", default=None)


def get_client_source() -> Optional[str]:
    """Get the current client source from context."""
    return client_source_ctx.get()


class RequestLoggingMiddleware(BaseHTTPMiddleware):
    """
    Middleware that sets up request context (correlation_id, user_id) for logging.
    
    Features:
    - Generates unique correlation_id for each request
    - Extracts user_id from headers or uses default
    - Detects client source (mcp_server, chrome_extension, website, api)
    - Measures request duration
    - Stores context for downstream logging via @log_activity decorators
    
    Note: Activity logging is handled by @log_activity decorators on endpoints,
    not by this middleware, to avoid duplicate log entries.
    """
    
    # Paths to exclude from processing (health checks, static files, etc.)
    EXCLUDED_PATHS = {"/health", "/favicon.ico", "/docs", "/openapi.json", "/redoc"}
    
    def __init__(self, app: FastAPI, default_user_id: str = "default_user"):
        super().__init__(app)
        self.default_user_id = default_user_id
    
    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        # Skip logging for excluded paths
        if request.url.path in self.EXCLUDED_PATHS:
            return await call_next(request)
        
        # Generate correlation ID
        correlation_id = request.headers.get("X-Correlation-ID") or str(uuid.uuid4())
        
        # Extract user ID from header or use default
        user_id = request.headers.get("X-User-ID") or self.default_user_id
        
        # Detect client source from headers
        client_source = self._detect_client_source(request)
        
        # Set context variables
        set_correlation_id(correlation_id)
        set_user_id(user_id)
        client_source_ctx.set(client_source)
        
        # Also set correlation_id in log context for file logging
        from app.core.log_context import current_correlation_id, request_start_time
        current_correlation_id.set(correlation_id)
        
        # Set request start time for accurate duration calculation in log_activity decorator
        request_start_time.set(time.time())
        
        # Build request context
        request_context = {
            "correlation_id": correlation_id,
            "user_id": user_id,
            "method": request.method,
            "path": request.url.path,
            "query_params": dict(request.query_params),
            "client_ip": self._get_client_ip(request),
            "user_agent": request.headers.get("User-Agent", ""),
            "client_source": client_source,
        }
        request_context_ctx.set(request_context)
        
        # Store in request state for access in endpoints
        request.state.correlation_id = correlation_id
        request.state.user_id = user_id
        request.state.client_source = client_source
        request.state.request_context = request_context
        
        # Record start time
        start_time = time.time()
        
        # Process request
        response = None
        error_occurred = False
        error_message = None
        
        try:
            response = await call_next(request)
        except Exception as e:
            error_occurred = True
            error_message = str(e)
            raise
        finally:
            # Calculate duration
            duration_ms = int((time.time() - start_time) * 1000)
            
            # Determine status
            if error_occurred:
                status_code = 500
                status = "error"
            elif response:
                status_code = response.status_code
                status = "error" if status_code >= 400 else "success"
            else:
                status_code = 500
                status = "error"
            
            # Add response info to context
            request_context["status_code"] = status_code
            request_context["duration_ms"] = duration_ms
            request_context["status"] = status
            
            # Note: Activity logging is handled by @log_activity decorators on endpoints
            # Middleware only sets up correlation context - no duplicate logging
            
            # Add correlation ID to response headers
            if response:
                response.headers["X-Correlation-ID"] = correlation_id
        
        return response
    
    def _get_client_ip(self, request: Request) -> str:
        """Extract client IP from request, handling proxies."""
        forwarded = request.headers.get("X-Forwarded-For")
        if forwarded:
            return forwarded.split(",")[0].strip()
        return request.client.host if request.client else "unknown"
    
    def _detect_client_source(self, request: Request) -> str:
        """
        Detect client source from request headers.
        
        Priority:
        1. X-Client-Source header (explicit)
        2. User-Agent detection (implicit)
        3. API Key presence (MCP/CLI)
        4. Default to 'unknown'
        """
        # Check explicit header first
        explicit_source = request.headers.get("X-Client-Source")
        if explicit_source:
            return explicit_source.lower()
        
        user_agent = request.headers.get("User-Agent", "").lower()
        
        # Detect from User-Agent
        if "notesapp-chrome" in user_agent or "chrome-extension" in user_agent:
            return "chrome_extension"
        if "notesapp-mcp" in user_agent or "mcp-server" in user_agent:
            return "mcp_server"
        if "curl" in user_agent or "httpie" in user_agent or "insomnia" in user_agent or "postman" in user_agent:
            return "api_client"
        
        # Check if using API key (typically MCP or CLI)
        if request.headers.get("X-API-Key"):
            return "api_key_client"
        
        # Check referer for website
        referer = request.headers.get("Referer", "")
        if referer:
            if "localhost" in referer or "127.0.0.1" in referer:
                return "website_local"
            if "vercel.app" in referer or "notesapp" in referer.lower():
                return "website"
        
        # Browser detection
        if "mozilla" in user_agent and ("chrome" in user_agent or "firefox" in user_agent or "safari" in user_agent):
            return "website"
        
        return "unknown"


class CorrelationIdFilter(logging.Filter):
    """
    Logging filter that adds correlation_id to log records.
    Use this with standard Python logging to include correlation IDs.
    """
    
    def filter(self, record: logging.LogRecord) -> bool:
        record.correlation_id = get_correlation_id() or "no-correlation-id"
        record.user_id = get_user_id() or "no-user-id"
        return True
