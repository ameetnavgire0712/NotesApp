"""
Logs API Endpoints
Provides REST API for querying logs, tracing requests, and searching.
"""
import os
import re
from datetime import datetime
from typing import Optional, List
from uuid import UUID
from pathlib import Path

from fastapi import APIRouter, Query, HTTPException
from pydantic import BaseModel

from app.services.log_query_service import get_log_query_service
from app.models.log_schemas import (
    LogQueryParams,
    TraceResponse
)

router = APIRouter(prefix="/logs", tags=["Logs"])


# =============================================================================
# USER ACTIVITY LOG (COMBINED VIEW)
# =============================================================================

@router.get("/user/{user_id}")
async def get_user_activity_log(
    user_id: str,
    start_date: Optional[datetime] = Query(None, description="Start date (ISO format)"),
    end_date: Optional[datetime] = Query(None, description="End date (ISO format)"),
    include_archived: bool = Query(False, description="Include archived logs from blob storage"),
    limit: int = Query(100, ge=1, le=500, description="Maximum activities to return"),
    offset: int = Query(0, ge=0, description="Pagination offset")
):
    """
    Get comprehensive activity log for a user.
    
    Returns all user activities with their associated under-the-hood operations
    and errors, grouped by request (correlation_id).
    
    Each activity includes:
    - **Basic info**: action, resource_type, status, duration
    - **Operations**: All service calls (tensorlake, blob_storage, notes_db, etc.)
    - **Errors**: Any exceptions that occurred
    
    This is the primary endpoint for understanding what a user did and what
    happened behind the scenes for each action.
    """
    service = get_log_query_service()
    
    result = await service.get_user_activity_log(
        user_id=user_id,
        start_date=start_date,
        end_date=end_date,
        include_archived=include_archived,
        limit=limit,
        offset=offset
    )
    
    if not result["activities"]:
        raise HTTPException(
            status_code=404,
            detail=f"No activities found for user: {user_id}"
        )
    
    return result


# =============================================================================
# REQUEST TRACING
# =============================================================================

@router.get("/trace/{correlation_id}", response_model=TraceResponse)
async def get_request_trace(
    correlation_id: UUID
):
    """
    Get complete trace for a request by correlation ID.
    
    Returns all activities, operations, and errors associated with a single request,
    ordered chronologically. Useful for debugging end-to-end request flow.
    
    Use this when you have a specific correlation_id and want to see everything
    that happened during that request.
    """
    service = get_log_query_service()
    
    trace = await service.get_trace(correlation_id)
    
    if not trace.activities and not trace.operations and not trace.errors:
        raise HTTPException(
            status_code=404,
            detail=f"No logs found for correlation_id: {correlation_id}"
        )
    
    return trace


# =============================================================================
# FULL-TEXT SEARCH
# =============================================================================

@router.get("/search")
async def search_logs(
    q: str = Query(..., min_length=2, description="Search text"),
    user_id: Optional[str] = Query(None, description="Filter by user ID"),
    log_types: Optional[str] = Query(
        None,
        description="Comma-separated log types: activity,operation,error"
    ),
    start_date: Optional[datetime] = Query(None, description="Start date"),
    end_date: Optional[datetime] = Query(None, description="End date"),
    limit: int = Query(50, ge=1, le=200, description="Max results per log type")
):
    """
    Full-text search across all log types.
    
    Searches log content including metadata, messages, and context.
    Returns matching logs grouped by type (activities, operations, errors).
    
    Use this when looking for specific keywords, error messages, or patterns
    across all logs.
    """
    service = get_log_query_service()
    
    # Parse log types
    types_list = None
    if log_types:
        types_list = [t.strip() for t in log_types.split(",")]
    
    results = await service.search_logs(
        search_text=q,
        user_id=user_id,
        log_types=types_list,
        start_date=start_date,
        end_date=end_date,
        limit=limit
    )
    
    return {
        "query": q,
        "results": results,
        "total_matches": sum(len(v) for v in results.values())
    }


# =============================================================================
# GRAFANA ARCHIVE ACCESS
# =============================================================================

@router.get("/archive/csv")
async def list_archived_csv_files(
    log_type: Optional[str] = Query(None, description="Filter by log type (activities, operations, errors)"),
    start_date: Optional[str] = Query(None, description="Start date (YYYY-MM-DD)"),
    end_date: Optional[str] = Query(None, description="End date (YYYY-MM-DD)")
):
    """
    List archived CSV files available for Grafana Infinity plugin.
    
    Returns a list of archived log files with their SAS URLs for direct access
    from Grafana. Each file covers one day of logs for a specific log type.
    
    The SAS URLs are valid for 1 year and can be used directly in Grafana
    Infinity plugin data source configuration.
    """
    from app.services.blob_storage import get_blob_service
    
    blob_service = get_blob_service()
    files = blob_service.list_archived_csv_files(
        log_type=log_type,
        start_date=start_date,
        end_date=end_date
    )
    
    return {
        "files": files,
        "count": len(files),
        "instructions": "Use the sas_url in Grafana Infinity plugin with type='csv'"
    }


@router.get("/archive/grafana-config")
async def get_grafana_infinity_config(
    log_type: Optional[str] = Query(None, description="Filter by log type")
):
    """
    Get Grafana Infinity plugin configuration for archived logs.
    
    Returns pre-configured data source settings for the Grafana Infinity plugin
    to access archived CSV logs. Copy this configuration directly into your
    Grafana setup.
    
    The configuration includes:
    - Plugin installation instructions
    - Data source setup for each log type
    - SAS URLs with long-term validity (1 year)
    """
    from app.services.blob_storage import get_blob_service
    
    blob_service = get_blob_service()
    config = blob_service.get_grafana_infinity_config(log_type=log_type)
    
    return config


