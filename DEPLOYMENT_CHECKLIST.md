# Log Export Deployment Checklist

## ✅ Setup Complete
- [x] Created `app/api/v1/log_export.py` with REST endpoints
- [x] Created `app/services/scheduled_tasks.py` with APScheduler
- [x] Updated `app/main.py` with scheduler lifecycle
- [x] Added `apscheduler>=3.10.0` to `requirements.txt`
- [x] Installed APScheduler locally (`pip install apscheduler`)
- [x] Created Supabase migration for `log_exports` table
- [x] Updated frontend with token refresh logic

## 📋 Pre-Deployment Steps

### 1. **Verify Azure Storage Setup**
```powershell
# List containers to verify they were created
az storage container list --connection-string "$env:AZURE_STORAGE_CONNECTION_STRING"
```

Expected output: `supabase-logs` and `cloudflare-logs` containers should exist.

### 2. **Push Supabase Migration** (if Supabase CLI available)
```bash
cd notesapp-deploy
supabase db push
```

**Alternative: Create table manually via Supabase dashboard**
- Open Supabase dashboard → SQL Editor
- Run the migration SQL from `notesapp-deploy/supabase/migrations/20260226000000_log_exports.sql`

### 3. **Set Environment Variables** (Cloudflare logs export)
If using Cloudflare log export, set these in Fly.io or your deployment platform:
```
CLOUDFLARE_API_TOKEN=your_api_token
CLOUDFLARE_ACCOUNT_ID=your_account_id
```

Get these from:
- **CLOUDFLARE_API_TOKEN**: Cloudflare → Account → API Tokens (create token with Logpush permission)
- **CLOUDFLARE_ACCOUNT_ID**: From `wrangler.toml` or Cloudflare dashboard

### 4. **Deploy Backend**

#### Option A: Deploy to Fly.io
```bash
fly deploy
```

#### Option B: Docker Build & Push
```bash
docker build -t your-registry/notesapp-backend:latest .
docker push your-registry/notesapp-backend:latest
```

## 🧪 Post-Deployment Verification

### 1. **Test Manual Supabase Log Export**
```bash
curl -X POST http://localhost:8000/api/v1/logs/export/supabase-logs \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```

Expected response:
```json
{
  "job_id": "uuid",
  "status": "started",
  "message": "Export job started"
}
```

### 2. **Test Manual Cloudflare Log Export** (if configured)
```bash
curl -X POST http://localhost:8000/api/v1/logs/export/cloudflare-logs \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```

### 3. **Check Azure Blobs**
```powershell
az storage blob list --container-name supabase-logs --connection-string "$env:AZURE_STORAGE_CONNECTION_STRING"
az storage blob list --container-name cloudflare-logs --connection-string "$env:AZURE_STORAGE_CONNECTION_STRING"
```

### 4. **Verify Scheduled Tasks** (next day at 01:00/01:30 UTC)
- Monitor logs for: `"Successfully exported X traces to supabase-logs/..."`
- Check if files appear in Azure containers with correct timestamps

## 🔍 Export File Structure

### Supabase Logs
**Container:** `supabase-logs`
**Path:** `YYYY-MM-DD/search_upload_traces_HHMMSS.json`
**Content:**
```json
{
  "search_traces": [...],
  "upload_traces": [...],
  "export_metadata": {
    "export_time": "2026-02-26T09:00:00",
    "job_id": "uuid",
    "total_records": 45,
    "time_range": {
      "from": "2026-02-24T09:00:00",
      "to": "2026-02-26T09:00:00"
    }
  }
}
```

### Cloudflare Logs
**Container:** `cloudflare-logs`
**Path:** `YYYY-MM-DD_worker_logs.json`
**Content:** Raw Cloudflare Logpull API response

## 📊 Scheduled Export Times
- **Supabase logs:** Daily at 01:00 UTC
- **Cloudflare logs:** Daily at 01:30 UTC (if configured)

## 🚀 Next Steps After Deployment
1. Verify first scheduled export runs (check logs and Azure containers)
2. Monitor for any errors in application logs
3. If issues occur, check:
   - Azure connection string is valid
   - Containers exist and are accessible
   - Supabase tables are properly created
   - Environment variables are set (for Cloudflare)
