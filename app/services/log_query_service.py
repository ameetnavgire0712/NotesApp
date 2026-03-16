"""
Log Query Service
Provides unified querying across Supabase (hot storage) and Azure Blob Storage (archived).
Supports filtering, full-text search, and correlation ID tracing.
"""
import json
import logging
from datetime import datetime, timedelta
from typing import Optional, List, Dict, Any
from uuid import UUID

from supabase import create_client, Client

from app.core.config import get_settings
from app.services.blob_storage import get_blob_service
from app.models.log_schemas import (
    ActivityLog, OperationLog, ErrorLog,
    LogQueryParams, ActivityLogResponse, OperationLogResponse, 
    ErrorLogResponse, TraceResponse
)

logger = logging.getLogger(__name__)


class LogQueryService:
    """
    Service for querying logs from both Supabase and Blob Storage.
    
    - Recent logs (< 30 days): Query from Supabase
    - Archived logs (>= 30 days): Query from Blob Storage
    - Supports unified queries across both sources
    """
    
    ARCHIVE_THRESHOLD_DAYS = 30
    
    def __init__(self):
        settings = get_settings()
        self.supabase: Client = create_client(
            settings.supabase_url,
            settings.supabase_service_key
        )
        self.blob_service = get_blob_service()
    
    def _get_archive_cutoff_date(self) -> datetime:
        """Get the date before which logs are archived."""
        return datetime.utcnow() - timedelta(days=self.ARCHIVE_THRESHOLD_DAYS)
    
    def _needs_blob_search(self, start_date: Optional[datetime]) -> bool:
        """Check if we need to search blob storage based on date range."""
        if not start_date:
            return False  # Default to Supabase only for recent queries
        return start_date < self._get_archive_cutoff_date()
    
    # =========================================================================
    # ACTIVITY LOGS
    # =========================================================================
    
    async def query_activities(
        self,
        params: LogQueryParams
    ) -> ActivityLogResponse:
        """
        Query user activity logs.
        
        Args:
            params: Query parameters
        
        Returns:
            ActivityLogResponse with logs and pagination info
        """
        logs = []
        total_count = 0
        
        # Query Supabase for recent logs
        supabase_logs, supabase_count = await self._query_supabase_activities(params)
        logs.extend(supabase_logs)
        total_count += supabase_count
        
        # Query blob storage for archived logs if needed
        if params.include_archived and self._needs_blob_search(params.start_date):
            blob_logs = await self._query_blob_activities(params)
            logs.extend(blob_logs)
            total_count += len(blob_logs)
        
        # Sort by timestamp descending
        logs.sort(key=lambda x: x.timestamp, reverse=True)
        
        # Apply pagination
        paginated_logs = logs[params.offset:params.offset + params.limit]
        
        return ActivityLogResponse(
            logs=paginated_logs,
            total_count=total_count,
            has_more=total_count > params.offset + params.limit,
            query_params=params
        )
    
    async def _query_supabase_activities(
        self,
        params: LogQueryParams
    ) -> tuple[List[ActivityLog], int]:
        """Query activity logs from Supabase."""
        try:
            query = self.supabase.table("user_activities").select("*", count="exact")
            
            # Apply filters
            if params.user_id:
                query = query.eq("user_id", params.user_id)
            if params.correlation_id:
                query = query.eq("correlation_id", str(params.correlation_id))
            if params.action:
                query = query.eq("action", params.action)
            if params.resource_type:
                query = query.eq("resource_type", params.resource_type)
            if params.status:
                query = query.eq("status", params.status)
            if params.start_date:
                query = query.gte("created_at", params.start_date.isoformat())
            if params.end_date:
                query = query.lte("created_at", params.end_date.isoformat())
            
            # Order and paginate
            query = query.order("created_at", desc=True)
            query = query.range(params.offset, params.offset + params.limit - 1)
            
            result = query.execute()
            
            logs = []
            for row in result.data or []:
                logs.append(ActivityLog(
                    id=UUID(row["id"]),
                    correlation_id=UUID(row["correlation_id"]),
                    timestamp=datetime.fromisoformat(row["created_at"].replace("Z", "+00:00")),
                    user_id=row["user_id"],
                    action=row["action"],
                    resource_type=row.get("resource_type"),
                    resource_id=UUID(row["resource_id"]) if row.get("resource_id") else None,
                    status=row["status"],
                    duration_ms=row.get("duration_ms"),
                    metadata=row.get("metadata", {})
                ))
            
            return logs, result.count or len(logs)
            
        except Exception as e:
            logger.error(f"Failed to query Supabase activities: {e}")
            return [], 0
    
    async def _query_blob_activities(
        self,
        params: LogQueryParams
    ) -> List[ActivityLog]:
        """Query activity logs from blob storage."""
        logs = []
        
        try:
            # Determine which user folders to search
            user_ids = [params.user_id] if params.user_id else await self._get_all_user_ids()
            
            for user_id in user_ids:
                # List activity log files
                files = await self.blob_service.list_log_files(
                    user_id=user_id,
                    log_type="activities",
                    include_archived=True,
                    start_date=params.start_date.strftime("%Y-%m-%d") if params.start_date else None,
                    end_date=params.end_date.strftime("%Y-%m-%d") if params.end_date else None
                )
                
                for file_info in files:
                    entries = await self.blob_service.download_log_file(file_info["blob_name"])
                    
                    for entry in entries:
                        # Apply filters
                        if params.action and entry.get("action") != params.action:
                            continue
                        if params.status and entry.get("status") != params.status:
                            continue
                        if params.search_text and params.search_text.lower() not in json.dumps(entry).lower():
                            continue
                        
                        try:
                            logs.append(ActivityLog(
                                id=UUID(entry["id"]) if entry.get("id") else None,
                                correlation_id=UUID(entry["correlation_id"]),
                                timestamp=datetime.fromisoformat(entry["timestamp"]),
                                user_id=entry["user_id"],
                                action=entry["action"],
                                resource_type=entry.get("resource_type"),
                                resource_id=UUID(entry["resource_id"]) if entry.get("resource_id") else None,
                                status=entry["status"],
                                duration_ms=entry.get("duration_ms"),
                                metadata=entry.get("metadata", {})
                            ))
                        except Exception as parse_error:
                            logger.warning(f"Failed to parse activity log entry: {parse_error}")
            
        except Exception as e:
            logger.error(f"Failed to query blob activities: {e}")
        
        return logs
    
    # =========================================================================
    # OPERATION LOGS
    # =========================================================================
    
    async def query_operations(
        self,
        params: LogQueryParams
    ) -> OperationLogResponse:
        """Query operation logs."""
        logs = []
        total_count = 0
        
        # Query Supabase
        supabase_logs, supabase_count = await self._query_supabase_operations(params)
        logs.extend(supabase_logs)
        total_count += supabase_count
        
        # Query blob storage if needed
        if params.include_archived and self._needs_blob_search(params.start_date):
            blob_logs = await self._query_blob_operations(params)
            logs.extend(blob_logs)
            total_count += len(blob_logs)
        
        logs.sort(key=lambda x: x.timestamp, reverse=True)
        paginated_logs = logs[params.offset:params.offset + params.limit]
        
        return OperationLogResponse(
            logs=paginated_logs,
            total_count=total_count,
            has_more=total_count > params.offset + params.limit,
            query_params=params
        )
    
    async def _query_supabase_operations(
        self,
        params: LogQueryParams
    ) -> tuple[List[OperationLog], int]:
        """Query operation logs from Supabase."""
        try:
            query = self.supabase.table("operation_logs").select("*", count="exact")
            
            if params.correlation_id:
                query = query.eq("correlation_id", str(params.correlation_id))
            if params.service:
                query = query.eq("service", params.service)
            if params.status:
                query = query.eq("status", params.status)
            if params.start_date:
                query = query.gte("created_at", params.start_date.isoformat())
            if params.end_date:
                query = query.lte("created_at", params.end_date.isoformat())
            
            query = query.order("created_at", desc=True)
            query = query.range(params.offset, params.offset + params.limit - 1)
            
            result = query.execute()
            
            logs = []
            for row in result.data or []:
                logs.append(OperationLog(
                    id=UUID(row["id"]),
                    correlation_id=UUID(row["correlation_id"]),
                    timestamp=datetime.fromisoformat(row["created_at"].replace("Z", "+00:00")),
                    service=row["service"],
                    operation=row["operation"],
                    status=row["status"],
                    duration_ms=row.get("duration_ms"),
                    input_summary=row.get("input_summary", {}),
                    output_summary=row.get("output_summary", {})
                ))
            
            return logs, result.count or len(logs)
            
        except Exception as e:
            logger.error(f"Failed to query Supabase operations: {e}")
            return [], 0
    
    async def _query_blob_operations(
        self,
        params: LogQueryParams
    ) -> List[OperationLog]:
        """Query operation logs from blob storage."""
        logs = []
        
        try:
            files = await self.blob_service.list_log_files(
                user_id="_system",
                log_type="operations",
                include_archived=True,
                start_date=params.start_date.strftime("%Y-%m-%d") if params.start_date else None,
                end_date=params.end_date.strftime("%Y-%m-%d") if params.end_date else None
            )
            
            for file_info in files:
                entries = await self.blob_service.download_log_file(file_info["blob_name"])
                
                for entry in entries:
                    if params.service and entry.get("service") != params.service:
                        continue
                    if params.status and entry.get("status") != params.status:
                        continue
                    
                    try:
                        logs.append(OperationLog(
                            id=UUID(entry["id"]) if entry.get("id") else None,
                            correlation_id=UUID(entry["correlation_id"]),
                            timestamp=datetime.fromisoformat(entry["timestamp"]),
                            service=entry["service"],
                            operation=entry["operation"],
                            status=entry["status"],
                            duration_ms=entry.get("duration_ms"),
                            input_summary=entry.get("input_summary", {}),
                            output_summary=entry.get("output_summary", {})
                        ))
                    except Exception as parse_error:
                        logger.warning(f"Failed to parse operation log entry: {parse_error}")
            
        except Exception as e:
            logger.error(f"Failed to query blob operations: {e}")
        
        return logs
    
    # =========================================================================
    # ERROR LOGS
    # =========================================================================
    
    async def query_errors(
        self,
        params: LogQueryParams
    ) -> ErrorLogResponse:
        """Query error logs."""
        logs = []
        total_count = 0
        
        supabase_logs, supabase_count = await self._query_supabase_errors(params)
        logs.extend(supabase_logs)
        total_count += supabase_count
        
        if params.include_archived and self._needs_blob_search(params.start_date):
            blob_logs = await self._query_blob_errors(params)
            logs.extend(blob_logs)
            total_count += len(blob_logs)
        
        logs.sort(key=lambda x: x.timestamp, reverse=True)
        paginated_logs = logs[params.offset:params.offset + params.limit]
        
        return ErrorLogResponse(
            logs=paginated_logs,
            total_count=total_count,
            has_more=total_count > params.offset + params.limit,
            query_params=params
        )
    
    async def _query_supabase_errors(
        self,
        params: LogQueryParams
    ) -> tuple[List[ErrorLog], int]:
        """Query error logs from Supabase."""
        try:
            query = self.supabase.table("error_logs").select("*", count="exact")
            
            if params.user_id:
                query = query.eq("user_id", params.user_id)
            if params.correlation_id:
                query = query.eq("correlation_id", str(params.correlation_id))
            if params.error_type:
                query = query.eq("error_type", params.error_type)
            if params.start_date:
                query = query.gte("created_at", params.start_date.isoformat())
            if params.end_date:
                query = query.lte("created_at", params.end_date.isoformat())
            
            query = query.order("created_at", desc=True)
            query = query.range(params.offset, params.offset + params.limit - 1)
            
            result = query.execute()
            
            logs = []
            for row in result.data or []:
                logs.append(ErrorLog(
                    id=UUID(row["id"]),
                    correlation_id=UUID(row["correlation_id"]) if row.get("correlation_id") else None,
                    timestamp=datetime.fromisoformat(row["created_at"].replace("Z", "+00:00")),
                    user_id=row.get("user_id"),
                    error_code=row["error_code"],
                    error_type=row["error_type"],
                    message=row["message"],
                    stack_trace=row.get("stack_trace"),
                    context=row.get("context", {})
                ))
            
            return logs, result.count or len(logs)
            
        except Exception as e:
            logger.error(f"Failed to query Supabase errors: {e}")
            return [], 0
    
    async def _query_blob_errors(
        self,
        params: LogQueryParams
    ) -> List[ErrorLog]:
        """Query error logs from blob storage."""
        logs = []
        
        try:
            # Search both user-specific and system error logs
            user_ids = [params.user_id] if params.user_id else ["_system"]
            if not params.user_id:
                user_ids.extend(await self._get_all_user_ids())
            
            for user_id in user_ids:
                files = await self.blob_service.list_log_files(
                    user_id=user_id,
                    log_type="errors",
                    include_archived=True,
                    start_date=params.start_date.strftime("%Y-%m-%d") if params.start_date else None,
                    end_date=params.end_date.strftime("%Y-%m-%d") if params.end_date else None
                )
                
                for file_info in files:
                    entries = await self.blob_service.download_log_file(file_info["blob_name"])
                    
                    for entry in entries:
                        if params.error_type and entry.get("error_type") != params.error_type:
                            continue
                        
                        try:
                            logs.append(ErrorLog(
                                id=UUID(entry["id"]) if entry.get("id") else None,
                                correlation_id=UUID(entry["correlation_id"]) if entry.get("correlation_id") else None,
                                timestamp=datetime.fromisoformat(entry["timestamp"]),
                                user_id=entry.get("user_id"),
                                error_code=entry["error_code"],
                                error_type=entry["error_type"],
                                message=entry["message"],
                                stack_trace=entry.get("stack_trace"),
                                context=entry.get("context", {})
                            ))
                        except Exception as parse_error:
                            logger.warning(f"Failed to parse error log entry: {parse_error}")
            
        except Exception as e:
            logger.error(f"Failed to query blob errors: {e}")
        
        return logs
    
    # =========================================================================
    # TRACE BY CORRELATION ID
    # =========================================================================
    
    async def get_trace(self, correlation_id: UUID) -> TraceResponse:
        """
        Get complete trace for a request by correlation ID.
        Queries all log types and merges results.
        """
        params = LogQueryParams(
            correlation_id=correlation_id,
            include_archived=True,
            limit=1000
        )
        
        # Query all log types
        activities_response = await self.query_activities(params)
        operations_response = await self.query_operations(params)
        errors_response = await self.query_errors(params)
        
        # Calculate total duration
        all_timestamps = []
        for log in activities_response.logs:
            all_timestamps.append(log.timestamp)
        for log in operations_response.logs:
            all_timestamps.append(log.timestamp)
        for log in errors_response.logs:
            all_timestamps.append(log.timestamp)
        
        start_time = min(all_timestamps) if all_timestamps else None
        end_time = max(all_timestamps) if all_timestamps else None
        total_duration = int((end_time - start_time).total_seconds() * 1000) if start_time and end_time else None
        
        return TraceResponse(
            correlation_id=correlation_id,
            activities=activities_response.logs,
            operations=operations_response.logs,
            errors=errors_response.logs,
            total_duration_ms=total_duration,
            start_time=start_time,
            end_time=end_time
        )
    
    # =========================================================================
    # FULL-TEXT SEARCH
    # =========================================================================
    
    async def search_logs(
        self,
        search_text: str,
        user_id: Optional[str] = None,
        log_types: Optional[List[str]] = None,
        start_date: Optional[datetime] = None,
        end_date: Optional[datetime] = None,
        limit: int = 100
    ) -> Dict[str, List[Any]]:
        """
        Full-text search across all log types.
        
        Args:
            search_text: Text to search for
            user_id: Optional user ID filter
            log_types: Optional list of log types to search ('activity', 'operation', 'error')
            start_date: Optional start date
            end_date: Optional end date
            limit: Maximum results per log type
        
        Returns:
            Dict with 'activities', 'operations', 'errors' keys
        """
        results = {
            "activities": [],
            "operations": [],
            "errors": []
        }
        
        log_types = log_types or ["activity", "operation", "error"]
        
        params = LogQueryParams(
            user_id=user_id,
            search_text=search_text,
            start_date=start_date,
            end_date=end_date,
            include_archived=True,
            limit=limit
        )
        
        if "activity" in log_types:
            response = await self.query_activities(params)
            # Filter by search text (Supabase doesn't support full-text on JSONB easily)
            results["activities"] = [
                log for log in response.logs
                if search_text.lower() in json.dumps(log.model_dump(), default=str).lower()
            ][:limit]
        
        if "operation" in log_types:
            response = await self.query_operations(params)
            results["operations"] = [
                log for log in response.logs
                if search_text.lower() in json.dumps(log.model_dump(), default=str).lower()
            ][:limit]
        
        if "error" in log_types:
            response = await self.query_errors(params)
            results["errors"] = [
                log for log in response.logs
                if search_text.lower() in json.dumps(log.model_dump(), default=str).lower()
            ][:limit]
        
        return results
    
    # =========================================================================
    # HELPERS
    # =========================================================================
    
    async def _get_all_user_ids(self) -> List[str]:
        """Get all unique user IDs from recent activity logs."""
        try:
            result = self.supabase.table("user_activities")\
                .select("user_id")\
                .limit(1000)\
                .execute()
            
            user_ids = set()
            for row in result.data or []:
                user_ids.add(row["user_id"])
            
            return list(user_ids)
        except Exception:
            return ["default_user"]
    
    # =========================================================================
    # USER ACTIVITY LOG (COMBINED VIEW)
    # =========================================================================
    
    async def get_user_activity_log(
        self,
        user_id: str,
        start_date: Optional[datetime] = None,
        end_date: Optional[datetime] = None,
        include_archived: bool = False,
        limit: int = 100,
        offset: int = 0
    ) -> Dict[str, Any]:
        """
        Get comprehensive activity log for a user.
        
        Returns all activities with their associated operations and errors,
        grouped by correlation_id for easy tracing.
        
        Args:
            user_id: The user ID to query
            start_date: Optional start date filter
            end_date: Optional end date filter
            include_archived: Whether to include archived logs from blob storage
            limit: Maximum number of activities to return
            offset: Pagination offset
        
        Returns:
            Dict with activities, each containing operations and errors
        """
        # Query activities for this user
        params = LogQueryParams(
            user_id=user_id,
            start_date=start_date,
            end_date=end_date,
            include_archived=include_archived,
            limit=limit,
            offset=offset
        )
        
        activities_response = await self.query_activities(params)
        
        # Get unique correlation IDs from activities
        correlation_ids = [str(a.correlation_id) for a in activities_response.logs]
        unique_corr_ids = list(set(correlation_ids))
        
        # Batch query operations and errors for all correlation IDs at once
        operations_by_corr_id: Dict[str, List] = {cid: [] for cid in unique_corr_ids}
        errors_by_corr_id: Dict[str, List] = {cid: [] for cid in unique_corr_ids}
        
        if unique_corr_ids:
            # Batch query operations - single query with IN clause
            try:
                ops_result = self.supabase.table("operation_logs") \
                    .select("*") \
                    .in_("correlation_id", unique_corr_ids) \
                    .order("created_at", desc=True) \
                    .execute()
                
                for row in ops_result.data or []:
                    corr_id = row.get("correlation_id")
                    if corr_id in operations_by_corr_id:
                        operations_by_corr_id[corr_id].append({
                            "id": row.get("id"),
                            "service": row.get("service"),
                            "operation": row.get("operation"),
                            "status": row.get("status"),
                            "duration_ms": row.get("duration_ms"),
                            "input_summary": row.get("input_summary", {}),
                            "output_summary": row.get("output_summary", {}),
                            "timestamp": row.get("created_at")
                        })
            except Exception as e:
                logger.error(f"Failed to batch query operations: {e}")
            
            # Batch query errors - single query with IN clause
            try:
                err_result = self.supabase.table("error_logs") \
                    .select("*") \
                    .in_("correlation_id", unique_corr_ids) \
                    .order("created_at", desc=True) \
                    .execute()
                
                for row in err_result.data or []:
                    corr_id = row.get("correlation_id")
                    if corr_id in errors_by_corr_id:
                        errors_by_corr_id[corr_id].append({
                            "id": row.get("id"),
                            "error_type": row.get("error_type"),
                            "error_code": row.get("error_code"),
                            "error_message": row.get("error_message"),
                            "endpoint": row.get("endpoint"),
                            "timestamp": row.get("created_at")
                        })
            except Exception as e:
                logger.error(f"Failed to batch query errors: {e}")
        
        # Build combined response
        activity_logs = []
        for activity in activities_response.logs:
            corr_id_str = str(activity.correlation_id)
            activity_logs.append({
                "id": str(activity.id) if activity.id else None,
                "correlation_id": corr_id_str,
                "timestamp": activity.timestamp.isoformat(),
                "action": activity.action,
                "resource_type": activity.resource_type,
                "resource_id": str(activity.resource_id) if activity.resource_id else None,
                "status": activity.status,
                "duration_ms": activity.duration_ms,
                "metadata": activity.metadata,
                "operations": operations_by_corr_id.get(corr_id_str, []),
                "errors": errors_by_corr_id.get(corr_id_str, [])
            })
        
        # Get summary stats
        total_operations = sum(len(ops) for ops in operations_by_corr_id.values())
        total_errors = sum(len(errs) for errs in errors_by_corr_id.values())
        success_count = sum(1 for a in activities_response.logs if a.status == "success")
        error_count = sum(1 for a in activities_response.logs if a.status == "error")
        
        return {
            "user_id": user_id,
            "period": {
                "start": start_date.isoformat() if start_date else None,
                "end": end_date.isoformat() if end_date else None
            },
            "summary": {
                "total_activities": activities_response.total_count,
                "total_operations": total_operations,
                "total_errors": total_errors,
                "success_count": success_count,
                "error_count": error_count,
                "success_rate": round(success_count / len(activities_response.logs) * 100, 2) if activities_response.logs else 0
            },
            "activities": activity_logs,
            "pagination": {
                "limit": limit,
                "offset": offset,
                "has_more": activities_response.has_more
            }
        }


# =============================================================================
# SINGLETON
# =============================================================================

_log_query_service: Optional[LogQueryService] = None


def get_log_query_service() -> LogQueryService:
    """Get the singleton LogQueryService instance."""
    global _log_query_service
    if _log_query_service is None:
        _log_query_service = LogQueryService()
    return _log_query_service
