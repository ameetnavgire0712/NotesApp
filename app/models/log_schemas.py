"""
Pydantic models for logging, monitoring, and dashboard functionality.
"""
from datetime import datetime
from typing import Optional, List, Dict, Any, Literal
from pydantic import BaseModel, Field
from uuid import UUID


# =============================================================================
# LOG ENTRY MODELS
# =============================================================================

class ActivityLog(BaseModel):
    """User activity log entry - captures user actions in the application."""
    id: Optional[UUID] = None
    correlation_id: UUID
    timestamp: datetime = Field(default_factory=datetime.utcnow)
    user_id: str
    action: str  # 'upload_file', 'search', 'delete_note', 'view_note', etc.
    resource_type: Optional[str] = None  # 'note', 'file', 'screenshot', 'quick_note'
    resource_id: Optional[UUID] = None
    status: Literal["success", "error", "pending"] = "success"
    duration_ms: Optional[int] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)
    
    class Config:
        from_attributes = True


class OperationLog(BaseModel):
    """Internal operation log - captures service-level operations."""
    id: Optional[UUID] = None
    correlation_id: UUID
    timestamp: datetime = Field(default_factory=datetime.utcnow)
    service: str  # 'blob_storage', 'tensorlake', 'embeddings', 'notes_db', etc.
    operation: str  # 'upload_file', 'convert_to_markdown', 'generate_embeddings', etc.
    status: Literal["success", "error", "timeout"] = "success"
    duration_ms: Optional[int] = None
    input_summary: Dict[str, Any] = Field(default_factory=dict)
    output_summary: Dict[str, Any] = Field(default_factory=dict)
    
    class Config:
        from_attributes = True


class ErrorLog(BaseModel):
    """Error log entry - captures exceptions and errors with full context."""
    id: Optional[UUID] = None
    correlation_id: Optional[UUID] = None
    timestamp: datetime = Field(default_factory=datetime.utcnow)
    user_id: Optional[str] = None
    error_code: str  # Application-specific error code
    error_type: str  # Exception class name
    message: str
    stack_trace: Optional[str] = None
    context: Dict[str, Any] = Field(default_factory=dict)
    
    class Config:
        from_attributes = True


# =============================================================================
# LOG QUERY MODELS
# =============================================================================

class LogQueryParams(BaseModel):
    """Parameters for querying logs."""
    user_id: Optional[str] = None
    correlation_id: Optional[UUID] = None
    action: Optional[str] = None
    resource_type: Optional[str] = None
    status: Optional[str] = None
    error_type: Optional[str] = None
    service: Optional[str] = None
    start_date: Optional[datetime] = None
    end_date: Optional[datetime] = None
    search_text: Optional[str] = None
    limit: int = Field(default=100, ge=1, le=1000)
    offset: int = Field(default=0, ge=0)
    include_archived: bool = False


class ActivityLogResponse(BaseModel):
    """Response model for activity log queries."""
    logs: List[ActivityLog]
    total_count: int
    has_more: bool
    query_params: LogQueryParams


class OperationLogResponse(BaseModel):
    """Response model for operation log queries."""
    logs: List[OperationLog]
    total_count: int
    has_more: bool
    query_params: LogQueryParams


class ErrorLogResponse(BaseModel):
    """Response model for error log queries."""
    logs: List[ErrorLog]
    total_count: int
    has_more: bool
    query_params: LogQueryParams


class TraceResponse(BaseModel):
    """Complete trace of a request by correlation_id."""
    correlation_id: UUID
    activities: List[ActivityLog]
    operations: List[OperationLog]
    errors: List[ErrorLog]
    total_duration_ms: Optional[int] = None
    start_time: Optional[datetime] = None
    end_time: Optional[datetime] = None


# =============================================================================
# DASHBOARD / METRICS MODELS
# =============================================================================

class TimeSeriesPoint(BaseModel):
    """Single point in a time series."""
    timestamp: datetime
    value: float


