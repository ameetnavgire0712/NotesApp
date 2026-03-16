"""
Custom exception hierarchy for the NotesApp application.
Provides structured error handling with error codes, context preservation,
and integration with the logging framework.
"""
import traceback
from typing import Optional, Dict, Any
from enum import Enum


class ErrorCode(str, Enum):
    """Application-specific error codes for categorization and monitoring."""
    
    # General errors (1xxx)
    UNKNOWN_ERROR = "ERR_1000"
    VALIDATION_ERROR = "ERR_1001"
    NOT_FOUND = "ERR_1002"
    PERMISSION_DENIED = "ERR_1003"
    RATE_LIMITED = "ERR_1004"
    
    # Blob storage errors (2xxx)
    BLOB_UPLOAD_FAILED = "ERR_2001"
    BLOB_DOWNLOAD_FAILED = "ERR_2002"
    BLOB_DELETE_FAILED = "ERR_2003"
    BLOB_NOT_FOUND = "ERR_2004"
    BLOB_CONNECTION_ERROR = "ERR_2005"
    BLOB_SAS_GENERATION_FAILED = "ERR_2006"
    
    # Database errors (3xxx)
    DB_CONNECTION_ERROR = "ERR_3001"
    DB_QUERY_FAILED = "ERR_3002"
    DB_INSERT_FAILED = "ERR_3003"
    DB_UPDATE_FAILED = "ERR_3004"
    DB_DELETE_FAILED = "ERR_3005"
    DB_RECORD_NOT_FOUND = "ERR_3006"
    
    # External service errors (4xxx)
    TENSORLAKE_API_ERROR = "ERR_4001"
    TENSORLAKE_TIMEOUT = "ERR_4002"
    TENSORLAKE_CONVERSION_FAILED = "ERR_4003"
    OPENAI_API_ERROR = "ERR_4101"
    OPENAI_RATE_LIMITED = "ERR_4102"
    OPENAI_EMBEDDING_FAILED = "ERR_4103"
    GROQ_API_ERROR = "ERR_4201"
    GROQ_RATE_LIMITED = "ERR_4202"
    
    # Processing errors (5xxx)
    FILE_PROCESSING_ERROR = "ERR_5001"
    EMBEDDING_GENERATION_FAILED = "ERR_5002"
    HTML_CLEANING_FAILED = "ERR_5003"
    CHUNKING_FAILED = "ERR_5004"
    
    # Logging/archival errors (6xxx)
    LOG_WRITE_FAILED = "ERR_6001"
    LOG_QUERY_FAILED = "ERR_6002"
    ARCHIVAL_FAILED = "ERR_6003"
    METRICS_AGGREGATION_FAILED = "ERR_6004"


