"""
Metrics Service
Aggregates and calculates metrics for the monitoring dashboard.
Provides hourly aggregation, performance percentiles, and trend analysis.
"""
import logging
from datetime import datetime, timedelta
from typing import Optional, List, Dict, Any
from collections import defaultdict

from supabase import create_client, Client

from app.core.config import get_settings
from app.models.log_schemas import (
    DashboardOverview, ActivityTimeline, TimeSeriesPoint,
    ErrorBreakdown, PerformanceMetrics, UsageStats,
    EndpointMetrics, ServiceHealthStatus, SystemHealth
)

logger = logging.getLogger(__name__)


class MetricsService:
    """
    Service for aggregating metrics and providing dashboard data.
    
    Features:
    - Real-time metrics from log tables
    - Hourly pre-aggregation for performance
    - Trend analysis comparing time periods
    - Service health monitoring
    """
    
    def __init__(self):
        settings = get_settings()
        self.supabase: Client = create_client(
            settings.supabase_url,
            settings.supabase_service_key
        )
    
    # =========================================================================
    # DASHBOARD OVERVIEW
    # =========================================================================
    
    async def get_dashboard_overview(
        self,
        period: str = "last_24h"
    ) -> DashboardOverview:
        """
        Get main dashboard overview with key metrics.
        
        Args:
            period: Time period - 'last_hour', 'last_24h', 'last_7d'
        
        Returns:
            DashboardOverview with key metrics and trends
        """
        # Calculate time ranges
        now = datetime.utcnow()
        current_start, current_end = self._get_time_range(period, now)
        previous_start, previous_end = self._get_previous_period(period, current_start)
        
        # Get current period metrics
        current_metrics = await self._get_period_metrics(current_start, current_end)
        
        # Get previous period for trends
        previous_metrics = await self._get_period_metrics(previous_start, previous_end)
        
        # Calculate trends
        request_trend = self._calculate_trend(
            current_metrics["total_requests"],
            previous_metrics["total_requests"]
        )
        error_trend = self._calculate_trend(
            current_metrics["error_count"],
            previous_metrics["error_count"]
        )
        latency_trend = self._calculate_trend(
            current_metrics["avg_latency"],
            previous_metrics["avg_latency"]
        )
        
        # Calculate rates
        total = current_metrics["total_requests"]
        success_rate = (current_metrics["success_count"] / total * 100) if total > 0 else 100
        error_rate = (current_metrics["error_count"] / total * 100) if total > 0 else 0
        
        return DashboardOverview(
            period=period,
            generated_at=now,
            total_requests=total,
            success_rate=round(success_rate, 2),
            error_rate=round(error_rate, 2),
            avg_latency_ms=round(current_metrics["avg_latency"], 2),
            active_users=current_metrics["active_users"],
            notes_created=current_metrics["notes_created"],
            searches_performed=current_metrics["searches_performed"],
            errors_count=current_metrics["error_count"],
            request_trend=request_trend,
            error_trend=error_trend,
            latency_trend=latency_trend
        )
    
    async def _get_period_metrics(
        self,
        start: datetime,
        end: datetime
    ) -> Dict[str, Any]:
        """Get aggregated metrics for a time period."""
        metrics = {
            "total_requests": 0,
            "success_count": 0,
            "error_count": 0,
            "avg_latency": 0,
            "active_users": 0,
            "notes_created": 0,
            "searches_performed": 0
        }
        
        try:
            # Query activities
            result = self.supabase.table("user_activities")\
                .select("*")\
                .gte("created_at", start.isoformat())\
                .lte("created_at", end.isoformat())\
                .execute()
            
            activities = result.data or []
            metrics["total_requests"] = len(activities)
            
            users = set()
            total_duration = 0
            duration_count = 0
            
            for activity in activities:
                users.add(activity["user_id"])
                
                if activity["status"] == "success":
                    metrics["success_count"] += 1
                elif activity["status"] == "error":
                    metrics["error_count"] += 1
                
                if activity.get("duration_ms"):
                    total_duration += activity["duration_ms"]
                    duration_count += 1
                
                action = activity["action"]
                if action in ("upload_file", "upload_screenshot", "create_quick_note"):
                    metrics["notes_created"] += 1
                elif action == "search_notes":
                    metrics["searches_performed"] += 1
            
            metrics["active_users"] = len(users)
            metrics["avg_latency"] = total_duration / duration_count if duration_count > 0 else 0
            
        except Exception as e:
            logger.error(f"Failed to get period metrics: {e}")
        
        return metrics
    
    # =========================================================================
    # ACTIVITY TIMELINE
    # =========================================================================
    
    async def get_activity_timeline(
        self,
        period: str = "last_24h",
        interval: str = "hour"
    ) -> ActivityTimeline:
        """
        Get activity timeline for visualization.
        
        Args:
            period: Time period
            interval: Aggregation interval - 'hour' or 'day'
        
        Returns:
            ActivityTimeline with time series data
        """
        now = datetime.utcnow()
        start, end = self._get_time_range(period, now)
        
        try:
            result = self.supabase.table("user_activities")\
                .select("action, created_at")\
                .gte("created_at", start.isoformat())\
                .lte("created_at", end.isoformat())\
                .execute()
            
            # Aggregate by time bucket
            buckets = defaultdict(lambda: defaultdict(int))
            
            for activity in result.data or []:
                created_at = datetime.fromisoformat(
                    activity["created_at"].replace("Z", "+00:00")
                ).replace(tzinfo=None)
                
                if interval == "hour":
                    bucket = created_at.replace(minute=0, second=0, microsecond=0)
                else:
                    bucket = created_at.replace(hour=0, minute=0, second=0, microsecond=0)
                
                buckets[bucket]["total"] += 1
                buckets[bucket][activity["action"]] += 1
            
            # Build time series
            data_points = []
            by_action = defaultdict(list)
            
            for bucket in sorted(buckets.keys()):
                data_points.append(TimeSeriesPoint(
                    timestamp=bucket,
                    value=buckets[bucket]["total"]
                ))
                
                for action, count in buckets[bucket].items():
                    if action != "total":
                        by_action[action].append(TimeSeriesPoint(
                            timestamp=bucket,
                            value=count
                        ))
            
            return ActivityTimeline(
                period=period,
                interval=interval,
                data_points=data_points,
                by_action=dict(by_action)
            )
            
        except Exception as e:
            logger.error(f"Failed to get activity timeline: {e}")
            return ActivityTimeline(
                period=period,
                interval=interval,
                data_points=[],
                by_action={}
            )
    
    # =========================================================================
    # ERROR BREAKDOWN
    # =========================================================================
    
    async def get_error_breakdown(
        self,
        period: str = "last_24h"
    ) -> ErrorBreakdown:
        """Get detailed error breakdown."""
        now = datetime.utcnow()
        start, end = self._get_time_range(period, now)
        
        try:
            # Get errors
            result = self.supabase.table("error_logs")\
                .select("error_type, error_code, context")\
                .gte("created_at", start.isoformat())\
                .lte("created_at", end.isoformat())\
                .execute()
            
            errors = result.data or []
            
            by_type = defaultdict(int)
            by_code = defaultdict(int)
            by_endpoint = defaultdict(int)
            
            for error in errors:
                by_type[error["error_type"]] += 1
                by_code[error["error_code"]] += 1
                
                context = error.get("context", {})
                if "endpoint" in context:
                    by_endpoint[context["endpoint"]] += 1
            
            # Sort and limit top endpoints
            top_endpoints = [
                {"endpoint": k, "count": v}
                for k, v in sorted(by_endpoint.items(), key=lambda x: x[1], reverse=True)[:10]
            ]
            
            return ErrorBreakdown(
                total_errors=len(errors),
                by_type=dict(by_type),
                by_error_code=dict(by_code),
                top_endpoints=top_endpoints
            )
            
        except Exception as e:
            logger.error(f"Failed to get error breakdown: {e}")
            return ErrorBreakdown(
                total_errors=0,
                by_type={},
                by_error_code={},
                top_endpoints=[]
            )
    
    # =========================================================================
    # PERFORMANCE METRICS
    # =========================================================================
    
    async def get_performance_metrics(
        self,
        period: str = "last_24h"
    ) -> PerformanceMetrics:
        """Get performance metrics with percentiles."""
        now = datetime.utcnow()
        start, end = self._get_time_range(period, now)
        
        try:
            # Get activities with duration
            result = self.supabase.table("user_activities")\
                .select("action, duration_ms, metadata")\
                .gte("created_at", start.isoformat())\
                .lte("created_at", end.isoformat())\
                .not_.is_("duration_ms", "null")\
                .execute()
            
            activities = result.data or []
            
            if not activities:
                return PerformanceMetrics(
                    period=period,
                    avg_latency_ms=0,
                    p50_ms=0,
                    p95_ms=0,
                    p99_ms=0,
                    slowest_endpoints=[]
                )
            
            # Calculate overall percentiles
            durations = sorted([a["duration_ms"] for a in activities if a["duration_ms"]])
            
            p50 = self._percentile(durations, 50)
            p95 = self._percentile(durations, 95)
            p99 = self._percentile(durations, 99)
            avg = sum(durations) / len(durations)
            
            # Calculate per-endpoint metrics
            endpoint_durations = defaultdict(list)
            for activity in activities:
                metadata = activity.get("metadata", {})
                path = metadata.get("path", activity["action"])
                method = metadata.get("method", "POST")
                endpoint_durations[(path, method)].append(activity["duration_ms"])
            
            slowest_endpoints = []
            for (path, method), durs in endpoint_durations.items():
                sorted_durs = sorted(durs)
                slowest_endpoints.append(EndpointMetrics(
                    endpoint=path,
                    method=method,
                    total_requests=len(durs),
                    success_count=len(durs),  # Simplified
                    error_count=0,
                    avg_duration_ms=sum(durs) / len(durs),
                    p50_duration_ms=self._percentile(sorted_durs, 50),
                    p95_duration_ms=self._percentile(sorted_durs, 95),
                    p99_duration_ms=self._percentile(sorted_durs, 99)
                ))
            
            # Sort by p95
            slowest_endpoints.sort(key=lambda x: x.p95_duration_ms or 0, reverse=True)
            
            return PerformanceMetrics(
                period=period,
                avg_latency_ms=round(avg, 2),
                p50_ms=p50,
                p95_ms=p95,
                p99_ms=p99,
                slowest_endpoints=slowest_endpoints[:10]
            )
            
        except Exception as e:
            logger.error(f"Failed to get performance metrics: {e}")
            return PerformanceMetrics(
                period=period,
                avg_latency_ms=0,
                p50_ms=0,
                p95_ms=0,
                p99_ms=0,
                slowest_endpoints=[]
            )
    
    # =========================================================================
    # USAGE STATS
    # =========================================================================
    
    async def get_usage_stats(
        self,
        period: str = "last_24h"
    ) -> UsageStats:
        """Get detailed usage statistics."""
        now = datetime.utcnow()
        start, end = self._get_time_range(period, now)
        
        try:
            result = self.supabase.table("user_activities")\
                .select("*")\
                .gte("created_at", start.isoformat())\
                .lte("created_at", end.isoformat())\
                .execute()
            
            activities = result.data or []
            
            # Count by action
            action_counts = defaultdict(lambda: {"success": 0, "error": 0, "total": 0})
            user_counts = defaultdict(int)
            
            files_uploaded = 0
            screenshots = 0
            quick_notes = 0
            searches = 0
            notes_deleted = 0
            
            for activity in activities:
                action = activity["action"]
                status = activity["status"]
                user_id = activity["user_id"]
                
                action_counts[action]["total"] += 1
                action_counts[action][status] += 1
                user_counts[user_id] += 1
                
                if action == "upload_file":
                    files_uploaded += 1
                elif action == "upload_screenshot":
                    screenshots += 1
                elif action == "create_quick_note":
                    quick_notes += 1
                elif action == "search_notes":
                    searches += 1
                elif action == "delete_note":
                    notes_deleted += 1
            
            # Build endpoint metrics
            by_endpoint = []
            for action, counts in action_counts.items():
                by_endpoint.append(EndpointMetrics(
                    endpoint=action,
                    method="POST",
                    total_requests=counts["total"],
                    success_count=counts["success"],
                    error_count=counts["error"],
                    avg_duration_ms=0
                ))
            
            by_endpoint.sort(key=lambda x: x.total_requests, reverse=True)
            
            # Build user stats
            by_user = [
                {"user_id": uid, "request_count": count}
                for uid, count in sorted(user_counts.items(), key=lambda x: x[1], reverse=True)[:20]
            ]
            
            return UsageStats(
                period=period,
                total_requests=len(activities),
                unique_users=len(user_counts),
                notes_created=files_uploaded + screenshots + quick_notes,
                files_uploaded=files_uploaded,
                screenshots_captured=screenshots,
                quick_notes_created=quick_notes,
                searches_performed=searches,
                notes_deleted=notes_deleted,
                by_endpoint=by_endpoint[:20],
                by_user=by_user
            )
            
        except Exception as e:
            logger.error(f"Failed to get usage stats: {e}")
            return UsageStats(
                period=period,
                total_requests=0,
                unique_users=0,
                notes_created=0,
                files_uploaded=0,
                screenshots_captured=0,
                quick_notes_created=0,
                searches_performed=0,
                notes_deleted=0,
                by_endpoint=[],
                by_user=[]
            )
    
    # =========================================================================
    # SERVICE HEALTH
    # =========================================================================
    
    async def get_system_health(self) -> SystemHealth:
        """Get health status of all services."""
        now = datetime.utcnow()
        one_hour_ago = now - timedelta(hours=1)
        
        services = ["blob_storage", "tensorlake", "embeddings", "notes_db", "html_cleaner"]
        health_statuses = []
        
        try:
            # Get recent operation logs
            result = self.supabase.table("operation_logs")\
                .select("service, status, duration_ms, created_at")\
                .gte("created_at", one_hour_ago.isoformat())\
                .execute()
            
            operations = result.data or []
            
            # Aggregate by service
            service_stats = defaultdict(lambda: {
                "total": 0, "success": 0, "error": 0,
                "durations": [], "last_success": None, "last_error": None
            })
            
            for op in operations:
                service = op["service"]
                stats = service_stats[service]
                stats["total"] += 1
                
                created_at = datetime.fromisoformat(
                    op["created_at"].replace("Z", "+00:00")
                ).replace(tzinfo=None)
                
                if op["status"] == "success":
                    stats["success"] += 1
                    if not stats["last_success"] or created_at > stats["last_success"]:
                        stats["last_success"] = created_at
                else:
                    stats["error"] += 1
                    if not stats["last_error"] or created_at > stats["last_error"]:
                        stats["last_error"] = created_at
                
                if op.get("duration_ms"):
                    stats["durations"].append(op["duration_ms"])
            
            # Build health statuses
            for service in services:
                stats = service_stats.get(service, {
                    "total": 0, "success": 0, "error": 0,
                    "durations": [], "last_success": None, "last_error": None
                })
                
                # Determine status
                if stats["total"] == 0:
                    status = "unknown"
                elif stats["error"] == 0:
                    status = "healthy"
                elif stats["error"] / stats["total"] < 0.1:
                    status = "healthy"
                elif stats["error"] / stats["total"] < 0.3:
                    status = "degraded"
                else:
                    status = "unhealthy"
                
                error_rate = (stats["error"] / stats["total"] * 100) if stats["total"] > 0 else 0
                avg_latency = sum(stats["durations"]) / len(stats["durations"]) if stats["durations"] else None
                
                health_statuses.append(ServiceHealthStatus(
                    service=service,
                    status=status,
                    last_success=stats["last_success"],
                    last_error=stats["last_error"],
                    error_rate_1h=round(error_rate, 2),
                    avg_latency_ms=round(avg_latency, 2) if avg_latency else None
                ))
            
            # Determine overall status
            statuses = [h.status for h in health_statuses]
            if "unhealthy" in statuses:
                overall = "unhealthy"
            elif "degraded" in statuses:
                overall = "degraded"
            else:
                overall = "healthy"
            
            return SystemHealth(
                overall_status=overall,
                services=health_statuses,
                last_updated=now
            )
            
        except Exception as e:
            logger.error(f"Failed to get system health: {e}")
            return SystemHealth(
                overall_status="unknown",
                services=[],
                last_updated=now
            )
    
    # =========================================================================
    # HOURLY AGGREGATION (for background job)
    # =========================================================================
    
    async def aggregate_hourly_metrics(
        self,
        target_hour: Optional[datetime] = None
    ) -> Dict[str, Any]:
        """
        Aggregate metrics for a specific hour into api_metrics_hourly table.
        Run this as a background job every hour.
        """
        if target_hour is None:
            # Aggregate previous hour
            now = datetime.utcnow()
            target_hour = now.replace(minute=0, second=0, microsecond=0) - timedelta(hours=1)
        
        hour_start = target_hour
        hour_end = target_hour + timedelta(hours=1)
        
        try:
            # Get activities for the hour
            result = self.supabase.table("user_activities")\
                .select("action, status, duration_ms, metadata")\
                .gte("created_at", hour_start.isoformat())\
                .lt("created_at", hour_end.isoformat())\
                .execute()
            
            activities = result.data or []
            
            # Aggregate by endpoint
            endpoint_stats = defaultdict(lambda: {
                "total": 0, "success": 0, "error": 0, "durations": []
            })
            
            for activity in activities:
                metadata = activity.get("metadata", {})
                path = metadata.get("path", f"/{activity['action']}")
                method = metadata.get("method", "POST")
                key = (path, method)
                
                endpoint_stats[key]["total"] += 1
                if activity["status"] == "success":
                    endpoint_stats[key]["success"] += 1
                else:
                    endpoint_stats[key]["error"] += 1
                
                if activity.get("duration_ms"):
                    endpoint_stats[key]["durations"].append(activity["duration_ms"])
            
            # Insert/update aggregated metrics
            records_upserted = 0
            for (endpoint, method), stats in endpoint_stats.items():
                durations = sorted(stats["durations"]) if stats["durations"] else []
                
                metric_data = {
                    "hour": hour_start.isoformat(),
                    "endpoint": endpoint,
                    "method": method,
                    "total_requests": stats["total"],
                    "success_count": stats["success"],
                    "error_count": stats["error"],
                    "total_duration_ms": sum(durations),
                    "min_duration_ms": min(durations) if durations else None,
                    "max_duration_ms": max(durations) if durations else None,
                    "p50_duration_ms": self._percentile(durations, 50) if durations else None,
                    "p95_duration_ms": self._percentile(durations, 95) if durations else None,
                    "p99_duration_ms": self._percentile(durations, 99) if durations else None
                }
                
                # Upsert
                self.supabase.table("api_metrics_hourly")\
                    .upsert(metric_data, on_conflict="hour,endpoint,method")\
                    .execute()
                
                records_upserted += 1
            
            logger.info(f"Aggregated {records_upserted} endpoint metrics for {hour_start}")
            
            return {
                "hour": hour_start.isoformat(),
                "endpoints_aggregated": records_upserted,
                "total_activities": len(activities)
            }
            
        except Exception as e:
            logger.error(f"Failed to aggregate hourly metrics: {e}")
            return {"error": str(e)}
    
    # =========================================================================
    # HELPERS
    # =========================================================================
    
    def _get_time_range(
        self,
        period: str,
        now: datetime
    ) -> tuple[datetime, datetime]:
        """Get start and end datetime for a period."""
        if period == "last_hour":
            return now - timedelta(hours=1), now
        elif period == "last_24h":
            return now - timedelta(hours=24), now
        elif period == "last_7d":
            return now - timedelta(days=7), now
        elif period == "last_30d":
            return now - timedelta(days=30), now
        else:
            return now - timedelta(hours=24), now
    
    def _get_previous_period(
        self,
        period: str,
        current_start: datetime
    ) -> tuple[datetime, datetime]:
        """Get the previous period for trend comparison."""
        if period == "last_hour":
            delta = timedelta(hours=1)
        elif period == "last_24h":
            delta = timedelta(hours=24)
        elif period == "last_7d":
            delta = timedelta(days=7)
        else:
            delta = timedelta(hours=24)
        
        return current_start - delta, current_start
    
    def _calculate_trend(
        self,
        current: float,
        previous: float
    ) -> Optional[float]:
        """Calculate percentage change between periods."""
        if previous == 0:
            return None if current == 0 else 100.0
        return round((current - previous) / previous * 100, 2)
    
    def _percentile(self, sorted_data: List[float], p: int) -> float:
        """Calculate percentile from sorted data."""
        if not sorted_data:
            return 0
        k = (len(sorted_data) - 1) * p / 100
        f = int(k)
        c = f + 1 if f + 1 < len(sorted_data) else f
        return sorted_data[f] + (sorted_data[c] - sorted_data[f]) * (k - f)


# =============================================================================
# SINGLETON
# =============================================================================

_metrics_service: Optional[MetricsService] = None


def get_metrics_service() -> MetricsService:
    """Get the singleton MetricsService instance."""
    global _metrics_service
    if _metrics_service is None:
        _metrics_service = MetricsService()
    return _metrics_service
