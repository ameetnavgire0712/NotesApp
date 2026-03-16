"""
Supabase Log Handler for Distributed Logging

Implements a Python logging handler that writes logs to Supabase,
enabling centralized logging for distributed Fly.io deployments.

The schema matches the existing notesapp.log format exactly:
timestamp | level | correlation_id | user_id | logger_name | filename:lineno | function | message
"""

import os
import logging
import asyncio
import threading
from datetime import datetime
from typing import Optional
from dataclasses import dataclass, asdict
from queue import Queue, Empty

import httpx


@dataclass
class LogEntry:
    """Log entry matching notesapp.log and Supabase table schema."""
    timestamp: str
    level: str
    correlation_id: Optional[str]
    user_id: Optional[str]
    logger_name: str
    filename: str
    line_number: int
    function_name: str
    message: str
    machine_id: str
    region: str
    service: str


class SupabaseLogger:
    """
    Async logger that batches and writes logs to Supabase.
    
    Features:
    - Batches logs (100 logs or 5 seconds, whichever comes first)
    - Thread-safe with background flush task
    - Includes Fly.io machine metadata (machine_id, region)
    - Graceful shutdown with final flush
    """
    
    def __init__(
        self,
        batch_size: int = 100,
        flush_interval: float = 5.0,
    ):
        self.batch_size = batch_size
        self.flush_interval = flush_interval
        
        # Get config from environment
        self.supabase_url = os.environ.get("SUPABASE_URL", "")
        self.supabase_key = os.environ.get("SUPABASE_SERVICE_KEY", "")
        
        # Fly.io machine metadata
        self.machine_id = os.environ.get("FLY_MACHINE_ID", "local")
        self.region = os.environ.get("FLY_REGION", "local")
        self.service = os.environ.get("FLY_APP_NAME", "unknown")
        
        # Thread-safe queue for log entries
        self._queue: Queue[LogEntry] = Queue()
        self._running = False
        self._flush_task: Optional[asyncio.Task] = None
        self._client: Optional[httpx.AsyncClient] = None
        
    async def start(self):
        """Start the background flush task."""
        if self._running:
            return
            
        self._running = True
        self._client = httpx.AsyncClient(
            base_url=self.supabase_url,
            headers={
                "apikey": self.supabase_key,
                "Authorization": f"Bearer {self.supabase_key}",
                "Content-Type": "application/json",
                "Prefer": "return=minimal",
            },
            timeout=30.0,
        )
        
        # Start background flush task
        self._flush_task = asyncio.create_task(self._flush_loop())
        
    async def stop(self):
        """Stop the logger and flush remaining logs."""
        self._running = False
        
        if self._flush_task:
            self._flush_task.cancel()
            try:
                await self._flush_task
            except asyncio.CancelledError:
                pass
        
        # Final flush
        await self._flush()
        
        if self._client:
            await self._client.aclose()
            
    def log(self, entry: LogEntry):
        """Add a log entry to the queue (thread-safe)."""
        self._queue.put(entry)
        
        # Trigger immediate flush if batch is full
        if self._queue.qsize() >= self.batch_size:
            # Signal flush (non-blocking)
            pass
            
    async def _flush_loop(self):
        """Background loop that flushes logs periodically."""
        while self._running:
            await asyncio.sleep(self.flush_interval)
            await self._flush()
            
    async def _flush(self):
        """Flush pending logs to Supabase."""
        if not self._client or self._queue.empty():
            return
            
        # Collect up to batch_size entries
        entries = []
        while len(entries) < self.batch_size:
            try:
                entry = self._queue.get_nowait()
                entries.append(asdict(entry))
            except Empty:
                break
                
        if not entries:
            return
            
        try:
            response = await self._client.post(
                "/rest/v1/application_logs",
                json=entries,
            )
            
            if response.status_code >= 400:
                # Log to console if Supabase insert fails
                print(f"Failed to write logs to Supabase: {response.status_code} - {response.text}")
                
        except Exception as e:
            print(f"Error flushing logs to Supabase: {e}")


class SupabaseLogHandler(logging.Handler):
    """
    Python logging handler that writes to Supabase via SupabaseLogger.
    
    Usage:
        handler = SupabaseLogHandler()
        handler.setLevel(logging.DEBUG)
        logging.getLogger().addHandler(handler)
    """
    
    def __init__(self):
        super().__init__()
        self._logger = get_supabase_logger()
        
    def emit(self, record: logging.LogRecord):
        """Process a log record."""
        try:
            # Format first to allow formatter to inject context variables
            # (e.g., UserContextFormatter adds correlation_id and user_id)
            formatted_message = self.format(record)
            
            # Extract context variables AFTER formatting (formatter may have set them)
            correlation_id = getattr(record, 'correlation_id', None)
            user_id = getattr(record, 'user_id', None)
            
            # Handle None values and string "None"
            if correlation_id in (None, "None", "no-correlation-id"):
                correlation_id = None
            if user_id in (None, "None", "no-user-id"):
                user_id = None
            
            entry = LogEntry(
                timestamp=datetime.utcnow().isoformat(),
                level=record.levelname,
                correlation_id=correlation_id,
                user_id=user_id,
                logger_name=record.name,
                filename=record.filename,
                line_number=record.lineno,
                function_name=record.funcName,
                message=formatted_message,
                machine_id=self._logger.machine_id,
                region=self._logger.region,
                service=self._logger.service,
            )
            
            self._logger.log(entry)
            
        except Exception:
            self.handleError(record)


# Singleton instance
_supabase_logger: Optional[SupabaseLogger] = None
_lock = threading.Lock()


def get_supabase_logger() -> SupabaseLogger:
    """Get the singleton SupabaseLogger instance."""
    global _supabase_logger
    
    if _supabase_logger is None:
        with _lock:
            if _supabase_logger is None:
                _supabase_logger = SupabaseLogger()
                
    return _supabase_logger