# =============================================================================
# LOG FILE READER - DETAILED LOGS BY CORRELATION ID
# =============================================================================

class LogFileEntry(BaseModel):
    """Single log entry from the log file."""
    timestamp: str
    level: str
    correlation_id: str
    user_id: str
    module: str
    location: str
    function: str
    message: str
    line_number: int


class LogFileTraceResponse(BaseModel):
    """Response containing all log entries for a correlation_id from the log file."""
    correlation_id: str
    total_lines: int
    logs: List[LogFileEntry]
    first_timestamp: Optional[str] = None
    last_timestamp: Optional[str] = None
    duration_ms: Optional[int] = None
    levels_summary: dict = {}
    message: Optional[str] = None  # For error/info messages when no logs found


# Log line regex patterns - support both old and new formats
# New format (8 columns): timestamp | level | correlation_id | user_id | module | file:line | function | message
# Old format (7 columns): timestamp | level | correlation_id | module | file:line | function | message
LOG_LINE_PATTERN_NEW = re.compile(
    r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})\s*\|\s*(\w+)\s*\|\s*([^\|]+)\s*\|\s*([^\|]+)\s*\|\s*([^\|]+)\s*\|\s*([^\|]+)\s*\|\s*([^\|]+)\s*\|\s*(.*)$'
)
LOG_LINE_PATTERN_OLD = re.compile(
    r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})\s*\|\s*(\w+)\s*\|\s*([^\|]+)\s*\|\s*([^\|]+)\s*\|\s*([^\|]+)\s*\|\s*([^\|]+)\s*\|\s*(.*)$'
)


def parse_log_line(line: str, line_number: int) -> Optional[LogFileEntry]:
    """
    Parse a single log line into structured data.
    Supports both old format (7 columns) and new format (8 columns).
    
    Returns None if the line doesn't match the expected format.
    """
    # Try new format first (8 columns with user_id)
    match = LOG_LINE_PATTERN_NEW.match(line.strip())
    if match:
        return LogFileEntry(
            timestamp=match.group(1).strip(),
            level=match.group(2).strip(),
            correlation_id=match.group(3).strip(),
            user_id=match.group(4).strip(),
            module=match.group(5).strip(),
            location=match.group(6).strip(),
            function=match.group(7).strip(),
            message=match.group(8).strip(),
            line_number=line_number
        )
    
    # Try old format (7 columns without user_id)
    match = LOG_LINE_PATTERN_OLD.match(line.strip())
    if match:
        return LogFileEntry(
            timestamp=match.group(1).strip(),
            level=match.group(2).strip(),
            correlation_id=match.group(3).strip(),
            user_id="unknown",  # Old format didn't have user_id
            module=match.group(4).strip(),
            location=match.group(5).strip(),
            function=match.group(6).strip(),
            message=match.group(7).strip(),
            line_number=line_number
        )
    
    return None


def get_log_file_path() -> Path:
    """Get the path to the log file."""
    # Try environment variable first
    log_file = os.getenv("LOG_FILE_PATH")
    if log_file:
        return Path(log_file)
    
    # Default location
    return Path(__file__).parent.parent.parent.parent / "notesapp.log"


@router.get("/file/trace/{correlation_id}", response_model=LogFileTraceResponse)
async def get_file_trace(
    correlation_id: str,
    include_context: bool = Query(
        False, 
        description="Include 'system' logs immediately before/after the request (auth, etc.)"
    ),
    context_lines: int = Query(
        10, 
        ge=1, 
        le=50,
        description="Number of context lines before first match (only if include_context=True)"
    ),
    level: Optional[str] = Query(
        None,
        description="Filter by log level: DEBUG, INFO, WARNING, ERROR"
    )
):
    """
    Get detailed logs from the log file for a specific correlation_id.
    
    This reads directly from notesapp.log and returns ALL log entries
    for the specified correlation_id, including:
    - Authentication steps
    - Embedding generation
    - FAISS search with scores
    - Hybrid search combined scores
    - Reranker scores and filtering decisions
    - Final results
    
    **Note**: This only searches the current log file. Rotated logs are not included.
    
    **Parameters**:
    - **correlation_id**: The request correlation ID (UUID format)
    - **include_context**: If True, includes 'system' logs that appear just before 
      the first log entry for this correlation_id (useful for seeing auth flow)
    - **context_lines**: Number of lines before first match to include as context
    - **level**: Filter by specific log level (DEBUG, INFO, WARNING, ERROR)
    
    **Example**: `/api/v1/logs/file/trace/2649b4d0-c40d-4ab1-ac04-928fe1cf5969`
    """
    log_file = get_log_file_path()
    
    if not log_file.exists():
        raise HTTPException(
            status_code=404,
            detail=f"Log file not found: {log_file}"
        )
    
    # Validate correlation_id format (should be UUID or 'system')
    correlation_id = correlation_id.strip()
    if correlation_id != 'system':
        try:
            UUID(correlation_id)
        except ValueError:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid correlation_id format. Expected UUID, got: {correlation_id}"
            )
    
    matching_logs: List[LogFileEntry] = []
    context_buffer: List[LogFileEntry] = []
    first_match_found = False
    first_match_line = None
    
    try:
        with open(log_file, 'r', encoding='utf-8', errors='replace') as f:
            for line_num, line in enumerate(f, 1):
                entry = parse_log_line(line, line_num)
                
                if entry is None:
                    continue
                
                # Check if this line matches our correlation_id
                if entry.correlation_id == correlation_id:
                    if not first_match_found:
                        first_match_found = True
                        first_match_line = line_num
                        
                        # Add context buffer if requested
                        if include_context and context_buffer:
                            matching_logs.extend(context_buffer)
                    
                    # Apply level filter if specified
                    if level is None or entry.level.upper() == level.upper():
                        matching_logs.append(entry)
                else:
                    # Maintain rolling context buffer for 'system' logs
                    if include_context and entry.correlation_id == 'system':
                        context_buffer.append(entry)
                        # Keep only the last N context lines
                        if len(context_buffer) > context_lines:
                            context_buffer.pop(0)
    
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error reading log file: {str(e)}"
        )
    
    # If no logs found, return empty result with message (don't raise 404 for better Grafana compatibility)
    if not matching_logs:
        return LogFileTraceResponse(
            correlation_id=correlation_id,
            total_lines=0,
            logs=[],
            first_timestamp=None,
            last_timestamp=None,
            duration_ms=None,
            levels_summary={},
            message=f"No logs found for correlation_id '{correlation_id}'. The log file may have been rotated or this request is too old."
        )
    
    # Calculate summary
    levels_summary = {}
    for log in matching_logs:
        levels_summary[log.level] = levels_summary.get(log.level, 0) + 1
    
    # Get timestamp range (excluding context lines)
    request_logs = [l for l in matching_logs if l.correlation_id == correlation_id]
    first_ts = request_logs[0].timestamp if request_logs else None
    last_ts = request_logs[-1].timestamp if request_logs else None
    
    # Calculate duration
    duration_ms = None
    if first_ts and last_ts and first_ts != last_ts:
        try:
            from datetime import datetime
            fmt = "%Y-%m-%d %H:%M:%S,%f"
            # Pad milliseconds to microseconds
            first_dt = datetime.strptime(first_ts + "000", fmt)
            last_dt = datetime.strptime(last_ts + "000", fmt)
            duration_ms = int((last_dt - first_dt).total_seconds() * 1000)
        except Exception:
            pass
    
    return LogFileTraceResponse(
        correlation_id=correlation_id,
        total_lines=len(matching_logs),
        logs=matching_logs,
        first_timestamp=first_ts,
        last_timestamp=last_ts,
        duration_ms=duration_ms,
        levels_summary=levels_summary
    )


