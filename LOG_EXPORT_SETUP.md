# Log Export to Azure Blob Storage - Setup Guide

## Overview

This document explains how to export NotesApp logs (Supabase search traces + Cloudflare worker logs) to Azure Blob Storage for long-term retention and analysis.

**Key Features:**
- Exports **last 48 hours** of logs daily (no duplicates)
- Separate containers for Supabase and Cloudflare logs
- Meaningful filenames with date suffix: `2026-02-26_search_traces.json`
- Automatic daily scheduled export at 01:00 UTC (Supabase) and 01:30 UTC (Cloudflare)
- REST API for manual export and status tracking

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Daily Scheduled Tasks (APScheduler)                     │
│ - 01:00 UTC: Export Supabase logs                       │
│ - 01:30 UTC: Export Cloudflare logs                     │
└────────┬────────────────────────────┬────────────────────┘
         │                            │
    ┌────▼────┐               ┌───────▼───────┐
    │ Supabase │               │  Cloudflare   │
    │ Database │               │  Logpull API  │
    │          │               │               │
    │- search_ │               │- Worker logs  │
    │  traces  │               │               │
    └────┬─────┘               └────────┬──────┘
         │                             │
         └──────────┬──────────────────┘
                    │
         ┌──────────▼──────────┐
         │   Azure Blob        │
         │   Storage Account   │
         │                     │
         │ /supabase-logs/     │
         │ /cloudflare-logs/   │
         └─────────────────────┘
```

---

## Setup Instructions

### 1. Create Azure Blob Containers

Run this PowerShell command with your Azure connection string:

```powershell
$connectionString = $env:AZURE_STORAGE_CONNECTION_STRING
$ctx = New-AzureStorageContext -ConnectionString $connectionString

# Create containers
New-AzureStorageContainer -Name "supabase-logs" -Context $ctx
New-AzureStorageContainer -Name "cloudflare-logs" -Context $ctx

# Verify
Get-AzureStorageContainer -Context $ctx | Select-Object Name
```

**Output:**
```
Name
----
notes-storage
supabase-logs
cloudflare-logs
```

### 2. Create Supabase Table for Tracking Exports

Run the migration in your Supabase:

```sql
-- From: notesapp-deploy/supabase/migrations/20260226000000_log_exports.sql
supabase db push
```

This creates the `log_exports` table to track all export jobs.

### 3. Set Environment Variables

Add these to your `.env` file for local testing, or as Heroku/Docker secrets for production:

```bash
# For Supabase exports (should already be set)
LOG_ENABLED=true
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_KEY=eyJ...

# For Azure exports (should already be set)
AZURE_STORAGE_CONNECTION_STRING=...

