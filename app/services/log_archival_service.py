"""
Log Archival Service
Moves logs older than 30 days from Supabase to Azure Blob Storage.
Tracks archival progress for reliability and restartability.
"""
import json
import logging
from datetime import datetime, timedelta
from typing import Optional, List, Dict, Any
from uuid import UUID, uuid4

from supabase import create_client, Client

from app.core.config import get_settings
from app.services.blob_storage import get_blob_service
from app.models.log_schemas import ArchivalStatus, ArchivalJobResponse

logger = logging.getLogger(__name__)


class LogArchivalService:
    """
    Service for archiving logs from Supabase to Azure Blob Storage.
    
    Features:
    - Archives logs older than 30 days
    - Batches records by user and date
    - Tracks progress for reliability
    - Supports manual and scheduled archival
    """
    
    ARCHIVE_THRESHOLD_DAYS = 30
    BATCH_SIZE = 1000  # Records per batch
    
    ARCHIVABLE_TABLES = [
        ("user_activities", "user_id", "activities"),
        ("operation_logs", None, "operations"),  # No user_id, use _system
        ("error_logs", "user_id", "errors"),
    ]
    
    def __init__(self):
        settings = get_settings()
        self.supabase: Client = create_client(
            settings.supabase_url,
            settings.supabase_service_key
        )
        self.blob_service = get_blob_service()
    
    def _get_archive_cutoff_date(self) -> datetime:
        """Get the cutoff date for archival (30 days ago)."""
        return datetime.utcnow() - timedelta(days=self.ARCHIVE_THRESHOLD_DAYS)
    
    async def run_archival(
        self,
        target_date: Optional[str] = None,
        tables: Optional[List[str]] = None
    ) -> ArchivalJobResponse:
        """
        Run archival job for logs older than threshold.
        
        Args:
            target_date: Optional specific date to archive (YYYY-MM-DD).
                        If not provided, archives all eligible dates.
            tables: Optional list of table names to archive.
                   If not provided, archives all tables.
        
        Returns:
            ArchivalJobResponse with job status and results
        """
        job_id = uuid4()
        started_at = datetime.utcnow()
        cutoff_date = self._get_archive_cutoff_date()
        
        # Determine which tables to archive
        tables_to_archive = []
        for table_name, user_field, log_type in self.ARCHIVABLE_TABLES:
            if tables is None or table_name in tables:
                tables_to_archive.append((table_name, user_field, log_type))
        
        results = []
        overall_status = "completed"
        
        for table_name, user_field, log_type in tables_to_archive:
            try:
                if target_date:
                    # Archive specific date
                    status = await self._archive_table_for_date(
                        job_id, table_name, user_field, log_type, target_date
                    )
                    results.append(status)
                else:
                    # Archive all dates before cutoff
                    dates = await self._get_archivable_dates(table_name, cutoff_date)
                    for date_str in dates:
                        status = await self._archive_table_for_date(
                            job_id, table_name, user_field, log_type, date_str
                        )
                        results.append(status)
                        
                        if status.status == "failed":
                            overall_status = "failed"
                            
            except Exception as e:
                logger.error(f"Failed to archive {table_name}: {e}")
                results.append(ArchivalStatus(
                    date=target_date or "unknown",
                    table=table_name,
                    records_archived=0,
                    records_deleted=0,
                    blob_path="",
                    started_at=started_at,
                    status="failed",
                    error_message=str(e)
                ))
                overall_status = "failed"
        
        return ArchivalJobResponse(
            job_id=job_id,
            started_at=started_at,
            target_date=target_date or f"before_{cutoff_date.strftime('%Y-%m-%d')}",
            tables=[t[0] for t in tables_to_archive],
            status=overall_status,
            results=results
        )
    
    async def _get_archivable_dates(
        self,
        table_name: str,
        cutoff_date: datetime
    ) -> List[str]:
        """Get list of dates that have records eligible for archival."""
        try:
            # Query distinct dates before cutoff
            result = self.supabase.table(table_name)\
                .select("created_at")\
                .lt("created_at", cutoff_date.isoformat())\
                .order("created_at")\
                .limit(10000)\
                .execute()
            
            dates = set()
            for row in result.data or []:
                created_at = row["created_at"]
                if created_at:
                    date_str = created_at[:10]  # Extract YYYY-MM-DD
                    dates.add(date_str)
            
            return sorted(dates)
            
        except Exception as e:
            logger.error(f"Failed to get archivable dates for {table_name}: {e}")
            return []
    
    async def _archive_table_for_date(
        self,
        job_id: UUID,
        table_name: str,
        user_field: Optional[str],
        log_type: str,
        date_str: str
    ) -> ArchivalStatus:
        """
        Archive a single table for a specific date.
        
        Groups records by user (if applicable) and writes to blob storage.
        """
        started_at = datetime.utcnow()
        
        # Record start in archival_status table
        await self._record_archival_status(
            job_id, date_str, table_name, "in_progress"
        )
        
        try:
            # Fetch records for this date
            start_of_day = f"{date_str}T00:00:00Z"
            end_of_day = f"{date_str}T23:59:59.999999Z"
            
            records = await self._fetch_records_for_date(
                table_name, start_of_day, end_of_day
            )
            
            if not records:
                return ArchivalStatus(
                    date=date_str,
                    table=table_name,
                    records_archived=0,
                    records_deleted=0,
                    blob_path="",
                    started_at=started_at,
                    completed_at=datetime.utcnow(),
                    status="completed"
                )
            
            # Group records by user
            records_by_user: Dict[str, List[dict]] = {}
            for record in records:
                if user_field and record.get(user_field):
                    user_id = record[user_field]
                else:
                    user_id = "_system"
                
                if user_id not in records_by_user:
                    records_by_user[user_id] = []
                records_by_user[user_id].append(record)
            
            # Write to blob storage for each user (JSONL) AND aggregated CSV for Grafana
            total_archived = 0
            blob_paths = []
            all_records_for_csv = []
            
            for user_id, user_records in records_by_user.items():
                # Keep original JSONL archival per user
                result = await self.blob_service.upload_log_batch(
                    user_id=user_id,
                    log_type=log_type,
                    date_str=date_str,
                    entries=user_records,
                    archived=True  # Store in _archived folder
                )
                total_archived += len(user_records)
                blob_paths.append(result["blob_name"])
                all_records_for_csv.extend(user_records)
            
            # Also write aggregated CSV for Grafana Infinity plugin
            csv_result = await self.blob_service.upload_log_batch_csv(
                log_type=log_type,
                date_str=date_str,
                entries=all_records_for_csv
            )
            if csv_result.get("blob_name"):
                blob_paths.append(csv_result["blob_name"])
                logger.info(f"Created Grafana CSV: {csv_result['blob_name']}")
            
            # Delete archived records from Supabase
            deleted_count = await self._delete_archived_records(
                table_name, start_of_day, end_of_day
            )
            
            # Update archival status
            await self._update_archival_status(
                job_id, date_str, table_name,
                records_archived=total_archived,
                records_deleted=deleted_count,
                blob_path=",".join(blob_paths),
                status="completed"
            )
            
            logger.info(
                f"Archived {total_archived} records from {table_name} for {date_str}, "
                f"deleted {deleted_count} from Supabase"
            )
            
            return ArchivalStatus(
                date=date_str,
                table=table_name,
                records_archived=total_archived,
                records_deleted=deleted_count,
                blob_path=",".join(blob_paths),
                started_at=started_at,
                completed_at=datetime.utcnow(),
                status="completed"
            )
            
        except Exception as e:
            error_msg = str(e)
            logger.error(f"Failed to archive {table_name} for {date_str}: {error_msg}")
            
            await self._update_archival_status(
                job_id, date_str, table_name,
                status="failed",
                error_message=error_msg
            )
            
            return ArchivalStatus(
                date=date_str,
                table=table_name,
                records_archived=0,
                records_deleted=0,
                blob_path="",
                started_at=started_at,
                completed_at=datetime.utcnow(),
                status="failed",
                error_message=error_msg
            )
    
    async def _fetch_records_for_date(
        self,
        table_name: str,
        start_of_day: str,
        end_of_day: str
    ) -> List[dict]:
        """Fetch all records for a specific date range."""
        all_records = []
        offset = 0
        
        while True:
            result = self.supabase.table(table_name)\
                .select("*")\
                .gte("created_at", start_of_day)\
                .lte("created_at", end_of_day)\
                .range(offset, offset + self.BATCH_SIZE - 1)\
                .execute()
            
            if not result.data:
                break
            
            all_records.extend(result.data)
            
            if len(result.data) < self.BATCH_SIZE:
                break
            
            offset += self.BATCH_SIZE
        
        return all_records
    
    async def _delete_archived_records(
        self,
        table_name: str,
        start_of_day: str,
        end_of_day: str
    ) -> int:
        """Delete records that have been archived."""
        try:
            # Count first
            count_result = self.supabase.table(table_name)\
                .select("id", count="exact")\
                .gte("created_at", start_of_day)\
                .lte("created_at", end_of_day)\
                .execute()
            
            count = count_result.count or 0
            
            # Delete
            self.supabase.table(table_name)\
                .delete()\
                .gte("created_at", start_of_day)\
                .lte("created_at", end_of_day)\
                .execute()
            
            return count
            
        except Exception as e:
            logger.error(f"Failed to delete archived records from {table_name}: {e}")
            return 0
    
    async def _record_archival_status(
        self,
        job_id: UUID,
        date_str: str,
        table_name: str,
        status: str
    ) -> None:
        """Record archival job start in tracking table."""
        try:
            self.supabase.table("archival_status").insert({
                "job_id": str(job_id),
                "target_date": date_str,
                "table_name": table_name,
                "status": status,
                "started_at": datetime.utcnow().isoformat()
            }).execute()
        except Exception as e:
            logger.warning(f"Failed to record archival status: {e}")
    
    async def _update_archival_status(
        self,
        job_id: UUID,
        date_str: str,
        table_name: str,
        records_archived: int = 0,
        records_deleted: int = 0,
        blob_path: str = "",
        status: str = "completed",
        error_message: Optional[str] = None
    ) -> None:
        """Update archival job status."""
        try:
            update_data = {
                "records_archived": records_archived,
                "records_deleted": records_deleted,
                "blob_path": blob_path,
                "status": status,
                "completed_at": datetime.utcnow().isoformat()
            }
            if error_message:
                update_data["error_message"] = error_message
            
            self.supabase.table("archival_status")\
                .update(update_data)\
                .eq("job_id", str(job_id))\
                .eq("target_date", date_str)\
                .eq("table_name", table_name)\
                .execute()
        except Exception as e:
            logger.warning(f"Failed to update archival status: {e}")
    
    async def get_archival_history(
        self,
        limit: int = 50,
        status_filter: Optional[str] = None
    ) -> List[dict]:
        """Get recent archival job history."""
        try:
            query = self.supabase.table("archival_status")\
                .select("*")\
                .order("started_at", desc=True)\
                .limit(limit)
            
            if status_filter:
                query = query.eq("status", status_filter)
            
            result = query.execute()
            return result.data or []
            
        except Exception as e:
            logger.error(f"Failed to get archival history: {e}")
            return []
    
    async def get_archival_stats(self) -> Dict[str, Any]:
        """Get archival statistics."""
        try:
            # Get counts by status
            result = self.supabase.table("archival_status")\
                .select("status")\
                .execute()
            
            stats = {
                "total_jobs": 0,
                "completed": 0,
                "failed": 0,
                "in_progress": 0
            }
            
            for row in result.data or []:
                stats["total_jobs"] += 1
                status = row.get("status", "unknown")
                if status in stats:
                    stats[status] += 1
            
            # Get total records archived
            result = self.supabase.table("archival_status")\
                .select("records_archived")\
                .eq("status", "completed")\
                .execute()
            
            stats["total_records_archived"] = sum(
                row.get("records_archived", 0) for row in result.data or []
            )
            
            return stats
            
        except Exception as e:
            logger.error(f"Failed to get archival stats: {e}")
            return {}


# =============================================================================
# SINGLETON
# =============================================================================

_archival_service: Optional[LogArchivalService] = None


def get_archival_service() -> LogArchivalService:
    """Get the singleton LogArchivalService instance."""
    global _archival_service
    if _archival_service is None:
        _archival_service = LogArchivalService()
    return _archival_service