@router.get("/file/recent")
async def get_recent_file_logs(
    limit: int = Query(100, ge=1, le=1000, description="Number of recent log lines to return"),
    level: Optional[str] = Query(None, description="Filter by log level"),
    correlation_id: Optional[str] = Query(None, description="Filter by correlation_id")
):
    """
    Get the most recent log entries from the log file.
    
    This is useful for debugging and monitoring recent activity.
    Returns logs in reverse chronological order (newest first).
    """
    log_file = get_log_file_path()
    
    if not log_file.exists():
        raise HTTPException(
            status_code=404,
            detail=f"Log file not found: {log_file}"
        )
    
    all_logs: List[LogFileEntry] = []
    
    try:
        with open(log_file, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.readlines()
        
        # Parse from the end
        for line_num in range(len(lines), 0, -1):
            line = lines[line_num - 1]
            entry = parse_log_line(line, line_num)
            
            if entry is None:
                continue
            
            # Apply filters
            if level and entry.level.upper() != level.upper():
                continue
            if correlation_id and entry.correlation_id != correlation_id:
                continue
            
            all_logs.append(entry)
            
            if len(all_logs) >= limit:
                break
    
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error reading log file: {str(e)}"
        )
    
    # Get unique correlation_ids from the results
    unique_correlation_ids = list(set(log.correlation_id for log in all_logs))
    
    return {
        "total_lines": len(all_logs),
        "logs": all_logs,
        "unique_correlation_ids": unique_correlation_ids[:20],  # Limit to 20
        "log_file": str(log_file)
    }


@router.get("/file/correlation-ids")
async def list_correlation_ids(
    limit: int = Query(50, ge=1, le=200, description="Maximum correlation IDs to return"),
    exclude_system: bool = Query(True, description="Exclude 'system' correlation ID")
):
    """
    List recent unique correlation IDs from the log file.
    
    Useful for discovering which correlation IDs are available to trace.
    Returns correlation IDs in order of most recent first.
    """
    log_file = get_log_file_path()
    
    if not log_file.exists():
        raise HTTPException(
            status_code=404,
            detail=f"Log file not found: {log_file}"
        )
    
    correlation_ids = []
    seen = set()
    
    try:
        with open(log_file, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.readlines()
        
        # Parse from the end to get most recent first
        for line_num in range(len(lines), 0, -1):
            line = lines[line_num - 1]
            entry = parse_log_line(line, line_num)
            
            if entry is None:
                continue
            
            cid = entry.correlation_id
            
            if exclude_system and cid == 'system':
                continue
            
            if cid not in seen:
                seen.add(cid)
                correlation_ids.append({
                    "correlation_id": cid,
                    "first_seen_line": line_num,
                    "sample_timestamp": entry.timestamp
                })
                
                if len(correlation_ids) >= limit:
                    break
    
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error reading log file: {str(e)}"
        )
    
    return {
        "correlation_ids": correlation_ids,
        "count": len(correlation_ids),
        "log_file": str(log_file)
    }


# =============================================================================
# WORKER LOGS (Cloudflare Worker Logging) - Stored in Supabase
# =============================================================================

from supabase import create_client
from app.core.config import get_settings

def _get_supabase_client():
    """Get Supabase client for worker logs."""
    settings = get_settings()
    return create_client(settings.supabase_url, settings.supabase_service_key)


class WorkerLogEntry(BaseModel):
    """Log entry from Cloudflare Worker"""
    request_id: str
    timestamp: str
    endpoint: str
    method: str
    user_id: Optional[str] = None
    query: Optional[str] = None
    timing: dict
    result: dict
    error: Optional[str] = None


