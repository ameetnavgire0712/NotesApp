"""
Setup Cloudflare Logpush to export worker logs to Azure Blob Storage.

Requirements:
- Cloudflare account with Workers
- Azure Storage account with a blob container
- Cloudflare API token (with Logs Edit permission)
"""

import requests
import json
from datetime import datetime, timedelta
import os

# Configuration
CLOUDFLARE_ACCOUNT_ID = "540f86da830862f033e02d84633d59dd"  # From your .env
CLOUDFLARE_API_TOKEN = os.getenv("CLOUDFLARE_API_TOKEN")  # You'll need to set this
AZURE_ACCOUNT_NAME = "rawnotesstorage"
AZURE_CONTAINER_NAME = "cloudflare-logs"
AZURE_SAS_URL = None  # Will be provided by user

print("""
╔════════════════════════════════════════════════════════════════╗
║          CLOUDFLARE LOGPUSH → AZURE SETUP GUIDE               ║
╚════════════════════════════════════════════════════════════════╝

Step 1: Generate SAS Token for Azure (MANUAL in Azure Portal)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Go to Azure Portal: https://portal.azure.com
2. Navigate to Storage Account → rawnotesstorage
3. Go to Containers → cloudflare-logs
4. Right-click on container → Generate SAS
5. Configure:
   - Permissions: ✓ Write only (uncheck Read, Delete, List)
   - Start time: Today
   - Expiration: Today + 5 years (REQUIRED by Cloudflare)
   - Allowed IP: Leave blank
   - Allowed protocols: HTTPS only
6. Click "Generate SAS token and URL"
7. Copy the "Blob SAS URL" (full URL with ?sv=... token)

The URL should look like:
https://rawnotesstorage.blob.core.windows.net/cloudflare-logs?sv=2024-...&ss=b&srt=o&sp=w&...

Step 2: Create Logpush Job via Cloudflare API
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Option A: Via Cloudflare Dashboard (Recommended)
  1. Go to: https://dash.cloudflare.com/?to=/:account/logs
  2. Click "Create a Logpush job"
  3. Select destination: "Microsoft Azure"
  4. Enter:
     - SAS URL: (paste the full Blob SAS URL)
     - Path: / (or cloudflare-logs/ if you want subfolder)
     - Check "Organize logs into daily subfolders"
  5. Dataset: "Workers Trace Events"
  6. Job name: "workers-trace-events"
  7. Configure fields as needed
  8. Submit

Option B: Via API (if you have CLOUDFLARE_API_TOKEN set)
  - Run this script with CLOUDFLARE_API_TOKEN in .env
""")

if not CLOUDFLARE_API_TOKEN:
    print(f"\n⚠️  CLOUDFLARE_API_TOKEN is not set in environment.")
    print("   You need it to create the Logpush job via API.")
    print("\n   Get it from: Cloudflare Dashboard → API Tokens → Create Token")
    print("   Permissions needed: 'Logs Edit'")
    print("\n   Or use the Cloudflare Dashboard (Option A above) instead.")
else:
    print(f"\n✅ CLOUDFLARE_API_TOKEN found")
    print("\nYou can now create the Logpush job via API.")
    print("\nAwaiting SAS URL input...")
    
print("\n" + "="*70)
print("Step 3: Enable Logging on Your Worker")
print("="*70)
print("""
Edit your wrangler.toml and add:

[env.production]
logpush = true

Or manually enable in Cloudflare Dashboard:
  1. Workers & Pages → Your Worker
  2. Settings → Observability
  3. Logpush → Enable (only available after job is created)
""")