class EndpointMetrics(BaseModel):
    """Metrics for a specific API endpoint."""
    endpoint: str
    method: str
    total_requests: int
    success_count: int
    error_count: int
    avg_duration_ms: float
    p50_duration_ms: Optional[float] = None
    p95_duration_ms: Optional[float] = None
    p99_duration_ms: Optional[float] = None


class ErrorBreakdown(BaseModel):
    """Breakdown of errors by type."""
    total_errors: int
    by_type: Dict[str, int]
    by_error_code: Dict[str, int]
    top_endpoints: List[Dict[str, Any]]


class PerformanceMetrics(BaseModel):
    """Performance metrics summary."""
    period: str  # 'last_hour', 'last_24h', 'last_7d'
    avg_latency_ms: float
    p50_ms: float
    p95_ms: float
    p99_ms: float
    slowest_endpoints: List[EndpointMetrics]


class UsageStats(BaseModel):
    """Usage statistics."""
    period: str
    total_requests: int
    unique_users: int
    notes_created: int
    files_uploaded: int
    screenshots_captured: int
    quick_notes_created: int
    searches_performed: int
    notes_deleted: int
    by_endpoint: List[EndpointMetrics]
    by_user: List[Dict[str, Any]]


class DashboardOverview(BaseModel):
    """Main dashboard overview response."""
    period: str
    generated_at: datetime = Field(default_factory=datetime.utcnow)
    
    # Key metrics
    total_requests: int
    success_rate: float  # Percentage 0-100
    error_rate: float  # Percentage 0-100
    avg_latency_ms: float
    
    # Activity counts
    active_users: int
    notes_created: int
    searches_performed: int
    errors_count: int
    
    # Trends (compared to previous period)
    request_trend: Optional[float] = None  # Percentage change
    error_trend: Optional[float] = None
    latency_trend: Optional[float] = None


class ActivityTimeline(BaseModel):
    """Timeline of user activities for visualization."""
    period: str
    interval: str  # 'hour', 'day'
    data_points: List[TimeSeriesPoint]
    by_action: Dict[str, List[TimeSeriesPoint]]


class ServiceHealthStatus(BaseModel):
    """Health status of a single service."""
    service: str
    status: Literal["healthy", "degraded", "unhealthy", "unknown"]
    last_success: Optional[datetime] = None
    last_error: Optional[datetime] = None
    error_rate_1h: float = 0.0
    avg_latency_ms: Optional[float] = None


class SystemHealth(BaseModel):
    """Overall system health status."""
    overall_status: Literal["healthy", "degraded", "unhealthy"]
    services: List[ServiceHealthStatus]
    last_updated: datetime = Field(default_factory=datetime.utcnow)


# =============================================================================
# ARCHIVAL MODELS
# =============================================================================

class ArchivalStatus(BaseModel):
    """Status of log archival operation."""
    date: str  # Date being archived (YYYY-MM-DD)
    table: str  # Table being archived
    records_archived: int
    records_deleted: int
    blob_path: str
    started_at: datetime
    completed_at: Optional[datetime] = None
    status: Literal["in_progress", "completed", "failed"]
    error_message: Optional[str] = None


class ArchivalJobResponse(BaseModel):
    """Response from archival job trigger."""
    job_id: UUID
    started_at: datetime
    target_date: str
    tables: List[str]
    status: Literal["started", "completed", "failed"]
    results: List[ArchivalStatus] = []


# =============================================================================
# API METRICS (for hourly aggregation)
# =============================================================================

class HourlyApiMetrics(BaseModel):
    """Hourly aggregated API metrics."""
    id: Optional[UUID] = None
    hour: datetime
    endpoint: str
    method: str
    total_requests: int = 0
    success_count: int = 0
    error_count: int = 0
    total_duration_ms: int = 0
    avg_duration_ms: Optional[int] = None
    min_duration_ms: Optional[int] = None
    max_duration_ms: Optional[int] = None
    p95_duration_ms: Optional[int] = None
    
    class Config:
        from_attributes = True