@router.post("/worker", tags=["Worker Logs"])
async def receive_worker_log(entry: WorkerLogEntry):
    """
    Receive and store logs from Cloudflare Worker.
    
    Logs are stored in Supabase worker_logs table for permanent storage.
    This endpoint is called by the worker after each request.
    """
    try:
        supabase = _get_supabase_client()
        
        # Flatten the timing and result dicts for Supabase columns
        timing = entry.timing or {}
        result = entry.result or {}
        
        # Handle user_id - try to validate as UUID, otherwise store as-is (after table migration to TEXT)
        # For now, if it's not a valid UUID, set to None to avoid DB errors
        user_id_value = None
        if entry.user_id:
            import uuid
            try:
                # Try to parse as UUID
                uuid.UUID(entry.user_id)
                user_id_value = entry.user_id
            except (ValueError, TypeError):
                # Not a UUID - store as-is (requires TEXT column type)
                # Until migration runs, we'll store None to avoid errors
                user_id_value = entry.user_id  # Will work after ALTER TABLE migration
        
        log_data = {
            "request_id": entry.request_id,
            "timestamp": entry.timestamp,
            "endpoint": entry.endpoint,
            "method": entry.method,
            "user_id": user_id_value,
            "query": entry.query,
            "timing_total_ms": timing.get("total_ms"),
            "timing_embedding_ms": timing.get("embedding_ms"),
            "timing_vectorize_ms": timing.get("vectorize_ms"),
            "timing_rerank_ms": timing.get("rerank_ms"),
            "timing_parse_ms": timing.get("parse_ms"),
            "timing_transform_ms": timing.get("transform_ms"),
            "result_match_count": result.get("match_count"),
            "result_rerank_count": result.get("rerank_count"),
            "error": entry.error,
        }
        
        supabase.table("worker_logs").insert(log_data).execute()
        return {"status": "ok", "request_id": entry.request_id, "storage": "supabase"}
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to write worker log to Supabase: {str(e)}"
        )


@router.get("/worker", tags=["Worker Logs"])
async def get_worker_logs(
    limit: int = Query(100, ge=1, le=1000, description="Number of logs to return"),
    endpoint: Optional[str] = Query(None, description="Filter by endpoint"),
    min_duration_ms: Optional[int] = Query(None, description="Min total_ms to include (for slow queries)"),
    hours: int = Query(24, ge=1, le=168, description="Hours of logs to retrieve (max 7 days)")
):
    """
    Read stored worker logs from Supabase for analysis.
    
    Returns the most recent worker logs, optionally filtered.
    """
    from datetime import datetime, timedelta, timezone
    
    try:
        supabase = _get_supabase_client()
        
        # Calculate time range
        since = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
        
        # Build query
        query = supabase.table("worker_logs").select("*").gte("timestamp", since).order("timestamp", desc=True)
        
        # Apply filters
        if endpoint:
            query = query.eq("endpoint", endpoint)
        if min_duration_ms:
            query = query.gte("timing_total_ms", min_duration_ms)
        
        query = query.limit(limit)
        result = query.execute()
        
        # Transform back to original format for compatibility
        logs = []
        for row in result.data:
            logs.append({
                "request_id": row["request_id"],
                "timestamp": row["timestamp"],
                "endpoint": row["endpoint"],
                "method": row["method"],
                "user_id": row["user_id"],
                "query": row["query"],
                "timing": {
                    "total_ms": row["timing_total_ms"],
                    "embedding_ms": row["timing_embedding_ms"],
                    "vectorize_ms": row["timing_vectorize_ms"],
                    "rerank_ms": row["timing_rerank_ms"],
                    "parse_ms": row["timing_parse_ms"],
                    "transform_ms": row["timing_transform_ms"],
                },
                "result": {
                    "match_count": row["result_match_count"],
                    "rerank_count": row["result_rerank_count"],
                },
                "error": row["error"],
            })
        
        return {
            "logs": logs,
            "count": len(logs),
            "storage": "supabase",
            "hours": hours
        }
    
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to read worker logs from Supabase: {str(e)}"
        )


@router.delete("/worker", tags=["Worker Logs"])
async def clear_worker_logs(
    hours: Optional[int] = Query(None, description="Only delete logs older than N hours. If not provided, deletes ALL logs.")
):
    """
    Clear worker logs from Supabase.
    
    Use before running a new batch of concurrent queries for clean analysis.
    If hours is provided, only deletes logs older than that many hours.
    """
    from datetime import datetime, timedelta, timezone
    
    try:
        supabase = _get_supabase_client()
        
        if hours:
            # Delete logs older than specified hours
            cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
            result = supabase.table("worker_logs").delete().lt("timestamp", cutoff).execute()
            return {"status": "cleared", "deleted_before": cutoff, "storage": "supabase"}
        else:
            # Delete all logs - need to use a broad filter since Supabase requires a filter
            result = supabase.table("worker_logs").delete().gte("id", 0).execute()
            return {"status": "cleared", "deleted": "all", "storage": "supabase"}
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to clear worker logs from Supabase: {str(e)}"
        )


