"""
Azure Blob Storage Service
Handles uploading files and generating access URLs
"""
import uuid
import json
import logging
from datetime import datetime, timedelta
from azure.storage.blob import generate_blob_sas, BlobSasPermissions
from azure.storage.blob.aio import BlobServiceClient as AsyncBlobServiceClient
from azure.storage.blob import BlobServiceClient as SyncBlobServiceClient
from app.core.config import get_settings
from app.core.log_decorators import log_operation

logger = logging.getLogger(__name__)


class BlobStorageService:
    def __init__(self):
        settings = get_settings()
        self.connection_string = settings.azure_storage_connection_string
        self.container_name = settings.azure_storage_container
        # Async client for async operations
        self._async_blob_service_client = None
        self._async_container_client = None
        # Sync client for sync operations (SAS generation, etc.)
        self._sync_blob_service_client = SyncBlobServiceClient.from_connection_string(
            self.connection_string
        )
        self._sync_container_client = self._sync_blob_service_client.get_container_client(
            self.container_name
        )
    
    def _get_async_clients(self):
        """Lazily initialize async clients."""
        if self._async_blob_service_client is None:
            self._async_blob_service_client = AsyncBlobServiceClient.from_connection_string(
                self.connection_string
            )
            self._async_container_client = self._async_blob_service_client.get_container_client(
                self.container_name
            )
        return self._async_container_client
    
    # Keep sync properties for backward compatibility
    @property
    def blob_service_client(self):
        return self._sync_blob_service_client
    
    @property
    def container_client(self):
        return self._sync_container_client
    
    def _generate_blob_name(self, user_id: str, file_type: str, original_filename: str = None) -> str:
        """Generate a unique blob name with user prefix"""
        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        unique_id = str(uuid.uuid4())[:8]
        
        if original_filename:
            # Keep original extension
            extension = original_filename.split(".")[-1] if "." in original_filename else "bin"
            return f"{user_id}/{file_type}/{timestamp}_{unique_id}.{extension}"
        else:
            # For screenshots and quick notes
            extension = "png" if file_type == "screenshot" else "txt"
            return f"{user_id}/{file_type}/{timestamp}_{unique_id}.{extension}"
    
    @log_operation(
        service="blob_storage",
        operation="upload_file",
        extract_input=lambda args, kwargs: {"user_id": kwargs.get("user_id"), "file_type": kwargs.get("file_type"), "size_bytes": len(kwargs.get("file_content", b""))},
        extract_output=lambda r: {"blob_name": r.get("blob_name") if r else None, "size_bytes": r.get("size_bytes") if r else 0}
    )
    async def upload_file(
        self,
        file_content: bytes,
        user_id: str,
        file_type: str,
        original_filename: str = None,
        content_type: str = None
    ) -> dict:
        """
        Upload a file to Azure Blob Storage
        
        Args:
            file_content: Raw bytes of the file
            user_id: User identifier
            file_type: 'screenshot', 'quick_note', or 'uploaded_file'
            original_filename: Original filename (for uploaded files)
            content_type: MIME type of the file
        
        Returns:
            dict with blob_name and blob_url
        """
        from azure.storage.blob import ContentSettings
        
        logger.debug(f"blob_storage.upload_file: user={user_id}, type={file_type}, size={len(file_content)} bytes, content_type={content_type}")
        
        blob_name = self._generate_blob_name(user_id, file_type, original_filename)
        logger.debug(f"Generated blob name: {blob_name}")
        
        # Use async client for non-blocking upload
        async_container = self._get_async_clients()
        blob_client = async_container.get_blob_client(blob_name)
        
        # Ensure text content types include charset=utf-8 for proper encoding
        final_content_type = content_type or "application/octet-stream"
        if final_content_type.startswith("text/") and "charset" not in final_content_type:
            final_content_type = f"{final_content_type}; charset=utf-8"
        
        # Upload the blob with content settings (async)
        content_settings = ContentSettings(content_type=final_content_type)
        await blob_client.upload_blob(
            file_content,
            overwrite=True,
            content_settings=content_settings
        )
        
        # Get the blob URL (without SAS token - we'll generate on demand)
        blob_url = blob_client.url
        logger.debug(f"Blob uploaded successfully: {blob_name}")
        
        return {
            "blob_name": blob_name,
            "blob_url": blob_url,
            "size_bytes": len(file_content)
        }
    
    def generate_sas_url(self, blob_name: str, expiry_hours: int = 1, expiry_minutes: int = None, expiry_years: int = None) -> str:
        """
        Generate a SAS URL for temporary access to a blob
        
        Args:
            blob_name: Name of the blob
            expiry_hours: Hours until the SAS token expires (default)
            expiry_minutes: Minutes until expiry (overrides expiry_hours if set)
            expiry_years: Years until expiry (for long-lived URLs, overrides others)
        
        Returns:
            Full URL with SAS token
        """
        # Parse account info from connection string
        account_name = None
        account_key = None
        for part in self.connection_string.split(";"):
            if part.startswith("AccountName="):
                account_name = part.split("=", 1)[1]
            elif part.startswith("AccountKey="):
                account_key = part.split("=", 1)[1]
        
        # Calculate expiry (years > minutes > hours)
        if expiry_years:
            expiry = datetime.utcnow() + timedelta(days=expiry_years * 365)
        elif expiry_minutes:
            expiry = datetime.utcnow() + timedelta(minutes=expiry_minutes)
        else:
            expiry = datetime.utcnow() + timedelta(hours=expiry_hours)
        
        sas_token = generate_blob_sas(
            account_name=account_name,
            container_name=self.container_name,
            blob_name=blob_name,
            account_key=account_key,
            permission=BlobSasPermissions(read=True),
            expiry=expiry
        )
        
        blob_client = self.container_client.get_blob_client(blob_name)
        return f"{blob_client.url}?{sas_token}"
    
    @log_operation(
        service="blob_storage",
        operation="delete_blob",
        extract_input=lambda args, kwargs: {"blob_name": kwargs.get("blob_name") or (args[1] if len(args) > 1 else None)},
        extract_output=lambda r: {"success": r}
    )
    async def delete_blob(self, blob_name: str) -> bool:
        """Delete a blob from storage"""
        logger.debug(f"blob_storage.delete_blob: blob_name={blob_name}")
        try:
            async_container = self._get_async_clients()
            blob_client = async_container.get_blob_client(blob_name)
            await blob_client.delete_blob()
            logger.debug(f"Blob deleted successfully: {blob_name}")
            return True
        except Exception as e:
            logger.warning(f"Failed to delete blob {blob_name}: {e}")
            return False
    
    # =========================================================================
    # LOG-SPECIFIC OPERATIONS
    # =========================================================================
    
    def _get_log_blob_path(
        self,
        user_id: str,
        log_type: str,
        date_str: str,
        archived: bool = False,
        file_format: str = "jsonl"
    ) -> str:
        """
        Generate blob path for log files.
        
        Args:
            user_id: User ID or '_system' for system logs
            log_type: 'activities', 'operations', or 'errors'
            date_str: Date string in YYYY-MM-DD format
            archived: Whether this is an archived log
            file_format: 'jsonl' or 'csv' (csv for Grafana Infinity plugin)
        
        Returns:
            Blob path like 'user_id/logs/activities/2026-01-13.jsonl' or
            '_grafana_archive/activities/2026-01-13.csv' for archived CSV
        """
        ext = file_format if file_format in ("jsonl", "csv") else "jsonl"
        
        if archived and file_format == "csv":
            # Store archived CSV in a dedicated folder for Grafana Infinity plugin
            return f"_grafana_archive/{log_type}/{date_str}.csv"
        elif archived:
            return f"{user_id}/logs/_archived/{log_type}/{date_str}.jsonl"
        return f"{user_id}/logs/{log_type}/{date_str}.jsonl"
    
    async def upload_log_batch(
        self,
        user_id: str,
        log_type: str,
        date_str: str,
        entries: list,
        archived: bool = False
    ) -> dict:
        """
        Upload a batch of log entries as JSONL to blob storage.
        
        Args:
            user_id: User ID
            log_type: Type of log
            date_str: Date string
            entries: List of log entry dictionaries
            archived: Whether to store in archive path
        
        Returns:
            dict with blob_name and entries_count
        """
        import json
        from azure.storage.blob import ContentSettings
        
        blob_path = self._get_log_blob_path(user_id, log_type, date_str, archived)
        async_container = self._get_async_clients()
        blob_client = async_container.get_blob_client(blob_path)
        
        # Convert entries to JSONL format
        jsonl_content = "\n".join(json.dumps(entry, default=str) for entry in entries)
        jsonl_bytes = (jsonl_content + "\n").encode("utf-8")
        
        # Try to append to existing blob
        try:
            stream = await blob_client.download_blob()
            existing_content = await stream.readall()
            new_content = existing_content + jsonl_bytes
        except Exception:
            # Blob doesn't exist, create new
            new_content = jsonl_bytes
        
        # Upload with JSONL content type (async)
        content_settings = ContentSettings(content_type="application/x-ndjson")
        await blob_client.upload_blob(
            new_content,
            overwrite=True,
            content_settings=content_settings
        )
        
        return {
            "blob_name": blob_path,
            "entries_count": len(entries),
            "size_bytes": len(new_content)
        }
    
    async def list_log_files(
        self,
        user_id: str,
        log_type: str = None,
        include_archived: bool = False,
        start_date: str = None,
        end_date: str = None
    ) -> list:
        """
        List log files for a user.
        
        Args:
            user_id: User ID
            log_type: Optional filter by log type
            include_archived: Include archived logs
            start_date: Optional start date filter (YYYY-MM-DD)
            end_date: Optional end date filter (YYYY-MM-DD)
        
        Returns:
            List of blob names
        """
        prefix = f"{user_id}/logs/"
        if log_type:
            prefix = f"{user_id}/logs/{log_type}/"
        
        results = []
        blobs = self.container_client.list_blobs(name_starts_with=prefix)
        
        for blob in blobs:
            name = blob.name
            
            # Skip archived if not requested
            if "_archived" in name and not include_archived:
                continue
            
            # Apply date filters if provided
            if start_date or end_date:
                # Extract date from blob name (e.g., '2026-01-13.jsonl')
                try:
                    filename = name.split("/")[-1]
                    file_date = filename.replace(".jsonl", "")
                    
                    if start_date and file_date < start_date:
                        continue
                    if end_date and file_date > end_date:
                        continue
                except Exception:
                    pass
            
            results.append({
                "blob_name": name,
                "size_bytes": blob.size,
                "last_modified": blob.last_modified.isoformat() if blob.last_modified else None
            })
        
        return results
    
    async def download_log_file(self, blob_name: str) -> list:
        """
        Download and parse a JSONL log file.
        
        Args:
            blob_name: Full blob path
        
        Returns:
            List of parsed log entries
        """
        import json
        
        try:
            async_container = self._get_async_clients()
            blob_client = async_container.get_blob_client(blob_name)
            stream = await blob_client.download_blob()
            content = (await stream.readall()).decode("utf-8")
            
            entries = []
            for line in content.strip().split("\n"):
                if line:
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
            
            return entries
        except Exception as e:
            raise Exception(f"Failed to download log file {blob_name}: {e}")
    
    async def stream_log_lines(
        self,
        blob_name: str,
        search_text: str = None,
        max_lines: int = 1000
    ):
        """
        Stream and optionally filter log lines from a blob.
        
        Args:
            blob_name: Full blob path
            search_text: Optional text to filter lines
            max_lines: Maximum lines to return
        
        Yields:
            Parsed log entry dictionaries
        """
        import json
        
        async_container = self._get_async_clients()
        blob_client = async_container.get_blob_client(blob_name)
        
        try:
            stream = await blob_client.download_blob()
            content = (await stream.readall()).decode("utf-8")
            
            count = 0
            for line in content.strip().split("\n"):
                if count >= max_lines:
                    break
                
                if not line:
                    continue
                
                # Apply text filter if provided
                if search_text and search_text.lower() not in line.lower():
                    continue
                
                try:
                    entry = json.loads(line)
                    yield entry
                    count += 1
                except json.JSONDecodeError:
                    continue
                    
        except Exception as e:
            raise Exception(f"Failed to stream log file {blob_name}: {e}")
    
    async def delete_log_files_before_date(
        self,
        user_id: str,
        log_type: str,
        before_date: str,
        archived_only: bool = False
    ) -> int:
        """
        Delete log files before a specific date.
        
        Args:
            user_id: User ID
            log_type: Log type
            before_date: Delete files before this date (YYYY-MM-DD)
            archived_only: Only delete from archive folder
        
        Returns:
            Number of files deleted
        """
        deleted_count = 0
        
        prefix = f"{user_id}/logs/"
        if archived_only:
            prefix = f"{user_id}/logs/_archived/{log_type}/"
        elif log_type:
            prefix = f"{user_id}/logs/{log_type}/"
        
        # Use sync client for listing (async list is complex), async for deletes
        blobs = self._sync_container_client.list_blobs(name_starts_with=prefix)
        async_container = self._get_async_clients()
        
        for blob in blobs:
            try:
                filename = blob.name.split("/")[-1]
                file_date = filename.replace(".jsonl", "").replace(".csv", "")
                
                if file_date < before_date:
                    blob_client = async_container.get_blob_client(blob.name)
                    await blob_client.delete_blob()
                    deleted_count += 1
            except Exception:
                continue
        
        return deleted_count
    
    # =========================================================================
    # CSV OPERATIONS FOR GRAFANA INFINITY PLUGIN
    # =========================================================================
    
    async def upload_log_batch_csv(
        self,
        log_type: str,
        date_str: str,
        entries: list,
        column_order: list = None
    ) -> dict:
        """
        Upload a batch of log entries as CSV to blob storage for Grafana Infinity plugin.
        
        The CSV is stored in a dedicated _grafana_archive folder, aggregating all users
        for easier querying from Grafana.
        
        Args:
            log_type: Type of log ('activities', 'operations', 'errors')
            date_str: Date string (YYYY-MM-DD)
            entries: List of log entry dictionaries
            column_order: Optional list of columns in order for CSV header
        
        Returns:
            dict with blob_name, entries_count, and sas_url
        """
        import csv
        import io
        from azure.storage.blob import ContentSettings
        
        if not entries:
            return {"blob_name": "", "entries_count": 0}
        
        # Determine columns from first entry if not specified
        if not column_order:
            # Common columns for each log type
            if log_type == "activities":
                column_order = [
                    "id", "user_id", "action", "resource_type", "resource_id",
                    "status", "duration_ms", "metadata", "correlation_id", "created_at"
                ]
            elif log_type == "operations":
                column_order = [
                    "id", "service", "operation", "status", "duration_ms",
                    "input_summary", "output_summary", "error_message",
                    "correlation_id", "created_at"
                ]
            elif log_type == "errors":
                column_order = [
                    "id", "user_id", "error_type", "error_message", "stack_trace",
                    "endpoint", "request_data", "severity", "correlation_id", "created_at"
                ]
            else:
                # Fallback: use all keys from first entry
                column_order = list(entries[0].keys())
        
        # Create CSV in memory
        output = io.StringIO()
        writer = csv.DictWriter(output, fieldnames=column_order, extrasaction='ignore')
        writer.writeheader()
        
        for entry in entries:
            # Convert nested dicts/lists to JSON strings for CSV
            row = {}
            for col in column_order:
                val = entry.get(col, "")
                if isinstance(val, (dict, list)):
                    row[col] = json.dumps(val, default=str)
                else:
                    row[col] = str(val) if val is not None else ""
            writer.writerow(row)
        
        csv_content = output.getvalue().encode("utf-8")
        
        # Store in _grafana_archive folder
        blob_path = f"_grafana_archive/{log_type}/{date_str}.csv"
        
        async_container = self._get_async_clients()
        blob_client = async_container.get_blob_client(blob_path)
        
        # Check if blob exists and append, or create new
        try:
            stream = await blob_client.download_blob()
            existing_content = await stream.readall()
            # Skip header in new content if appending
            lines = csv_content.decode("utf-8").split("\n", 1)
            if len(lines) > 1:
                new_content = existing_content + lines[1].encode("utf-8")
            else:
                new_content = existing_content
        except Exception:
            # Blob doesn't exist, create new with header
            new_content = csv_content
        
        # Upload with CSV content type
        content_settings = ContentSettings(content_type="text/csv")
        await blob_client.upload_blob(
            new_content,
            overwrite=True,
            content_settings=content_settings
        )
        
        # Generate long-lived SAS URL for Grafana (1 year)
        sas_url = self.generate_sas_url(blob_path, expiry_years=1)
        
        return {
            "blob_name": blob_path,
            "entries_count": len(entries),
            "size_bytes": len(new_content),
            "sas_url": sas_url
        }
    
    def list_archived_csv_files(
        self,
        log_type: str = None,
        start_date: str = None,
        end_date: str = None
    ) -> list:
        """
        List archived CSV files for Grafana Infinity plugin.
        
        Args:
            log_type: Optional filter by log type
            start_date: Optional start date (YYYY-MM-DD)
            end_date: Optional end date (YYYY-MM-DD)
        
        Returns:
            List of dicts with blob_name, date, log_type, and sas_url
        """
        prefix = "_grafana_archive/"
        if log_type:
            prefix = f"_grafana_archive/{log_type}/"
        
        results = []
        blobs = self._sync_container_client.list_blobs(name_starts_with=prefix)
        
        for blob in blobs:
            name = blob.name
            if not name.endswith(".csv"):
                continue
            
            # Extract date and log_type from path
            # Format: _grafana_archive/{log_type}/{date}.csv
            parts = name.replace("_grafana_archive/", "").replace(".csv", "").split("/")
            if len(parts) != 2:
                continue
            
            file_log_type, file_date = parts
            
            # Apply date filters
            if start_date and file_date < start_date:
                continue
            if end_date and file_date > end_date:
                continue
            
            # Generate SAS URL
            sas_url = self.generate_sas_url(name, expiry_years=1)
            
            results.append({
                "blob_name": name,
                "log_type": file_log_type,
                "date": file_date,
                "size_bytes": blob.size,
                "sas_url": sas_url,
                "last_modified": blob.last_modified.isoformat() if blob.last_modified else None
            })
        
        return sorted(results, key=lambda x: (x["log_type"], x["date"]))
    
    def get_grafana_infinity_config(self, log_type: str = None) -> dict:
        """
        Get configuration for Grafana Infinity plugin to access archived logs.
        
        Args:
            log_type: Optional specific log type, or returns config for all
        
        Returns:
            Dict with Infinity plugin configuration
        """
        csv_files = self.list_archived_csv_files(log_type=log_type)
        
        # Group by log type
        by_type = {}
        for f in csv_files:
            lt = f["log_type"]
            if lt not in by_type:
                by_type[lt] = []
            by_type[lt].append(f)
        
        return {
            "plugin": "yesoreyeram-infinity-datasource",
            "description": "Configuration for Grafana Infinity plugin to access archived NotesApp logs",
            "data_sources": [
                {
                    "name": f"NotesApp Archived {lt.title()}",
                    "type": "csv",
                    "files": [
                        {"date": f["date"], "url": f["sas_url"]}
                        for f in files
                    ]
                }
                for lt, files in by_type.items()
            ],
            "instructions": [
                "1. Install Grafana Infinity plugin: grafana-cli plugins install yesoreyeram-infinity-datasource",
                "2. Add new data source of type 'Infinity'",
                "3. Use the SAS URLs above with type 'CSV' and format 'Table'",
                "4. Set up panels to visualize the data"
            ]
        }


# Singleton instance
_blob_service = None

def get_blob_service() -> BlobStorageService:
    global _blob_service
    if _blob_service is None:
        _blob_service = BlobStorageService()
    return _blob_service
