"""
Logging context management.

Provides context variables for logging that can be set per-request
and accessed by logging filters across all modules.
"""
from contextvars import ContextVar
from typing import Optional

# Context variable to store user_id per-request for logging
# Default to None - will be set to actual user_id on authenticated requests
current_user_id: ContextVar[Optional[str]] = ContextVar("current_user_id", default=None)

# Context variable to store correlation_id per-request for logging  
# Default to None - will be set by middleware on each request
current_correlation_id: ContextVar[Optional[str]] = ContextVar("current_correlation_id", default=None)

# Context variable to store request start time for accurate duration calculation
request_start_time: ContextVar[Optional[float]] = ContextVar("request_start_time", default=None)