@router.get("/worker/stats", tags=["Worker Logs"])
async def get_worker_log_stats(
    hours: int = Query(24, ge=1, le=168, description="Hours of logs to analyze (max 7 days)")
):
    """
    Get aggregate statistics from worker logs stored in Supabase.
    
    Returns timing statistics for bottleneck analysis.
    """
    from datetime import datetime, timedelta, timezone
    from statistics import mean, median, stdev
    
    try:
        supabase = _get_supabase_client()
        
        # Calculate time range
        since = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
        
        # Get all logs in the time range
        result = supabase.table("worker_logs").select("*").gte("timestamp", since).order("timestamp", desc=True).limit(1000).execute()
        
        entries = result.data
        
        if not entries:
            return {"error": "No worker logs found", "hours": hours, "storage": "supabase"}
        
        # Extract timing metrics
        total_times = []
        vectorize_times = []
        embedding_times = []
        rerank_times = []
        errors = []
        
        for entry in entries:
            if entry.get("timing_total_ms"):
                total_times.append(entry["timing_total_ms"])
            if entry.get("timing_vectorize_ms"):
                vectorize_times.append(entry["timing_vectorize_ms"])
            if entry.get("timing_embedding_ms"):
                embedding_times.append(entry["timing_embedding_ms"])
            if entry.get("timing_rerank_ms"):
                rerank_times.append(entry["timing_rerank_ms"])
            if entry.get("error"):
                errors.append(entry)
        
        def calc_stats(values: list, name: str) -> dict:
            if not values:
                return {"name": name, "count": 0}
            return {
                "name": name,
                "count": len(values),
                "min": min(values),
                "max": max(values),
                "mean": round(mean(values), 2),
                "median": round(median(values), 2),
                "stdev": round(stdev(values), 2) if len(values) > 1 else 0,
                "p95": round(sorted(values)[int(len(values) * 0.95)], 2) if len(values) >= 20 else None,
                "p99": round(sorted(values)[int(len(values) * 0.99)], 2) if len(values) >= 100 else None
            }
        
        # Group by endpoint
        endpoint_stats = {}
        for entry in entries:
            ep = entry.get("endpoint", "unknown")
            if ep not in endpoint_stats:
                endpoint_stats[ep] = {"count": 0, "total_ms_sum": 0}
            endpoint_stats[ep]["count"] += 1
            endpoint_stats[ep]["total_ms_sum"] += entry.get("timing_total_ms", 0) or 0
        
        for ep in endpoint_stats:
            if endpoint_stats[ep]["count"] > 0:
                endpoint_stats[ep]["avg_ms"] = round(endpoint_stats[ep]["total_ms_sum"] / endpoint_stats[ep]["count"], 2)
        
        return {
            "total_entries": len(entries),
            "error_count": len(errors),
            "hours_analyzed": hours,
            "storage": "supabase",
            "timing_stats": {
                "total_ms": calc_stats(total_times, "total_ms"),
                "vectorize_ms": calc_stats(vectorize_times, "vectorize_ms"),
                "embedding_ms": calc_stats(embedding_times, "embedding_ms"),
                "rerank_ms": calc_stats(rerank_times, "rerank_ms"),
            },
            "endpoint_stats": endpoint_stats,
            "slow_queries": [
                {"request_id": e.get("request_id"), "total_ms": e.get("timing_total_ms"), "query": e.get("query"), "endpoint": e.get("endpoint")}
                for e in sorted(entries, key=lambda x: x.get("timing_total_ms") or 0, reverse=True)[:10]
            ],
            "errors": [
                {"request_id": e.get("request_id"), "error": e.get("error"), "endpoint": e.get("endpoint")}
                for e in errors[:10]
            ] if errors else []
        }
        
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to get worker log stats from Supabase: {str(e)}"
        )


# =============================================================================
# RECENT LOGS ENDPOINTS FOR DASHBOARD
# =============================================================================

@router.get("/recent-activities", tags=["Dashboard Logs"])
async def get_recent_activities(
    hours: int = Query(24, ge=1, le=168, description="Hours to look back"),
    limit: int = Query(200, ge=1, le=1000, description="Maximum entries to return")
):
    """
    Get recent user activities for dashboard.
    """
    from datetime import datetime, timedelta
    
    try:
        supabase = _get_supabase_client()
        since = (datetime.utcnow() - timedelta(hours=hours)).isoformat()
        
        result = supabase.table("user_activities")\
            .select("*")\
            .gte("created_at", since)\
            .order("created_at", desc=True)\
            .limit(limit)\
            .execute()
        
        return {
            "activities": result.data if result.data else [],
            "count": len(result.data) if result.data else 0,
            "hours": hours
        }
    except Exception as e:
        return {
            "activities": [],
            "count": 0,
            "hours": hours,
            "error": str(e)
        }


# =============================================================================
# ACTIVITY LOGS DASHBOARD ENDPOINTS
# =============================================================================

@router.get("/dashboard/users", tags=["Dashboard Logs"])
async def get_dashboard_users(
    hours: int = Query(24, ge=1, le=168, description="Hours to look back")
):
    """
    Get list of users who have activity in the given time range.
    Returns user_id and activity count for user selection dropdown.
    """
    from datetime import datetime, timedelta
    
    try:
        supabase = _get_supabase_client()
        since = (datetime.utcnow() - timedelta(hours=hours)).isoformat()
        
        # Get all activities and aggregate by user_id
        result = supabase.table("user_activities")\
            .select("user_id")\
            .gte("created_at", since)\
            .execute()
        
        if not result.data:
            return {"users": [], "hours": hours}
        
        # Count activities per user
        user_counts = {}
        for row in result.data:
            uid = row.get("user_id")
            if uid:
                user_counts[uid] = user_counts.get(uid, 0) + 1
        
        # Sort by activity count descending
        users = [
            {"user_id": uid, "activity_count": count}
            for uid, count in sorted(user_counts.items(), key=lambda x: -x[1])
        ]
        
        return {"users": users, "hours": hours}
    except Exception as e:
        return {"users": [], "hours": hours, "error": str(e)}


@router.get("/dashboard/activities", tags=["Dashboard Logs"])
async def get_dashboard_activities(
    user_id: str = Query(..., description="User ID to get activities for"),
    hours: int = Query(24, ge=1, le=168, description="Hours to look back"),
    limit: int = Query(100, ge=1, le=500, description="Maximum activities to return"),
    action: Optional[str] = Query(None, description="Filter by action type")
):
    """
    Get activities for a specific user with full details.
    Returns activities sorted by time (newest first).
    Each activity includes correlation_id for drilling down into detailed logs.
    """
    from datetime import datetime, timedelta
    
    try:
        supabase = _get_supabase_client()
        since = (datetime.utcnow() - timedelta(hours=hours)).isoformat()
        
        query = supabase.table("user_activities")\
            .select("*")\
            .eq("user_id", user_id)\
            .gte("created_at", since)\
            .order("created_at", desc=True)\
            .limit(limit)
        
        if action:
            query = query.eq("action", action)
        
        result = query.execute()
        
        return {
            "activities": result.data if result.data else [],
            "count": len(result.data) if result.data else 0,
            "user_id": user_id,
            "hours": hours
        }
    except Exception as e:
        return {
            "activities": [],
            "count": 0,
            "user_id": user_id,
            "hours": hours,
            "error": str(e)
        }