class AppException(Exception):
    """
    Base exception class for all application exceptions.
    Provides structured error information for logging and API responses.
    """
    
    def __init__(
        self,
        message: str,
        error_code: ErrorCode = ErrorCode.UNKNOWN_ERROR,
        status_code: int = 500,
        context: Optional[Dict[str, Any]] = None,
        original_exception: Optional[Exception] = None
    ):
        super().__init__(message)
        self.message = message
        self.error_code = error_code
        self.status_code = status_code
        self.context = context or {}
        self.original_exception = original_exception
        self.stack_trace = traceback.format_exc() if original_exception else None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert exception to dictionary for logging/API response."""
        return {
            "error_code": self.error_code.value,
            "error_type": self.__class__.__name__,
            "message": self.message,
            "context": self.context,
            "stack_trace": self.stack_trace
        }
    
    def __str__(self) -> str:
        return f"[{self.error_code.value}] {self.message}"


class ValidationError(AppException):
    """Raised when input validation fails."""
    
    def __init__(
        self,
        message: str,
        field: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None
    ):
        ctx = context or {}
        if field:
            ctx["field"] = field
        super().__init__(
            message=message,
            error_code=ErrorCode.VALIDATION_ERROR,
            status_code=400,
            context=ctx
        )


class NotFoundError(AppException):
    """Raised when a requested resource is not found."""
    
    def __init__(
        self,
        resource_type: str,
        resource_id: str,
        context: Optional[Dict[str, Any]] = None
    ):
        ctx = context or {}
        ctx.update({"resource_type": resource_type, "resource_id": resource_id})
        super().__init__(
            message=f"{resource_type} with id '{resource_id}' not found",
            error_code=ErrorCode.NOT_FOUND,
            status_code=404,
            context=ctx
        )


class BlobStorageError(AppException):
    """Raised when blob storage operations fail."""
    
    def __init__(
        self,
        message: str,
        error_code: ErrorCode = ErrorCode.BLOB_UPLOAD_FAILED,
        blob_name: Optional[str] = None,
        operation: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None,
        original_exception: Optional[Exception] = None
    ):
        ctx = context or {}
        if blob_name:
            ctx["blob_name"] = blob_name
        if operation:
            ctx["operation"] = operation
        super().__init__(
            message=message,
            error_code=error_code,
            status_code=500,
            context=ctx,
            original_exception=original_exception
        )


class DatabaseError(AppException):
    """Raised when database operations fail."""
    
    def __init__(
        self,
        message: str,
        error_code: ErrorCode = ErrorCode.DB_QUERY_FAILED,
        table: Optional[str] = None,
        operation: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None,
        original_exception: Optional[Exception] = None
    ):
        ctx = context or {}
        if table:
            ctx["table"] = table
        if operation:
            ctx["operation"] = operation
        super().__init__(
            message=message,
            error_code=error_code,
            status_code=500,
            context=ctx,
            original_exception=original_exception
        )


class ExternalServiceError(AppException):
    """Raised when external service calls fail (Tensorlake, OpenAI, Groq)."""
    
    def __init__(
        self,
        service: str,
        message: str,
        error_code: ErrorCode = ErrorCode.UNKNOWN_ERROR,
        operation: Optional[str] = None,
        response_status: Optional[int] = None,
        context: Optional[Dict[str, Any]] = None,
        original_exception: Optional[Exception] = None
    ):
        ctx = context or {}
        ctx["service"] = service
        if operation:
            ctx["operation"] = operation
        if response_status:
            ctx["response_status"] = response_status
        super().__init__(
            message=message,
            error_code=error_code,
            status_code=502,  # Bad Gateway for external service failures
            context=ctx,
            original_exception=original_exception
        )


class TensorlakeError(ExternalServiceError):
    """Raised when Tensorlake API calls fail."""
    
    def __init__(
        self,
        message: str,
        error_code: ErrorCode = ErrorCode.TENSORLAKE_API_ERROR,
        operation: Optional[str] = None,
        parse_id: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None,
        original_exception: Optional[Exception] = None
    ):
        ctx = context or {}
        if parse_id:
            ctx["parse_id"] = parse_id
        super().__init__(
            service="tensorlake",
            message=message,
            error_code=error_code,
            operation=operation,
            context=ctx,
            original_exception=original_exception
        )


class OpenAIError(ExternalServiceError):
    """Raised when OpenAI API calls fail."""
    
    def __init__(
        self,
        message: str,
        error_code: ErrorCode = ErrorCode.OPENAI_API_ERROR,
        operation: Optional[str] = None,
        model: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None,
        original_exception: Optional[Exception] = None
    ):
        ctx = context or {}
        if model:
            ctx["model"] = model
        super().__init__(
            service="openai",
            message=message,
            error_code=error_code,
            operation=operation,
            context=ctx,
            original_exception=original_exception
        )


class GroqError(ExternalServiceError):
    """Raised when Groq API calls fail."""
    
    def __init__(
        self,
        message: str,
        error_code: ErrorCode = ErrorCode.GROQ_API_ERROR,
        operation: Optional[str] = None,
        model: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None,
        original_exception: Optional[Exception] = None
    ):
        ctx = context or {}
        if model:
            ctx["model"] = model
        super().__init__(
            service="groq",
            message=message,
            error_code=error_code,
            operation=operation,
            context=ctx,
            original_exception=original_exception
        )


class ProcessingError(AppException):
    """Raised when file/data processing fails."""
    
    def __init__(
        self,
        message: str,
        error_code: ErrorCode = ErrorCode.FILE_PROCESSING_ERROR,
        file_type: Optional[str] = None,
        step: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None,
        original_exception: Optional[Exception] = None
    ):
        ctx = context or {}
        if file_type:
            ctx["file_type"] = file_type
        if step:
            ctx["processing_step"] = step
        super().__init__(
            message=message,
            error_code=error_code,
            status_code=500,
            context=ctx,
            original_exception=original_exception
        )


class LoggingError(AppException):
    """Raised when logging operations fail (non-fatal, should not break main flow)."""
    
    def __init__(
        self,
        message: str,
        error_code: ErrorCode = ErrorCode.LOG_WRITE_FAILED,
        log_type: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None,
        original_exception: Optional[Exception] = None
    ):
        ctx = context or {}
        if log_type:
            ctx["log_type"] = log_type
        super().__init__(
            message=message,
            error_code=error_code,
            status_code=500,
            context=ctx,
            original_exception=original_exception
        )


class ArchivalError(AppException):
    """Raised when log archival operations fail."""
    
    def __init__(
        self,
        message: str,
        target_date: Optional[str] = None,
        table: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None,
        original_exception: Optional[Exception] = None
    ):
        ctx = context or {}
        if target_date:
            ctx["target_date"] = target_date
        if table:
            ctx["table"] = table
        super().__init__(
            message=message,
            error_code=ErrorCode.ARCHIVAL_FAILED,
            status_code=500,
            context=ctx,
            original_exception=original_exception
        )
