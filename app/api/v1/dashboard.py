"""
Dashboard API Endpoints
Provides REST API for monitoring dashboard with metrics, charts, and health status.
"""
from datetime import datetime, timedelta

from fastapi import APIRouter, Query

from app.services.metrics_service import get_metrics_service
from app.models.log_schemas import (
    ActivityTimeline, PerformanceMetrics, SystemHealth
)

router = APIRouter(prefix="/dashboard", tags=["Dashboard"])


# =============================================================================
# QUICK SUMMARY (Main Dashboard View)
# =============================================================================

@router.get("/summary")
async def get_quick_summary(
    period: str = Query("last_24h", description="Time period: last_hour, last_24h, last_7d, last_30d")
):
    """
    Get a comprehensive summary for dashboard widgets.
    
    Combines key metrics from multiple sources into a single response
    optimized for dashboard cards/widgets.
    
    Returns:
    - **requests**: Total count, success rate, trend
    - **latency**: Average latency with trend
    - **errors**: Error count, rate, top error type
    - **usage**: Active users, notes created, searches
    - **health**: Overall status, healthy service count
    """
    service = get_metrics_service()
    
    overview = await service.get_dashboard_overview(period)
    errors = await service.get_error_breakdown(period)
    health = await service.get_system_health()
    
    return {
        "period": period,
        "generated_at": datetime.utcnow().isoformat(),
        "requests": {
            "total": overview.total_requests,
            "success_rate": overview.success_rate,
            "trend": overview.request_trend
        },
        "latency": {
            "avg_ms": overview.avg_latency_ms,
            "trend": overview.latency_trend
        },
        "errors": {
            "total": errors.total_errors,
            "rate": overview.error_rate,
            "trend": overview.error_trend,
            "top_type": max(errors.by_type.items(), key=lambda x: x[1])[0] if errors.by_type else None
        },
        "usage": {
            "active_users": overview.active_users,
            "notes_created": overview.notes_created,
            "searches": overview.searches_performed
        },
        "health": {
            "status": health.overall_status,
            "services_healthy": sum(1 for s in health.services if s.status == "healthy"),
            "services_total": len(health.services)
        }
    }


# =============================================================================
# ACTIVITY TIMELINE (For Charts)
# =============================================================================

@router.get("/activity", response_model=ActivityTimeline)
async def get_activity_timeline(
    period: str = Query("last_24h", description="Time period"),
    interval: str = Query("hour", description="Aggregation interval: hour or day")
):
    """
    Get activity timeline for charts/graphs.
    
    Returns time series data points for total activity and breakdown by action type.
    Useful for visualizing activity patterns over time.
    """
    service = get_metrics_service()
    return await service.get_activity_timeline(period, interval)


# =============================================================================
# PERFORMANCE METRICS
# =============================================================================

@router.get("/performance", response_model=PerformanceMetrics)
async def get_performance_metrics(
    period: str = Query("last_24h", description="Time period")
):
    """
    Get performance metrics with latency percentiles.
    
    Returns:
    - Average, P50, P95, P99 latency
    - Slowest endpoints with their latency breakdown
    """
    service = get_metrics_service()
    return await service.get_performance_metrics(period)


# =============================================================================
# SYSTEM HEALTH
# =============================================================================

@router.get("/health", response_model=SystemHealth)
async def get_system_health():
    """
    Get health status of all services.
    
    Returns:
    - Overall system status (healthy, degraded, unhealthy)
    - Per-service status with error rates and latency
    - Last success/error timestamps
    """
    service = get_metrics_service()
    return await service.get_system_health()


# =============================================================================
# CACHE & CIRCUIT BREAKER STATS
# =============================================================================

@router.get("/cache-stats")
async def get_cache_stats():
    """
    Get statistics for all caches and circuit breaker.
    
    Returns:
    - Synthesis cache: size, TTL, hit rate
    - API key cache: size, TTL
    - Circuit breaker: status, avg response time
    """
    from app.services.rag_agent import get_synthesis_cache_stats, get_circuit_breaker_stats
    from app.services.auth_service import get_api_key_cache_stats
    
    return {
        "synthesis_cache": get_synthesis_cache_stats(),
        "api_key_cache": get_api_key_cache_stats(),
        "circuit_breaker": get_circuit_breaker_stats()
    }


# =============================================================================
# REALTIME METRICS (For Live Updates)
# =============================================================================

@router.get("/realtime")
async def get_realtime_metrics():
    """
    Get real-time metrics for live dashboard updates.
    
    Returns metrics for the last 5 minutes, suitable for frequent polling.
    Includes current request count, success/error counts, average latency,
    and active users.
    """
    service = get_metrics_service()
    
    # Get last 5 minutes of data
    now = datetime.utcnow()
    start = now - timedelta(minutes=5)
    
    metrics = await service._get_period_metrics(start, now)
    
    return {
        "timestamp": now.isoformat(),
        "window_minutes": 5,
        "requests": metrics["total_requests"],
        "success": metrics["success_count"],
        "errors": metrics["error_count"],
        "avg_latency_ms": round(metrics["avg_latency"], 2),
        "active_users": metrics["active_users"]
    }