@router.get("/recent-operations", tags=["Dashboard Logs"])
async def get_recent_operations(
    hours: int = Query(24, ge=1, le=168, description="Hours to look back"),
    limit: int = Query(200, ge=1, le=1000, description="Maximum entries to return")
):
    """
    Get recent operation logs for dashboard.
    """
    from datetime import datetime, timedelta
    
    try:
        supabase = _get_supabase_client()
        since = (datetime.utcnow() - timedelta(hours=hours)).isoformat()
        
        result = supabase.table("operation_logs")\
            .select("*")\
            .gte("created_at", since)\
            .order("created_at", desc=True)\
            .limit(limit)\
            .execute()
        
        return {
            "operations": result.data if result.data else [],
            "count": len(result.data) if result.data else 0,
            "hours": hours
        }
    except Exception as e:
        return {
            "operations": [],
            "count": 0,
            "hours": hours,
            "error": str(e)
        }


@router.get("/recent-errors", tags=["Dashboard Logs"])
async def get_recent_errors(
    hours: int = Query(24, ge=1, le=168, description="Hours to look back"),
    limit: int = Query(100, ge=1, le=500, description="Maximum entries to return")
):
    """
    Get recent error logs for dashboard.
    """
    from datetime import datetime, timedelta
    
    try:
        supabase = _get_supabase_client()
        since = (datetime.utcnow() - timedelta(hours=hours)).isoformat()
        
        result = supabase.table("error_logs")\
            .select("*")\
            .gte("created_at", since)\
            .order("created_at", desc=True)\
            .limit(limit)\
            .execute()
        
        return {
            "errors": result.data if result.data else [],
            "count": len(result.data) if result.data else 0,
            "hours": hours
        }
    except Exception as e:
        return {
            "errors": [],
            "count": 0,
            "hours": hours,
            "error": str(e)
        }


# =============================================================================
# SEARCH TRACE STORAGE AND RETRIEVAL
# =============================================================================

class SearchTraceRequest(BaseModel):
    """Request body for storing a search trace from the Worker."""
    correlation_id: str
    user_id: str
    query: str
    query_corrected: Optional[str] = None
    
    # Complete timing breakdown
    timing_total_ms: Optional[int] = None
    timing_spell_check_ms: Optional[int] = None
    timing_tags_fetch_ms: Optional[int] = None
    timing_embedding_ms: Optional[int] = None
    timing_vector_search_ms: Optional[int] = None
    timing_keyword_search_ms: Optional[int] = None
    timing_rerank_ms: Optional[int] = None
    timing_relevance_check_ms: Optional[int] = None
    timing_synthesis_ms: Optional[int] = None
    timing_worker_ms: Optional[int] = None
    
    # Cache status
    embedding_cached: bool = False
    search_cached: bool = False
    tags_cached: Optional[bool] = None
    synthesis_cached: Optional[bool] = None
    
    # Chunk grouping info (top 3 per doc)
    chunks_before_grouping: Optional[int] = None
    chunks_after_grouping: Optional[int] = None
    unique_documents: Optional[int] = None
    chunks_per_doc_limit: Optional[int] = None
    
    # Dedup after LLM verification
    dedup_before_count: Optional[int] = None
    dedup_after_count: Optional[int] = None
    dedup_removed: Optional[int] = None
    
    # Candidates at each stage
    vector_candidates: Optional[List[dict]] = None
    keyword_candidates: Optional[List[dict]] = None
    combined_candidates: Optional[List[dict]] = None
    reranked_candidates: Optional[List[dict]] = None
    relevance_verified_candidates: Optional[List[dict]] = None
    final_results: Optional[List[dict]] = None
    
    # Counts
    vector_count: Optional[int] = None
    keyword_count: Optional[int] = None
    combined_count: Optional[int] = None
    reranked_count: Optional[int] = None
    relevance_verified_count: Optional[int] = None
    final_count: Optional[int] = None
    
    # Thresholds
    min_vector_threshold: Optional[float] = None
    min_rerank_threshold: Optional[float] = None
    
    # Source info
    source_worker: Optional[str] = None
    request_path: Optional[str] = None


class BackendTraceUpdate(BaseModel):
    """Request body for updating search trace with backend data."""
    correlation_id: str
    
    # Spell check
    spell_check_original: Optional[str] = None
    spell_check_corrected: Optional[str] = None
    spell_check_was_corrected: bool = False
    spell_check_explanation: Optional[str] = None
    spell_check_duration_ms: Optional[int] = None
    
    # Tag detection
    tags_available: Optional[List[str]] = None
    tags_detected: Optional[List[str]] = None
    tag_intent: Optional[str] = None  # 'list_all' or 'specific'
    tags_cache_hit: bool = False
    tags_fetch_duration_ms: Optional[int] = None
    
    # Query analysis
    query_intent: Optional[str] = None
    query_complexity: Optional[str] = None
    query_keywords: Optional[List[str]] = None
    query_needs_synthesis: bool = False
    query_analysis_duration_ms: Optional[int] = None
    
    # Circuit breaker
    circuit_breaker_open: bool = False
    circuit_breaker_avg_latency_ms: Optional[int] = None
    
    # Synthesis cache
    synthesis_cache_hit: bool = False
    synthesis_cache_key: Optional[str] = None
    synthesis_duration_ms: Optional[int] = None
    
    # LLM calls
    llm_calls: Optional[List[dict]] = None
    
    # Agent steps
    agent_steps: Optional[List[dict]] = None
    
    # Backend metadata
    backend_metadata: Optional[dict] = None
    timing_fly_ms: Optional[int] = None