# For Cloudflare exports (NEW - optional)
CLOUDFLARE_API_TOKEN=Bearer...  # Get from https://dash.cloudflare.com/profile/api-tokens
CLOUDFLARE_ACCOUNT_ID=540f86da...  # Your account ID from Worker logs
```

### 4. Install APScheduler

```bash
pip install apscheduler>=3.10.0
# Already added to requirements.txt
```

### 5. Deploy

```bash
# Deploy to Fly.io or your backend
git commit -am "Add log export to Azure Blob Storage"
git push
```

---

## API Endpoints

### Manual Export Triggers

#### Export Supabase Logs (Last 48 Hours)

```bash
POST /api/v1/logs/export/supabase-logs
```

**Response:**
```json
{
  "job_id": "export_20260226_082530",
  "status": "started",
  "message": "Exporting Supabase logs to Azure Blob Storage"
}
```

#### Export Cloudflare Logs (Last 48 Hours)

```bash
POST /api/v1/logs/export/cloudflare-logs
```

**Response:**
```json
{
  "job_id": "cf_export_20260226_082530",
  "status": "started",
  "message": "Exporting Cloudflare logs to Azure Blob Storage"
}
```

### Export Status

#### Get Status of a Job

```bash
GET /api/v1/logs/export/status/{job_id}
```

**Example:**
```bash
GET /api/v1/logs/export/status/export_20260226_082530
```

**Response:**
```json
{
  "id": 123,
  "job_id": "export_20260226_082530",
  "export_type": "supabase_search_traces",
  "status": "completed",
  "record_count": 1245,
  "time_range_start": "2026-02-24T08:25:30Z",
  "time_range_end": "2026-02-26T08:25:30Z",
  "blob_path": "supabase-logs/2026-02-26_search_traces.json",
  "created_at": "2026-02-26T08:25:30.123Z",
  "updated_at": "2026-02-26T08:26:15.456Z"
}
```

#### List All Recent Exports

```bash
GET /api/v1/logs/export/logs?limit=20
```

**Response:**
```json
{
  "exports": [
    {
      "id": 125,
      "job_id": "cf_export_20260226_013000",
      "export_type": "cloudflare_worker_logs",
      "status": "completed",
      "record_count": 8932,
      "blob_path": "cloudflare-logs/2026-02-26_worker_logs.json",
      "created_at": "2026-02-26T01:30:15.123Z"
    },
    {
      "id": 124,
      "job_id": "export_20260226_010000",
      "export_type": "supabase_search_traces",
      "status": "completed",
      "record_count": 5621,
      "blob_path": "supabase-logs/2026-02-26_search_traces.json",
      "created_at": "2026-02-26T01:00:10.456Z"
    }
  ]
}
```

---

## Scheduled Exports

### Daily Schedule

The system automatically exports logs daily:

| Time | Task | Source | Destination |
|------|------|--------|-------------|
| **01:00 UTC** | Export search traces (last 48h) | `search_traces` table | `supabase-logs/YYYY-MM-DD_search_traces.json` |
| **01:30 UTC** | Export worker logs (last 48h) | Cloudflare Logpull API | `cloudflare-logs/YYYY-MM-DD_worker_logs.json` |

### How to Change Schedule

Edit `app/services/scheduled_tasks.py`:

```python
# Change from 01:00 UTC to 02:00 UTC
scheduler.add_job(
    export_supabase_logs_task,
    CronTrigger(hour=2, minute=0),  # <- Change hour here
    ...
)
```

---

## File Formats

### Supabase Logs Format

**File:** `supabase-logs/2026-02-26_search_traces.json`

```json
[
  {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "user_id": "2649b4d0-c40d-4ab1-ac04-928fe1cf5969",
    "correlation_id": "550e8400...",
    "query": "how to optimize react performance",
    "query_corrected": null,
    "intent_classification": "CONTENT_SEARCH",
    "intent_confidence": 0.95,
    "vector_count": 23,
    "keyword_count": 1,
    "reranked_count": 18,
    "final_count": 2,
    "timing_total_ms": 1827,
    "timing_embedding_ms": 259,
    "timing_vector_search_ms": 145,
    "timing_rerank_ms": 495,
    "embedding_cached": false,
    "search_cached": false,
    "llm_calls": [
      {
        "model": "llama-3.1-8b-instant",
        "tokens_prompt": 284,
        "tokens_completion": 12,
        "latency_ms": 89
      }
    ],
    "answer_generated": true,
    "answer_preview": "Based on your notes, here are key optimization techniques...",
    "created_at": "2026-02-26T08:25:30.123Z"
  }
]
```

### Cloudflare Logs Format

**File:** `cloudflare-logs/2026-02-26_worker_logs.json`

```json
[
  {
    "timestamp": "2026-02-26T08:25:30.587Z",
    "level": "info",
    "message": "[wr_1772011412215_0mcf9er] RAG search: query=\"...\", user=2649b4d0",
    "request": {
      "method": "POST",
      "path": "/rag-search-auth",
      "url": "https://notesapp-vector-search.monocle0712.workers.dev/rag-search-auth"
    },
    "request_id": "9d3624fe5b6884fa",
    "event_timestamp": "2026-02-26T08:25:30.000Z"
  }
]
```

---

## Monitoring & Troubleshooting

### Check Export Status

```bash
# View recent exports
curl -X GET "http://localhost:8000/api/v1/logs/export/logs?limit=5" \
  -H "Authorization: Bearer YOUR_TOKEN"

