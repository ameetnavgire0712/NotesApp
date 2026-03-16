"""
Logging Service
Handles dual-write logging to Supabase (hot storage) and Azure Blob Storage (warm storage).
Provides buffered async writes to blob storage for performance.
"""
import asyncio
import json
import logging
from datetime import datetime
from typing import Optional, Dict, Any, List
from uuid import UUID, uuid4
from collections import defaultdict

from supabase import create_client, Client
from azure.storage.blob import BlobServiceClient, ContentSettings

from app.core.config import get_settings
from app.core.middleware import get_correlation_id
from app.models.log_schemas import ActivityLog, OperationLog, ErrorLog

logger = logging.getLogger(__name__)


class LogBuffer:
    """
    Buffer for batching log writes to blob storage.
    Flushes on size threshold or time interval.
    """
    
    def __init__(self, max_size: int = 100, flush_interval_seconds: int = 30):
        self.max_size = max_size
        self.flush_interval = flush_interval_seconds
        # Buffers keyed by (user_id, log_type, date)
        self._buffers: Dict[tuple, List[dict]] = defaultdict(list)
        self._lock = asyncio.Lock()
        self._last_flush = datetime.utcnow()
        self._flush_task: Optional[asyncio.Task] = None
    
    async def add(self, user_id: str, log_type: str, entry: dict) -> None:
        """Add a log entry to the buffer."""
        date_str = datetime.utcnow().strftime("%Y-%m-%d")
        key = (user_id, log_type, date_str)
        
        async with self._lock:
            self._buffers[key].append(entry)
            
            # Check if we need to flush this specific buffer
            if len(self._buffers[key]) >= self.max_size:
                entries = self._buffers.pop(key)
                return entries  # Return entries for immediate flush
        
        return None
    
    async def get_and_clear(self) -> Dict[tuple, List[dict]]:
        """Get all buffered entries and clear buffers."""
        async with self._lock:
            buffers = dict(self._buffers)
            self._buffers = defaultdict(list)
            self._last_flush = datetime.utcnow()
            return buffers
    
    def should_flush(self) -> bool:
        """Check if time-based flush is needed."""
        elapsed = (datetime.utcnow() - self._last_flush).total_seconds()
        return elapsed >= self.flush_interval or any(self._buffers.values())