@router.post("/search-trace", tags=["Search Traces"])
async def store_search_trace(trace: SearchTraceRequest):
    """
    Store a detailed search trace from the Worker.
    This endpoint is called by the Worker to persist all search execution data.
    """
    import json
    
    try:
        supabase = _get_supabase_client()
        
        # Build the record with complete timing and candidate data
        record = {
            "correlation_id": trace.correlation_id,
            "user_id": trace.user_id,
            "query": trace.query,
            "query_corrected": trace.query_corrected,
            # Complete timing breakdown
            "timing_total_ms": trace.timing_total_ms,
            "timing_spell_check_ms": trace.timing_spell_check_ms,
            "timing_tags_fetch_ms": trace.timing_tags_fetch_ms,
            "timing_embedding_ms": trace.timing_embedding_ms,
            "timing_vector_search_ms": trace.timing_vector_search_ms,
            "timing_keyword_search_ms": trace.timing_keyword_search_ms,
            "timing_rerank_ms": trace.timing_rerank_ms,
            "timing_relevance_check_ms": trace.timing_relevance_check_ms,
            "timing_synthesis_ms": trace.timing_synthesis_ms,
            "timing_worker_ms": trace.timing_worker_ms,
            # Cache status
            "embedding_cached": trace.embedding_cached,
            "search_cached": trace.search_cached,
            "tags_cached": trace.tags_cached,
            "synthesis_cached": trace.synthesis_cached,
            # Chunk grouping info (top 3 per doc)
            "chunks_before_grouping": trace.chunks_before_grouping,
            "chunks_after_grouping": trace.chunks_after_grouping,
            "unique_documents": trace.unique_documents,
            "chunks_per_doc_limit": trace.chunks_per_doc_limit,
            # Dedup after LLM verification
            "dedup_before_count": trace.dedup_before_count,
            "dedup_after_count": trace.dedup_after_count,
            "dedup_removed": trace.dedup_removed,
            # Candidates at each stage
            "vector_candidates": trace.vector_candidates,
            "keyword_candidates": trace.keyword_candidates,
            "combined_candidates": trace.combined_candidates,
            "reranked_candidates": trace.reranked_candidates,
            "relevance_verified_candidates": trace.relevance_verified_candidates,
            "final_results": trace.final_results,
            # Counts
            "vector_count": trace.vector_count or (len(trace.vector_candidates) if trace.vector_candidates else 0),
            "keyword_count": trace.keyword_count or (len(trace.keyword_candidates) if trace.keyword_candidates else 0),
            "combined_count": trace.combined_count or (len(trace.combined_candidates) if trace.combined_candidates else 0),
            "reranked_count": trace.reranked_count or (len(trace.reranked_candidates) if trace.reranked_candidates else 0),
            "relevance_verified_count": trace.relevance_verified_count or (len([v for v in (trace.relevance_verified_candidates or []) if v.get('passed_verification')]) if trace.relevance_verified_candidates else 0),
            "final_count": trace.final_count or (len(trace.final_results) if trace.final_results else 0),
            # Thresholds
            "min_vector_threshold": trace.min_vector_threshold,
            "min_rerank_threshold": trace.min_rerank_threshold,
            # Source info
            "source_worker": trace.source_worker,
            "request_path": trace.request_path,
        }
        
        result = supabase.table("search_traces").insert(record).execute()
        
        return {
            "success": True,
            "trace_id": result.data[0]["id"] if result.data else None,
            "correlation_id": trace.correlation_id
        }
    except Exception as e:
        # Log error but don't fail - this is fire-and-forget from Worker
        print(f"Failed to store search trace: {e}")
        return {
            "success": False,
            "error": str(e),
            "correlation_id": trace.correlation_id
        }


class ExtensionTimingRequest(BaseModel):
    """Request body for logging Chrome extension timing data."""
    correlation_id: str
    query: str
    timing_total_flow_ms: int
    timing_settings_check_ms: Optional[int] = None
    timing_backend_search_ms: Optional[int] = None
    timing_notification_ms: Optional[int] = None
    timing_delay_ms: Optional[int] = None
    timing_backend_reported_ms: Optional[int] = None
    results_count: Optional[int] = None
    source: str = "chrome-extension"


@router.post("/extension-timing", tags=["Search Traces"])
async def log_extension_timing(timing: ExtensionTimingRequest):
    """
    Log Chrome extension timing data and update the search trace.
    This helps identify bottlenecks between backend response and notification display.
    """
    try:
        supabase = _get_supabase_client()
        
        # Update the existing search trace with extension timing data
        update_data = {
            "extension_total_flow_ms": timing.timing_total_flow_ms,
            "extension_settings_check_ms": timing.timing_settings_check_ms,
            "extension_backend_search_ms": timing.timing_backend_search_ms,
            "extension_notification_ms": timing.timing_notification_ms,
            "extension_delay_ms": timing.timing_delay_ms,
            "extension_source": timing.source
        }
        
        # Try to update by correlation_id (which is worker_request_id)
        result = supabase.table("search_traces").update(update_data).eq(
            "correlation_id", timing.correlation_id
        ).execute()
        
        # Calculate the discrepancy
        backend_reported = timing.timing_backend_reported_ms or 0
        total_flow = timing.timing_total_flow_ms
        overhead = total_flow - backend_reported if backend_reported > 0 else 0
        
        print(f"[Extension Timing] {timing.correlation_id}: Total={total_flow}ms, Backend={backend_reported}ms, Overhead={overhead}ms")
        
        return {
            "success": True,
            "correlation_id": timing.correlation_id,
            "timing_overhead_ms": overhead
        }
    except Exception as e:
        print(f"Failed to log extension timing: {e}")
        return {
            "success": False,
            "error": str(e),
            "correlation_id": timing.correlation_id
        }


