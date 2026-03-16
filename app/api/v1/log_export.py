"""
Log export endpoints - Exports search traces and worker logs to Azure Blob Storage
"""
from fastapi import APIRouter, HTTPException, BackgroundTasks
from datetime import datetime, timedelta
from typing import Optional
import json
import logging
from azure.storage.blob import BlobServiceClient
from app.core.supabase_client import get_supabase_client

router = APIRouter(prefix="/api/v1/logs", tags=["Log Export"])
logger = logging.getLogger(__name__)

# Initialize Azure Blob Storage client
def get_blob_client():
    """Get Azure Blob Storage client from environment"""
    import os
    connection_string = os.getenv("AZURE_STORAGE_CONNECTION_STRING")
    if not connection_string:
        raise ValueError("AZURE_STORAGE_CONNECTION_STRING not set")
    return BlobServiceClient.from_connection_string(connection_string)

# =============================================================================
# SUPABASE LOGS EXPORT
# =============================================================================

@router.post("/export/supabase-logs", tags=["Log Export"])
async def export_supabase_logs(background_tasks: BackgroundTasks):
    """
    Export Supabase search_traces from last 48 hours to Azure Blob Storage.
    Runs in background. Returns job ID.
    """
    job_id = f"export_{datetime.utcnow().strftime('%Y%m%d_%H%M%S')}"
    background_tasks.add_task(export_supabase_logs_task, job_id)
    return {
        "job_id": job_id,
        "status": "started",
        "message": "Exporting Supabase logs to Azure Blob Storage"
    }

async def export_supabase_logs_task(job_id: str):
    """Background task to export Supabase logs"""
    try:
        supabase = get_supabase_client()
        blob_client = get_blob_client()
        
        # Query search_traces from last 48 hours
        now = datetime.utcnow()
        cutoff_time = (now - timedelta(hours=48)).isoformat()
        
        logger.info(f"[{job_id}] Exporting search_traces and upload_traces since {cutoff_time}")
        
        # Get search traces
        response = supabase.table("search_traces").select("*").gte(
            "created_at", cutoff_time
        ).order("created_at", desc=False).execute()
        
        search_traces = response.data if response.data else []
        logger.info(f"[{job_id}] Found {len(search_traces)} search traces to export")
        
        # Get upload traces
        response = supabase.table("upload_traces").select("*").gte(
            "created_at", cutoff_time
        ).order("created_at", desc=False).execute()
        
        upload_traces = response.data if response.data else []
        logger.info(f"[{job_id}] Found {len(upload_traces)} upload traces to export")
        
        total_records = len(search_traces) + len(upload_traces)
        
        if total_records == 0:
            logger.info(f"[{job_id}] No traces to export")
            return
        
        # Combine both traces
        all_traces = {
            "search_traces": search_traces,
            "upload_traces": upload_traces,
            "export_metadata": {
                "export_time": now.isoformat(),
                "job_id": job_id,
                "total_records": total_records,
                "time_range": {
                    "from": cutoff_time,
                    "to": now.isoformat()
                }
            }
        }
        
        # Convert to JSON
        traces_json = json.dumps(all_traces, indent=2, default=str)
        
        # Create filename with date AND time to avoid overwrites
        # Format: supabase-logs/2026-02-26/search_upload_traces_090000.json
        date_str = now.strftime("%Y-%m-%d")
        time_str = now.strftime("%H%M%S")
        folder = f"supabase-logs/{date_str}"
        filename = f"{folder}/search_upload_traces_{time_str}.json"
        
        # Upload to Azure
        container_client = blob_client.get_container_client("supabase-logs")
        blob = container_client.get_blob_client(filename)
        blob.upload_blob(traces_json, overwrite=True)
        
        logger.info(f"[{job_id}] Successfully exported {total_records} traces to {filename}")
        
        # Store export metadata
        metadata = {
            "export_time": now.isoformat(),
            "job_id": job_id,
            "search_traces_count": len(search_traces),
            "upload_traces_count": len(upload_traces),
            "total_count": total_records,
            "time_range": {
                "from": cutoff_time,
                "to": now.isoformat()
            },
            "blob_path": f"azure://rawnotesstorage.blob.core.windows.net/{filename}"
        }
        
        # Store in Supabase for tracking
        supabase.table("log_exports").insert({
            "job_id": job_id,
            "export_type": "supabase_search_upload_traces",
            "record_count": total_records,
            "time_range_start": cutoff_time,
            "time_range_end": now.isoformat(),
            "blob_path": filename,
            "status": "completed",
            "metadata": metadata
        }).execute()
        
    except Exception as e:
        logger.error(f"[{job_id}] Export failed: {str(e)}", exc_info=True)
        try:
            supabase = get_supabase_client()
            supabase.table("log_exports").insert({
                "job_id": job_id,
                "export_type": "supabase_search_upload_traces",
                "status": "failed",
                "error_message": str(e)
            }).execute()
        except:
            pass

# =============================================================================
# CLOUDFLARE LOGS EXPORT
# =============================================================================

@router.post("/export/cloudflare-logs", tags=["Log Export"])
async def export_cloudflare_logs(background_tasks: BackgroundTasks):
    """
    Export Cloudflare worker logs from last 48 hours to Azure Blob Storage.
    Uses Cloudflare Logpull API. Requires CF_API_TOKEN and CF_ACCOUNT_ID.
    """
    job_id = f"cf_export_{datetime.utcnow().strftime('%Y%m%d_%H%M%S')}"
    background_tasks.add_task(export_cloudflare_logs_task, job_id)
    return {
        "job_id": job_id,
        "status": "started",
        "message": "Exporting Cloudflare logs to Azure Blob Storage"
    }