class LoggingService:
    """
    Main logging service providing dual-write to Supabase and Blob Storage.
    
    Features:
    - Synchronous write to Supabase for queryability
    - Buffered async write to Blob Storage for durability
    - Automatic correlation ID injection
    - Structured JSON logging
    """
    
    def __init__(self):
        settings = get_settings()
        
        # Initialize Supabase client
        self.supabase: Client = create_client(
            settings.supabase_url,
            settings.supabase_service_key
        )
        
        # Initialize Azure Blob client
        self.blob_service_client = BlobServiceClient.from_connection_string(
            settings.azure_storage_connection_string
        )
        self.container_name = settings.azure_storage_container
        self.container_client = self.blob_service_client.get_container_client(
            self.container_name
        )
        
        # Initialize buffers for each log type
        self.activity_buffer = LogBuffer(max_size=50, flush_interval_seconds=30)
        self.operation_buffer = LogBuffer(max_size=100, flush_interval_seconds=30)
        self.error_buffer = LogBuffer(max_size=10, flush_interval_seconds=10)  # Flush errors faster
        
        # Background flush task
        self._flush_task: Optional[asyncio.Task] = None
        self._running = False
    
    async def start(self) -> None:
        """Start the background flush task."""
        if not self._running:
            self._running = True
            self._flush_task = asyncio.create_task(self._background_flush_loop())
            logger.info("LoggingService background flush task started")
    
    async def stop(self) -> None:
        """Stop the background flush task and flush remaining logs."""
        self._running = False
        if self._flush_task:
            self._flush_task.cancel()
            try:
                await self._flush_task
            except asyncio.CancelledError:
                pass
        # Final flush
        await self._flush_all_buffers()
        logger.info("LoggingService stopped and buffers flushed")
    
    async def _background_flush_loop(self) -> None:
        """Background task that periodically flushes buffers."""
        while self._running:
            try:
                await asyncio.sleep(10)  # Check every 10 seconds
                await self._flush_all_buffers()
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Error in background flush loop: {e}")
    
    async def _flush_all_buffers(self) -> None:
        """Flush all log buffers to blob storage."""
        for buffer, log_type in [
            (self.activity_buffer, "activities"),
            (self.operation_buffer, "operations"),
            (self.error_buffer, "errors")
        ]:
            if buffer.should_flush():
                try:
                    entries = await buffer.get_and_clear()
                    for (user_id, _, date_str), logs in entries.items():
                        if logs:
                            await self._write_logs_to_blob(user_id, log_type, date_str, logs)
                except Exception as e:
                    logger.error(f"Failed to flush {log_type} buffer: {e}")
    
    async def _write_logs_to_blob(
        self,
        user_id: str,
        log_type: str,
        date_str: str,
        entries: List[dict]
    ) -> None:
        """Write log entries to blob storage as JSONL (append)."""
        blob_path = f"{user_id}/logs/{log_type}/{date_str}.jsonl"
        
        try:
            blob_client = self.container_client.get_blob_client(blob_path)
            
            # Convert entries to JSONL format
            jsonl_content = "\n".join(json.dumps(entry, default=str) for entry in entries)
            jsonl_bytes = (jsonl_content + "\n").encode("utf-8")
            
            # Try to append to existing blob, or create new one
            try:
                # Check if blob exists and get its content
                existing_content = blob_client.download_blob().readall()
                new_content = existing_content + jsonl_bytes
            except Exception:
                # Blob doesn't exist, create new
                new_content = jsonl_bytes
            
            # Upload the combined content
            content_settings = ContentSettings(content_type="application/x-ndjson")
            blob_client.upload_blob(
                new_content,
                overwrite=True,
                content_settings=content_settings
            )
            
            logger.debug(f"Wrote {len(entries)} log entries to {blob_path}")
            
        except Exception as e:
            logger.error(f"Failed to write logs to blob {blob_path}: {e}")
            # Don't raise - logging failures shouldn't break the app
    
    async def _write_to_supabase(self, table: str, data: dict) -> Optional[dict]:
        """Write a log entry to Supabase."""
        try:
            result = self.supabase.table(table).insert(data).execute()
            return result.data[0] if result.data else None
        except Exception as e:
            logger.error(f"Failed to write to Supabase table {table}: {e}")
            return None
    
    def _get_correlation_id(self) -> UUID:
        """Get current correlation ID or generate a new one."""
        cid = get_correlation_id()
        if cid:
            try:
                return UUID(cid)
            except ValueError:
                pass
        return uuid4()
    
    # =========================================================================
    # PUBLIC LOGGING METHODS
    # =========================================================================
    
    async def log_activity(
        self,
        user_id: str,
        action: str,
        resource_type: Optional[str] = None,
        resource_id: Optional[UUID] = None,
        status: str = "success",
        duration_ms: Optional[int] = None,
        metadata: Optional[Dict[str, Any]] = None
    ) -> Optional[ActivityLog]:
        """
        Log a user activity.
        
        Args:
            user_id: User identifier
            action: Action performed (e.g., 'upload_file', 'search_notes')
            resource_type: Type of resource (e.g., 'note', 'file')
            resource_id: ID of the resource
            status: 'success', 'error', or 'pending'
            duration_ms: Operation duration in milliseconds
            metadata: Additional context
        
        Returns:
            The created ActivityLog or None on failure
        """
        correlation_id = self._get_correlation_id()
        timestamp = datetime.utcnow()
        
        # Validate user_id is a valid UUID before writing to Supabase
        # Skip Supabase logging for non-UUID user_ids (e.g., "unknown", "system", "default_user")
        valid_user_id = None
        if user_id:
            try:
                # Validate it's a proper UUID
                UUID(user_id)
                valid_user_id = user_id
            except (ValueError, TypeError):
                logger.debug(f"Skipping activity logging for non-UUID user_id: {user_id}")
        
        log_entry = ActivityLog(
            correlation_id=correlation_id,
            timestamp=timestamp,
            user_id=user_id,
            action=action,
            resource_type=resource_type,
            resource_id=resource_id,
            status=status,
            duration_ms=duration_ms,
            metadata=metadata or {}
        )
        
        # Only write to Supabase if we have a valid UUID user_id
        if valid_user_id:
            # Prepare data for Supabase
            supabase_data = {
                "correlation_id": str(correlation_id),
                "user_id": valid_user_id,
                "action": action,
                "resource_type": resource_type,
                "resource_id": str(resource_id) if resource_id else None,
                "status": status,
                "duration_ms": duration_ms,
                "metadata": metadata or {},
                "created_at": timestamp.isoformat()
            }
            
            # Write to Supabase (sync for queryability)
            await self._write_to_supabase("user_activities", supabase_data)
        
        # Buffer for blob storage (async batch write)
        blob_entry = log_entry.model_dump()
        blob_entry["correlation_id"] = str(correlation_id)
        blob_entry["resource_id"] = str(resource_id) if resource_id else None
        blob_entry["timestamp"] = timestamp.isoformat()
        
        immediate_flush = await self.activity_buffer.add(user_id, "activities", blob_entry)
        if immediate_flush:
            await self._write_logs_to_blob(
                user_id, "activities",
                timestamp.strftime("%Y-%m-%d"),
                immediate_flush
            )
        
        return log_entry
    
    async def log_operation(
        self,
        service: str,
        operation: str,
        status: str = "success",
        duration_ms: Optional[int] = None,
        input_summary: Optional[Dict[str, Any]] = None,
        output_summary: Optional[Dict[str, Any]] = None
    ) -> Optional[OperationLog]:
        """
        Log an internal service operation.
        
        Args:
            service: Service name (e.g., 'tensorlake', 'embeddings')
            operation: Operation name (e.g., 'convert_to_markdown')
            status: 'success', 'error', or 'timeout'
            duration_ms: Operation duration in milliseconds
            input_summary: Summary of input parameters
            output_summary: Summary of output/result
        
        Returns:
            The created OperationLog or None on failure
        """
        correlation_id = self._get_correlation_id()
        timestamp = datetime.utcnow()
        
        log_entry = OperationLog(
            correlation_id=correlation_id,
            timestamp=timestamp,
            service=service,
            operation=operation,
            status=status,
            duration_ms=duration_ms,
            input_summary=input_summary or {},
            output_summary=output_summary or {}
        )
        
        # Prepare data for Supabase
        supabase_data = {
            "correlation_id": str(correlation_id),
            "service": service,
            "operation": operation,
            "status": status,
            "duration_ms": duration_ms,
            "input_summary": input_summary or {},
            "output_summary": output_summary or {},
            "created_at": timestamp.isoformat()
        }
        
        # Write to Supabase
        await self._write_to_supabase("operation_logs", supabase_data)
        
        # Buffer for blob storage - use system user for operations
        blob_entry = log_entry.model_dump()
        blob_entry["correlation_id"] = str(correlation_id)
        blob_entry["timestamp"] = timestamp.isoformat()
        
        immediate_flush = await self.operation_buffer.add("_system", "operations", blob_entry)
        if immediate_flush:
            await self._write_logs_to_blob(
                "_system", "operations",
                timestamp.strftime("%Y-%m-%d"),
                immediate_flush
            )
        
        return log_entry
    
    async def log_error(
        self,
        error_code: str,
        error_type: str,
        message: str,
        stack_trace: Optional[str] = None,
        user_id: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None
    ) -> Optional[ErrorLog]:
        """
        Log an error.
        
        Args:
            error_code: Application error code
            error_type: Exception class name
            message: Error message
            stack_trace: Full stack trace
            user_id: User ID if available
            context: Additional context
        
        Returns:
            The created ErrorLog or None on failure
        """
        correlation_id = self._get_correlation_id()
        timestamp = datetime.utcnow()
        
        log_entry = ErrorLog(
            correlation_id=correlation_id,
            timestamp=timestamp,
            user_id=user_id,
            error_code=error_code,
            error_type=error_type,
            message=message,
            stack_trace=stack_trace,
            context=context or {}
        )
        
        # Prepare data for Supabase
        supabase_data = {
            "correlation_id": str(correlation_id),
            "user_id": user_id,
            "error_code": error_code,
            "error_type": error_type,
            "message": message,
            "stack_trace": stack_trace,
            "context": context or {},
            "created_at": timestamp.isoformat()
        }
        
        # Write to Supabase (errors are always written immediately)
        await self._write_to_supabase("error_logs", supabase_data)
        
        # Buffer for blob storage - store in user folder if known, else system
        target_user = user_id or "_system"
        blob_entry = log_entry.model_dump()
        blob_entry["correlation_id"] = str(correlation_id)
        blob_entry["timestamp"] = timestamp.isoformat()
        
        # Errors flush faster (smaller buffer)
        immediate_flush = await self.error_buffer.add(target_user, "errors", blob_entry)
        if immediate_flush:
            await self._write_logs_to_blob(
                target_user, "errors",
                timestamp.strftime("%Y-%m-%d"),
                immediate_flush
            )
        
        # Also log to standard Python logger for console visibility
        logger.error(
            f"[{error_code}] {error_type}: {message}",
            extra={"correlation_id": str(correlation_id), "user_id": user_id}
        )
        
        return log_entry
    
    async def flush(self) -> None:
        """Force flush all buffers immediately."""
        await self._flush_all_buffers()


# =============================================================================
# SINGLETON INSTANCE
# =============================================================================

_logging_service: Optional[LoggingService] = None


def get_logging_service() -> LoggingService:
    """Get the singleton LoggingService instance."""
    global _logging_service
    if _logging_service is None:
        _logging_service = LoggingService()
    return _logging_service


async def init_logging_service() -> LoggingService:
    """Initialize and start the logging service."""
    service = get_logging_service()
    await service.start()
    return service


async def shutdown_logging_service() -> None:
    """Shutdown the logging service gracefully."""
    global _logging_service
    if _logging_service:
        await _logging_service.stop()
        _logging_service = None