@router.patch("/search-trace/{correlation_id}", tags=["Search Traces"])
async def update_search_trace_backend(correlation_id: str, update: BackendTraceUpdate):
    """
    Update a search trace with backend (Fly.io) data.
    Called by the backend after Worker stores initial trace.
    This adds spell check, tag detection, circuit breaker, synthesis cache, agent steps, etc.
    """
    try:
        supabase = _get_supabase_client()
        
        # Build update record - only include non-None values
        record = {}
        
        # Spell check
        if update.spell_check_original:
            record["spell_check_original"] = update.spell_check_original
        if update.spell_check_corrected:
            record["spell_check_corrected"] = update.spell_check_corrected
        record["spell_check_was_corrected"] = update.spell_check_was_corrected
        if update.spell_check_explanation:
            record["spell_check_explanation"] = update.spell_check_explanation
        if update.spell_check_duration_ms:
            record["spell_check_duration_ms"] = update.spell_check_duration_ms
        
        # Tags
        if update.tags_available:
            record["tags_available"] = update.tags_available
        if update.tags_detected:
            record["tags_detected"] = update.tags_detected
        if update.tag_intent:
            record["tag_intent"] = update.tag_intent
        record["tags_cache_hit"] = update.tags_cache_hit
        if update.tags_fetch_duration_ms:
            record["tags_fetch_duration_ms"] = update.tags_fetch_duration_ms
        
        # Query analysis
        if update.query_intent:
            record["query_intent"] = update.query_intent
        if update.query_complexity:
            record["query_complexity"] = update.query_complexity
        if update.query_keywords:
            record["query_keywords"] = update.query_keywords
        record["query_needs_synthesis"] = update.query_needs_synthesis
        if update.query_analysis_duration_ms:
            record["query_analysis_duration_ms"] = update.query_analysis_duration_ms
        
        # Circuit breaker
        record["circuit_breaker_open"] = update.circuit_breaker_open
        if update.circuit_breaker_avg_latency_ms:
            record["circuit_breaker_avg_latency_ms"] = update.circuit_breaker_avg_latency_ms
        
        # Synthesis cache
        record["synthesis_cache_hit"] = update.synthesis_cache_hit
        if update.synthesis_cache_key:
            record["synthesis_cache_key"] = update.synthesis_cache_key
        if update.synthesis_duration_ms:
            record["synthesis_duration_ms"] = update.synthesis_duration_ms
        
        # LLM calls
        if update.llm_calls:
            record["llm_calls"] = update.llm_calls
        
        # Agent steps
        if update.agent_steps:
            record["agent_steps"] = update.agent_steps
        
        # Backend metadata
        if update.backend_metadata:
            record["backend_metadata"] = update.backend_metadata
        if update.timing_fly_ms:
            record["timing_fly_ms"] = update.timing_fly_ms
        
        record["source_backend"] = "fly-io"
        
        result = supabase.table("search_traces")\
            .update(record)\
            .eq("correlation_id", correlation_id)\
            .execute()
        
        if not result.data:
            # Trace doesn't exist yet - Worker hasn't stored it
            # This can happen if backend is faster than Worker async POST
            print(f"No trace found to update for correlation_id: {correlation_id}")
            return {
                "success": False,
                "error": "Trace not found - Worker may not have stored it yet",
                "correlation_id": correlation_id
            }
        
        return {
            "success": True,
            "correlation_id": correlation_id,
            "updated_fields": list(record.keys())
        }
    except Exception as e:
        print(f"Failed to update search trace with backend data: {e}")
        return {
            "success": False,
            "error": str(e),
            "correlation_id": correlation_id
        }


@router.get("/search-trace/{correlation_id}", tags=["Search Traces"])
async def get_search_trace(correlation_id: str):
    """
    Get the detailed search trace for a specific correlation_id.
    Returns all intermediate data from the search pipeline.
    """
    try:
        supabase = _get_supabase_client()
        
        result = supabase.table("search_traces")\
            .select("*")\
            .eq("correlation_id", correlation_id)\
            .execute()
        
        if not result.data:
            raise HTTPException(
                status_code=404,
                detail=f"No search trace found for correlation_id: {correlation_id}"
            )
        
        return result.data[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/search-traces/user/{user_id}", tags=["Search Traces"])
async def get_user_search_traces(
    user_id: str,
    hours: int = Query(24, ge=1, le=168, description="Hours to look back"),
    limit: int = Query(50, ge=1, le=200, description="Maximum traces to return")
):
    """
    Get search traces for a specific user.
    Returns summary info - use /search-trace/{correlation_id} for full details.
    """
    from datetime import datetime, timedelta
    
    try:
        supabase = _get_supabase_client()
        since = (datetime.utcnow() - timedelta(hours=hours)).isoformat()
        
        result = supabase.table("search_traces")\
            .select("id,correlation_id,query,timing_total_ms,final_count,embedding_cached,created_at")\
            .eq("user_id", user_id)\
            .gte("created_at", since)\
            .order("created_at", desc=True)\
            .limit(limit)\
            .execute()
        
        return {
            "traces": result.data if result.data else [],
            "count": len(result.data) if result.data else 0,
            "user_id": user_id,
            "hours": hours
        }
    except Exception as e:
        return {
            "traces": [],
            "count": 0,
            "user_id": user_id,
            "hours": hours,
            "error": str(e)
        }
