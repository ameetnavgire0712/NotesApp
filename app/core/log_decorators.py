"""
Logging decorators for automatic activity and operation logging.
Provides @log_activity for API endpoints and @log_operation for service methods.
"""
import time
import functools
import logging
import traceback
from typing import Callable, Optional, Any, Dict
from uuid import UUID

from app.core.middleware import get_correlation_id, get_user_id, get_client_source
from app.core.log_context import request_start_time

logger = logging.getLogger(__name__)


def _get_logging_service():
    """Lazy load logging service to avoid circular imports."""
    try:
        from app.services.logging_service import get_logging_service
        return get_logging_service()
    except Exception as e:
        logger.warning(f"Failed to get logging service: {e}")
        return None


def _extract_authenticated_user_id(args, kwargs) -> str:
    """
    Extract the authenticated user_id from endpoint parameters.
    
    Looks for:
    1. 'current_user' in kwargs (FastAPI Depends injection)
    2. AuthenticatedUser objects in args/kwargs
    3. Falls back to middleware context
    """
    # Check kwargs for current_user (most common pattern)
    current_user = kwargs.get('current_user')
    if current_user and hasattr(current_user, 'user_id'):
        return current_user.user_id
    
    # Check all kwargs for any object with user_id
    for key, value in kwargs.items():
        if hasattr(value, 'user_id') and value.user_id:
            return value.user_id
    
    # Check args for AuthenticatedUser-like objects
    for arg in args:
        if hasattr(arg, 'user_id') and arg.user_id:
            return arg.user_id
    
    # Fall back to middleware context
    return get_user_id() or "unknown"


def log_activity(
    action: str,
    resource_type: Optional[str] = None,
    extract_resource_id: Optional[Callable[[Any], str]] = None,
    extract_metadata: Optional[Callable[[Any, Any], Dict[str, Any]]] = None
):
    """
    Decorator for logging user activities on API endpoints.
    
    Args:
        action: The action being performed (e.g., 'upload_file', 'search_notes')
        resource_type: Type of resource being acted upon (e.g., 'note', 'file')
        extract_resource_id: Function to extract resource ID from result
        extract_metadata: Function to extract additional metadata from (args, result)
    
    Example:
        @router.post("/upload")
        @log_activity(
            action="upload_file",
            resource_type="file",
            extract_resource_id=lambda r: r.note_id,
            extract_metadata=lambda args, r: {"chunks": r.chunks_created}
        )
        async def upload_file(file: UploadFile):
            ...
    """
    def decorator(func: Callable):
        @functools.wraps(func)
        async def async_wrapper(*args, **kwargs):
            # Use request start time from middleware for total duration (includes auth)
            # Fall back to local start time if middleware didn't set it
            middleware_start = request_start_time.get()
            local_start_time = time.time()
            
            result = None
            status = "success"
            error_info = None
            
            try:
                result = await func(*args, **kwargs)
                return result
            except Exception as e:
                status = "error"
                error_info = {
                    "error_type": type(e).__name__,
                    "error_message": str(e)
                }
                raise
            finally:
                # Calculate duration from middleware start (total request time) or local start
                start_time = middleware_start if middleware_start else local_start_time
                duration_ms = int((time.time() - start_time) * 1000)
                
                # Build metadata
                metadata = {}
                if extract_metadata and result:
                    try:
                        metadata = extract_metadata(kwargs, result) or {}
                    except Exception:
                        pass
                
                if error_info:
                    metadata.update(error_info)
                
                # Extract resource ID
                resource_id = None
                if extract_resource_id and result:
                    try:
                        rid = extract_resource_id(result)
                        if rid:
                            resource_id = UUID(rid) if isinstance(rid, str) else rid
                    except Exception:
                        pass
                
                # Log the activity
                try:
                    logging_service = _get_logging_service()
                    if logging_service:
                        # Extract authenticated user_id from endpoint params
                        user_id = _extract_authenticated_user_id(args, kwargs)
                        
                        # Add client_source to metadata if available
                        client_source = get_client_source()
                        if client_source:
                            metadata["client_source"] = client_source
                        
                        await logging_service.log_activity(
                            user_id=user_id,
                            action=action,
                            resource_type=resource_type,
                            resource_id=resource_id,
                            status=status,
                            duration_ms=duration_ms,
                            metadata=metadata
                        )
                except Exception as log_error:
                    logger.error(f"Failed to log activity: {log_error}")
        
        @functools.wraps(func)
        def sync_wrapper(*args, **kwargs):
            # Use request start time from middleware for total duration (includes auth)
            middleware_start = request_start_time.get()
            local_start_time = time.time()
            
            result = None
            status = "success"
            error_info = None
            
            try:
                result = func(*args, **kwargs)
                return result
            except Exception as e:
                status = "error"
                error_info = {
                    "error_type": type(e).__name__,
                    "error_message": str(e)
                }
                raise
            finally:
                start_time = middleware_start if middleware_start else local_start_time
                duration_ms = int((time.time() - start_time) * 1000)
                metadata = error_info or {}
                
                logger.info(
                    f"Activity: {action} | Status: {status} | "
                    f"Duration: {duration_ms}ms | Resource: {resource_type}"
                )
        
        # Return appropriate wrapper based on function type
        if asyncio_iscoroutinefunction(func):
            return async_wrapper
        return sync_wrapper
    
    return decorator


