# Cloudflare Logpush to Azure Setup

## Step 1: Generate Azure SAS Token (5 minutes)

### Via Azure Portal UI (Easiest)

1. **Open Azure Portal**
   - Go to https://portal.azure.com
   - Login with your account

2. **Navigate to Storage Account**
   - Search for "rawnotesstorage" or go to Storage accounts
   - Click **rawnotesstorage**

3. **Go to Containers**
   - Left sidebar: **Containers**
   - Click on **cloudflare-logs** container

4. **Generate SAS Token**
   - Right-click the container name → **Generate SAS**
   - Or click the three dots (menu) → **Generate SAS**

5. **Configure SAS Settings**
   ```
   Signing key: key1 (default)
   Signed permission: ☑ Write (UNCHECK all others)
   Start time: (today's date)
   Expiration time: (set to 5 years from now)
              Example: 2031-02-26
   Allowed IP addresses: (leave empty)
   Allowed protocols: HTTPS only
   ```

6. **Generate & Copy URL**
   - Click **Generate SAS token and URL**
   - Copy the **Blob SAS URL** (the full URL starting with `https://`)
   - Save it - you'll need this in the next step

**Expected URL format:**
```
https://rawnotesstorage.blob.core.windows.net/cloudflare-logs?sv=2024-11-24&ss=b&srt=o&sp=w&se=2031-02-26T...&sig=xxxxx
```

### Validation Checklist
- ✅ Service: Blob-only (`ss=b` in URL)
- ✅ Signed resource type: Object-only (`srt=o` in URL)
- ✅ Signed permission: Write-only (`sp=w` in URL)
- ✅ 5-year expiration (critical!)

---

## Step 2: Create Logpush Job in Cloudflare (5 minutes)

### Via Cloudflare Dashboard (Recommended)

1. **Open Cloudflare Dashboard**
   - Go to https://dash.cloudflare.com/?to=/:account/logs
   - Or: Dashboard → Logs → Logpush

2. **Create New Job**
   - Click **Create a Logpush job**

3. **Select Destination**
   - Choose **Microsoft Azure**
   - Paste your **Blob SAS URL** (from Step 1)
   - Path: `/` (or leave blank - logs go to root of container)
   - ☑ **Check "Organize logs into daily subfolders"** ← Important!

4. **Select Dataset**
   - Dataset: **Workers Trace Events** ← This is for your Worker logs
   - Click **Next**

5. **Configure Fields** (Optional)
   - Leave as default or customize if needed
   - Recommended: Get all fields initially, can customize later
   - Click **Next**

6. **Job Configuration**
   - **Job name:** `workers-trace-events`
   - Frequency: Daily (default) ✅
   - Click **Next**

7. **Ownership Challenge** (if required)
   - Cloudflare will ask to verify you own the destination
   - Follow the verification steps in the UI

8. **Submit**
   - Click **Submit** to create the job
   - Status should show: ✅ **Enabled**

---

## Step 3: Enable Logging on Your Worker (2 minutes)

### Option A: Via Cloudflare Dashboard (Easiest)

1. **Go to Workers & Pages**
   - Cloudflare Dashboard → **Workers & Pages**
   - Click **notesapp-vector-search**

2. **Settings → Observability**
   - Left sidebar: **Settings**
   - Tab: **Observability**

3. **Enable Logpush**
   - **Logpush:** Click **Enable**
   - (Only appears after the Logpush job is created)
   - Status: ✅ **Enabled**

### Option B: Via wrangler.toml (Already Done ✅)

Your `wrangler.toml` already has:
```toml
logpush = true
```

---

## Step 4: Verification (Next Day)

Once everything is set up, logs will start flowing:

### Check Azure Portal
```
1. Azure Portal → rawnotesstorage → cloudflare-logs
2. You should see daily folders: 2026/02/26/, 2026/02/27/, etc.
3. Each folder contains JSON files with worker trace events
4. Example files:
   - 2026/02/26/notesapp-vector-search_0_20260226_010000_abc123.json
   - 2026/02/26/notesapp-vector-search_1_20260226_010000_xyz789.json
```

### Check Cloudflare Dashboard
```
Dashboard → Logs → Logpush
- Job name: "workers-trace-events"
- Status: "Healthy" or "Enabled"
- Last pushed: Shows recent push time
- Records pushed: Total count
```

### Check Worker Logs in Cloudflare
```
Workers & Pages → notesapp-vector-search → Logs
- You'll see real-time logs from your worker
- These are also being exported to Azure
```

---

## File Structure in Azure

Your logs will appear in Azure Blob Storage like:
```
cloudflare-logs/
├── 2026/02/26/
│   └── notesapp-vector-search_0_20260226_010000_abc123.json
│   └── notesapp-vector-search_1_20260226_010000_xyz789.json
├── 2026/02/27/
│   └── notesapp-vector-search_0_20260227_010000_def456.json
│   └── ...
```

Each JSON file contains worker trace events:
```json
{
  "Outcome": "ok",
  "Exceptions": [],
  "Logs": [
    {
      "Level": "log",
      "Message": ["User 123: Searching for 'aadhaar'"]
    }
  ],
  "EventTimestampMs": 1709000000000,
  "ScriptName": "notesapp-vector-search"
}
```

---

## Troubleshooting

### "signedResourceTypes must be Object only (srt=o)"
- Your SAS token has wrong settings
- Regenerate in Azure Portal with exactly these settings:
  - Service: Blob-only (`ss=b`)
  - Resource type: Object-only (`srt=o`)
  - Permission: Write-only (`sp=w`)

### "SAS token expired"
- SAS tokens expire after the set time (you set it to 5 years)
- Need to regenerate and update Logpush job with new URL
- Can be done via Cloudflare API: `PATCH /accounts/{id}/logpush/jobs/{job_id}`

### No logs appearing in Azure
1. Check Logpush job status in Cloudflare Dashboard
2. Verify job is "Enabled"
3. Verify your worker is receiving traffic
4. Wait for next scheduled push (typically daily around 01:00 UTC)
5. Check Logpush health dashboard for errors

### Worker logs appearing in Cloudflare but not Azure
- Logpush job is not enabled
- Enable in Cloudflare Dashboard → Workers & Pages → Observability
- Or verify `logpush = true` in your deployed wrangler.toml

---

## Next Steps (After Verification)

Once Cloudflare logs are flowing to Azure, we can:
1. Set up Supabase logs export (separate)
2. Create analytics queries across both log types
3. Set up alerts for errors
4. Archive older logs to cheaper storage tier

---

## Quick Reference

| Step | Time | Action | Verification |
|------|------|--------|--------------|
| 1 | 5 min | Generate Azure SAS token | URL contains `ss=b&srt=o&sp=w` |
| 2 | 5 min | Create Cloudflare Logpush job | Job shows "Enabled" |
| 3 | 2 min | Enable logging on Worker | Worker → Observability → Logpush: Enabled |
| 4 | 24h | Wait for logs | Check Azure Portal for daily folders |

