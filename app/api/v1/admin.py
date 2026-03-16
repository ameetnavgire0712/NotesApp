"""
Admin API Endpoints
Provides administrative operations like log archival, metrics aggregation, and system management.
"""
from datetime import datetime
from typing import Optional, List

from fastapi import APIRouter, Query, HTTPException, BackgroundTasks

from app.services.log_archival_service import get_archival_service
from app.services.metrics_service import get_metrics_service
from app.models.log_schemas import ArchivalJobResponse

router = APIRouter(prefix="/admin", tags=["Admin"])


# =============================================================================
# LOG ARCHIVAL
# =============================================================================

@router.post("/archive-logs", response_model=ArchivalJobResponse)
async def trigger_log_archival(
    target_date: Optional[str] = Query(
        None,
        description="Specific date to archive (YYYY-MM-DD). If not provided, archives all eligible dates."
    ),
    tables: Optional[str] = Query(
        None,
        description="Comma-separated table names to archive. If not provided, archives all tables."
    )
):
    """
    Trigger log archival job.
    
    Archives logs older than 30 days from Supabase to Azure Blob Storage.
    This operation:
    1. Queries records older than 30 days
    2. Writes them to blob storage as JSONL files
    3. Deletes archived records from Supabase
    
    Run this daily via cron job or manually as needed.
    """
    service = get_archival_service()
    
    # Parse tables if provided
    table_list = None
    if tables:
        table_list = [t.strip() for t in tables.split(",")]
    
    result = await service.run_archival(
        target_date=target_date,
        tables=table_list
    )
    
    return result


@router.get("/archive-history")
async def get_archival_history(
    limit: int = Query(50, ge=1, le=200, description="Maximum results"),
    status: Optional[str] = Query(None, description="Filter by status: completed, failed, in_progress")
):
    """
    Get history of archival jobs.
    
    Returns recent archival job records for monitoring and debugging.
    """
    service = get_archival_service()
    history = await service.get_archival_history(limit=limit, status_filter=status)
    return {
        "history": history,
        "total": len(history)
    }


@router.get("/archive-stats")
async def get_archival_stats():
    """
    Get archival statistics.
    
    Returns summary of archival jobs: total jobs, success/failure counts,
    total records archived.
    """
    service = get_archival_service()
    return await service.get_archival_stats()


# =============================================================================
# METRICS AGGREGATION
# =============================================================================

@router.post("/aggregate-metrics")
async def trigger_metrics_aggregation(
    background_tasks: BackgroundTasks,
    target_hour: Optional[str] = Query(
        None,
        description="Specific hour to aggregate (ISO format). If not provided, aggregates previous hour."
    )
):
    """
    Trigger hourly metrics aggregation.
    
    Aggregates activity logs into api_metrics_hourly table for faster dashboard queries.
    Run this hourly via cron job or manually.
    """
    service = get_metrics_service()
    
    hour = None
    if target_hour:
        try:
            hour = datetime.fromisoformat(target_hour)
        except ValueError:
            raise HTTPException(
                status_code=400,
                detail="Invalid target_hour format. Use ISO format (e.g., 2026-01-13T10:00:00)"
            )
    
    # Run in background
    background_tasks.add_task(service.aggregate_hourly_metrics, hour)
    
    return {
        "status": "started",
        "target_hour": target_hour or "previous_hour",
        "message": "Metrics aggregation started in background"
    }


# =============================================================================
# SYSTEM MANAGEMENT
# =============================================================================

@router.get("/system-info")
async def get_system_info():
    """
    Get system information and configuration status.
    """
    from app.core.config import get_settings
    
    settings = get_settings()
    
    return {
        "version": "1.0.0",
        "timestamp": datetime.utcnow().isoformat(),
        "services": {
            "azure_blob": "configured" if settings.azure_storage_connection_string else "missing",
            "supabase": "configured" if settings.supabase_url else "missing",
            "tensorlake": "configured" if settings.tensorlake_api_key else "missing",
            "openai": "configured" if settings.openai_api_key else "missing",
            "groq": "configured" if settings.groq_api_key else "optional"
        },
        "logging": {
            "archive_threshold_days": 30,
            "tables": ["user_activities", "operation_logs", "error_logs"]
        }
    }


@router.post("/flush-logs")
async def flush_log_buffers():
    """
    Force flush all log buffers to storage.
    
    Use this before shutdown or when you need logs persisted immediately.
    """
    try:
        from app.services.logging_service import get_logging_service
        service = get_logging_service()
        await service.flush()
        
        return {
            "status": "success",
            "message": "All log buffers flushed to storage"
        }
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to flush logs: {str(e)}"
        )


@router.delete("/clear-old-metrics")
async def clear_old_metrics(
    days: int = Query(90, ge=7, le=365, description="Delete metrics older than this many days")
):
    """
    Clear old aggregated metrics from api_metrics_hourly table.
    
    Helps manage database size by removing old aggregated data.
    Raw logs should be archived via archive-logs endpoint.
    """
    from datetime import timedelta
    from supabase import create_client
    from app.core.config import get_settings
    
    settings = get_settings()
    supabase = create_client(settings.supabase_url, settings.supabase_service_key)
    
    cutoff = datetime.utcnow() - timedelta(days=days)
    
    try:
        # Count first
        count_result = supabase.table("api_metrics_hourly")\
            .select("id", count="exact")\
            .lt("hour", cutoff.isoformat())\
            .execute()
        
        count = count_result.count or 0
        
        if count > 0:
            # Delete old metrics
            supabase.table("api_metrics_hourly")\
                .delete()\
                .lt("hour", cutoff.isoformat())\
                .execute()
        
        return {
            "status": "success",
            "deleted_count": count,
            "cutoff_date": cutoff.isoformat()
        }
        
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to clear old metrics: {str(e)}"
        )