# Check specific job
curl -X GET "http://localhost:8000/api/v1/logs/export/status/export_20260226_010000" \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### View Logs

```bash
# Check server logs for export execution
tail -f notesapp.log | grep -E "export|Export|EXPORT"

# Real-time logs during export
# Look for: "Export", "Successfully exported", "blob_path"
```

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `AZURE_STORAGE_CONNECTION_STRING not set` | Missing env var | Add to `.env` or secrets |
| `No records to export` | No logs during time window | Check if `LOG_ENABLED=true` |
| `Cloudflare export fails` | Missing API token | Set `CLOUDFLARE_API_TOKEN` |
| `403 Forbidden` | Invalid API token | Regenerate at https://dash.cloudflare.com/profile |
| `Blob upload fails` | Container doesn't exist | Run container creation script above |

---

## Data Retention Strategy

### Supabase (Hot Storage)
- **Keep:** Last 7 days
- **Auto-cleanup:** Via `cleanup_old_search_traces()` function
- **Purpose:** Real-time queries, dashboards

### Azure Blob (Archive Storage)
- **Keep:** Last 365 days (configurable)
- **Format:** Daily JSON files with 48-hour overlap
- **Cost:** ~$0.02/day for 1000 search traces

### Lifecycle Policy (Optional)

To auto-delete old archives when they exceed retention:

```python
# Add to Azure management script
from azure.storage.blob import BlobServiceClient
from datetime import datetime, timedelta

client = BlobServiceClient.from_connection_string(conn_str)
container = client.get_container_client("supabase-logs")

# Delete files older than 365 days
cutoff = datetime.utcnow() - timedelta(days=365)
for blob in container.list_blobs():
    if blob.properties['last_modified'].replace(tzinfo=None) < cutoff:
        container.delete_blob(blob.name)
```

---

## Analytics with Azure

### Example: Query Last 30 Days of Searches

Using Azure Blob Storage with Python:

```python
import json
from datetime import datetime, timedelta
from azure.storage.blob import BlobServiceClient

client = BlobServiceClient.from_connection_string(conn_str)
container = client.get_container_client("supabase-logs")

all_traces = []

# Download last 30 days of exports
for i in range(30):
    date = (datetime.utcnow() - timedelta(days=i)).strftime("%Y-%m-%d")
    filename = f"supabase-logs/{date}_search_traces.json"
    
    try:
        blob = container.get_blob_client(filename)
        data = json.loads(blob.download_blob().readall())
        all_traces.extend(data)
        print(f"✅ Loaded {date}: {len(data)} traces")
    except Exception as e:
        print(f"⚠️  {date}: {e}")

# Analyze
print(f"\nTotal traces (30 days): {len(all_traces)}")
print(f"Unique users: {len(set(t['user_id'] for t in all_traces))}")

# Filter by intent
by_intent = {}
for trace in all_traces:
    intent = trace.get('intent_classification', 'UNKNOWN')
    by_intent[intent] = by_intent.get(intent, 0) + 1

print(f"By intent: {by_intent}")
```

---

## Next Steps

1. ✅ Create Azure containers
2. ✅ Push Supabase migration
3. ✅ Set environment variables
4. ✅ Deploy updated backend (with APScheduler)
5. Test manual export: `POST /api/v1/logs/export/supabase-logs`
6. Check daily exports running at 01:00 UTC
7. Set up analytics on archived data

---

## Files Created/Modified

- **New:** `app/api/v1/log_export.py` - Export endpoints
- **New:** `app/services/scheduled_tasks.py` - Scheduled task manager
- **New:** `notesapp-deploy/supabase/migrations/20260226000000_log_exports.sql` - Tracking table
- **Modified:** `app/main.py` - Added scheduler initialization
- **Modified:** `requirements.txt` - Added `apscheduler`