async def export_cloudflare_logs_task(job_id: str):
    """Background task to export Cloudflare logs via Logpull API"""
    try:
        import os
        import httpx
        
        cf_token = os.getenv("CLOUDFLARE_API_TOKEN")
        cf_account_id = os.getenv("CLOUDFLARE_ACCOUNT_ID")
        
        if not cf_token or not cf_account_id:
            raise ValueError("CLOUDFLARE_API_TOKEN or CLOUDFLARE_ACCOUNT_ID not set")
        
        blob_client = get_blob_client()
        
        # Time range: last 48 hours
        now = datetime.utcnow()
        start_time = (now - timedelta(hours=48)).isoformat() + "Z"
        end_time = now.isoformat() + "Z"
        
        logger.info(f"[{job_id}] Exporting Cloudflare logs from {start_time} to {end_time}")
        
        # Fetch from Cloudflare Logpull API
        # Docs: https://developers.cloudflare.com/workers/platform/logpull-api/
        url = f"https://api.cloudflare.com/client/v4/accounts/{cf_account_id}/workers/analytics/engine/logs"
        
        headers = {
            "Authorization": f"Bearer {cf_token}",
            "Content-Type": "application/json"
        }
        
        params = {
            "start": start_time,
            "end": end_time,
            "limit": 1000  # Max per page
        }
        
        logs_data = []
        page = 0
        
        async with httpx.AsyncClient() as client:
            while True:
                logger.info(f"[{job_id}] Fetching page {page}...")
                params["offset"] = page * 1000
                
                response = await client.get(url, headers=headers, params=params)
                
                if response.status_code != 200:
                    logger.error(f"[{job_id}] Cloudflare API error: {response.status_code}")
                    logger.error(f"[{job_id}] Response: {response.text}")
                    raise Exception(f"Cloudflare API error: {response.status_code}")
                
                data = response.json()
                
                if "result" not in data:
                    logger.warning(f"[{job_id}] No result in response: {data}")
                    break
                
                records = data.get("result", []) or []
                
                # If this is the first page and it has records, get total count
                if page == 0 and "success" in data:
                    total = data.get("result_info", {}).get("total_count", 0)
                    logger.info(f"[{job_id}] Total records available: {total}")
                
                if not records:
                    break
                
                logs_data.extend(records)
                page += 1
                
                # Stop if less than page size (last page)
                if len(records) < 1000:
                    break
        
        logger.info(f"[{job_id}] Retrieved {len(logs_data)} Cloudflare log records")
        
        if not logs_data:
            logger.info(f"[{job_id}] No Cloudflare logs to export")
            return
        
        # Convert to JSON
        logs_json = json.dumps(logs_data, indent=2, default=str)
        
        # Create filename with date
        date_str = now.strftime("%Y-%m-%d")
        filename = f"cloudflare-logs/{date_str}_worker_logs.json"
        
        # Upload to Azure
        container_client = blob_client.get_container_client("cloudflare-logs")
        
        # Delete previous day's file
        prev_date = (now - timedelta(days=1)).strftime("%Y-%m-%d")
        prev_filename = f"cloudflare-logs/{prev_date}_worker_logs.json"
        try:
            container_client.delete_blob(prev_filename)
            logger.info(f"[{job_id}] Deleted previous export: {prev_filename}")
        except:
            logger.debug(f"[{job_id}] Prev file not found (expected)")
        
        # Upload new file
        blob = container_client.get_blob_client(filename)
        blob.upload_blob(logs_json, overwrite=True)
        
        logger.info(f"[{job_id}] Successfully exported {len(logs_data)} Cloudflare logs to {filename}")
        
        # Store export metadata
        supabase = get_supabase_client()
        supabase.table("log_exports").insert({
            "job_id": job_id,
            "export_type": "cloudflare_worker_logs",
            "record_count": len(logs_data),
            "time_range_start": start_time,
            "time_range_end": end_time,
            "blob_path": filename,
            "status": "completed"
        }).execute()
        
    except Exception as e:
        logger.error(f"[{job_id}] Cloudflare export failed: {str(e)}", exc_info=True)
        try:
            supabase = get_supabase_client()
            supabase.table("log_exports").insert({
                "job_id": job_id,
                "export_type": "cloudflare_worker_logs",
                "status": "failed",
                "error_message": str(e)
            }).execute()
        except:
            pass

# =============================================================================
# GET EXPORT STATUS
# =============================================================================

@router.get("/export/status/{job_id}", tags=["Log Export"])
async def get_export_status(job_id: str):
    """Get status of an export job"""
    try:
        supabase = get_supabase_client()
        response = supabase.table("log_exports").select("*").eq("job_id", job_id).execute()
        
        if not response.data:
            raise HTTPException(status_code=404, detail="Job not found")
        
        return response.data[0]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/export/logs", tags=["Log Export"])
async def list_export_logs(limit: int = 20):
    """List recent export jobs"""
    try:
        supabase = get_supabase_client()
        response = supabase.table("log_exports").select("*").order(
            "created_at", desc=True
        ).limit(limit).execute()
        
        return {"exports": response.data or []}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