def log_operation(
    service: str,
    operation: Optional[str] = None,
    extract_input: Optional[Callable[[tuple, dict], Dict[str, Any]]] = None,
    extract_output: Optional[Callable[[Any], Dict[str, Any]]] = None
):
    """
    Decorator for logging internal service operations.
    
    Args:
        service: The service name (e.g., 'blob_storage', 'tensorlake')
        operation: The operation name (defaults to function name)
        extract_input: Function to extract input summary from (args, kwargs)
        extract_output: Function to extract output summary from result
    
    Example:
        @log_operation(
            service="tensorlake",
            extract_input=lambda a, kw: {"file_type": kw.get("file_type")},
            extract_output=lambda r: {"success": r.get("success")}
        )
        async def convert_to_markdown(self, file_content, file_type):
            ...
    """
    def decorator(func: Callable):
        op_name = operation or func.__name__
        
        @functools.wraps(func)
        async def async_wrapper(*args, **kwargs):
            start_time = time.time()
            result = None
            status = "success"
            output_summary = {}
            
            # Extract input summary
            input_summary = {}
            if extract_input:
                try:
                    input_summary = extract_input(args, kwargs) or {}
                except Exception:
                    pass
            
            try:
                result = await func(*args, **kwargs)
                
                # Extract output summary
                if extract_output and result:
                    try:
                        output_summary = extract_output(result) or {}
                    except Exception:
                        pass
                
                return result
            except Exception as e:
                status = "error"
                output_summary = {
                    "error_type": type(e).__name__,
                    "error_message": str(e)
                }
                raise
            finally:
                duration_ms = int((time.time() - start_time) * 1000)
                
                # Log the operation
                try:
                    logging_service = _get_logging_service()
                    if logging_service:
                        await logging_service.log_operation(
                            service=service,
                            operation=op_name,
                            status=status,
                            duration_ms=duration_ms,
                            input_summary=input_summary,
                            output_summary=output_summary
                        )
                except Exception as log_error:
                    logger.error(f"Failed to log operation {service}.{op_name}: {log_error}")
        
        @functools.wraps(func)
        def sync_wrapper(*args, **kwargs):
            start_time = time.time()
            result = None
            status = "success"
            output_summary = {}
            
            # Extract input summary
            input_summary = {}
            if extract_input:
                try:
                    input_summary = extract_input(args, kwargs) or {}
                except Exception:
                    pass
            
            try:
                result = func(*args, **kwargs)
                
                # Extract output summary
                if extract_output and result:
                    try:
                        output_summary = extract_output(result) or {}
                    except Exception:
                        pass
                
                return result
            except Exception as e:
                status = "error"
                output_summary = {
                    "error_type": type(e).__name__,
                    "error_message": str(e)
                }
                raise
            finally:
                duration_ms = int((time.time() - start_time) * 1000)
                
                # Log the operation using asyncio
                try:
                    import asyncio
                    logging_service = _get_logging_service()
                    if logging_service:
                        # Try to get the running event loop
                        try:
                            loop = asyncio.get_running_loop()
                            # Schedule the async logging in the running loop
                            loop.create_task(
                                logging_service.log_operation(
                                    service=service,
                                    operation=op_name,
                                    status=status,
                                    duration_ms=duration_ms,
                                    input_summary=input_summary,
                                    output_summary=output_summary
                                )
                            )
                        except RuntimeError:
                            # No running loop, just log to console
                            logger.info(
                                f"Operation: {service}.{op_name} | Status: {status} | "
                                f"Duration: {duration_ms}ms"
                            )
                except Exception as log_error:
                    logger.error(f"Failed to log operation {service}.{op_name}: {log_error}")
        
        if asyncio_iscoroutinefunction(func):
            return async_wrapper
        return sync_wrapper
    
    return decorator


def log_error(
    error_code: Optional[str] = None,
    include_stack_trace: bool = True,
    reraise: bool = True
):
    """
    Decorator for capturing and logging errors.
    
    Args:
        error_code: Optional error code to use (defaults to exception type)
        include_stack_trace: Whether to include full stack trace
        reraise: Whether to re-raise the exception after logging
    
    Example:
        @log_error(error_code="UPLOAD_FAILED")
        async def process_upload(file):
            ...
    """
    def decorator(func: Callable):
        @functools.wraps(func)
        async def async_wrapper(*args, **kwargs):
            try:
                return await func(*args, **kwargs)
            except Exception as e:
                # Build error context
                context = {
                    "function": func.__name__,
                    "module": func.__module__,
                }
                
                # Add correlation context
                correlation_id = get_correlation_id()
                user_id = get_user_id()
                
                stack_trace = None
                if include_stack_trace:
                    stack_trace = traceback.format_exc()
                
                # Determine error code
                code = error_code or type(e).__name__.upper()
                
                # Log the error
                try:
                    logging_service = _get_logging_service()
                    if logging_service:
                        from uuid import UUID as UUIDType
                        await logging_service.log_error(
                            error_code=code,
                            error_type=type(e).__name__,
                            message=str(e),
                            stack_trace=stack_trace,
                            user_id=user_id,
                            context=context
                        )
                except Exception as log_error:
                    logger.error(f"Failed to log error: {log_error}")
                
                if reraise:
                    raise
        
        @functools.wraps(func)
        def sync_wrapper(*args, **kwargs):
            try:
                return func(*args, **kwargs)
            except Exception as e:
                logger.exception(f"Error in {func.__name__}: {e}")
                if reraise:
                    raise
        
        if asyncio_iscoroutinefunction(func):
            return async_wrapper
        return sync_wrapper
    
    return decorator


def asyncio_iscoroutinefunction(func: Callable) -> bool:
    """Check if a function is a coroutine function."""
    import asyncio
    import inspect
    return asyncio.iscoroutinefunction(func) or inspect.iscoroutinefunction(func)
