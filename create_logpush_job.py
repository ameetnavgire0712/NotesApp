"""
Create Cloudflare Logpush job to export Workers Trace Events to Azure Blob Storage
"""
import os
import requests
import json

# Configuration
CLOUDFLARE_ACCOUNT_ID = "540f86da830862f033e02d84633d59dd"

# Read SAS URL from file
with open("azure_sas_url.txt", "r") as f:
    AZURE_SAS_URL = f.read().strip()

# Cloudflare API token - check multiple sources
CLOUDFLARE_API_TOKEN = os.getenv("CLOUDFLARE_API_TOKEN")

if not CLOUDFLARE_API_TOKEN:
    # Try reading from .env file
    try:
        with open(".env", "r") as f:
            for line in f:
                if line.startswith("CLOUDFLARE_API_TOKEN=") and "OLD" not in line:
                    CLOUDFLARE_API_TOKEN = line.split("=", 1)[1].strip()
                    break
    except:
        pass

if not CLOUDFLARE_API_TOKEN:
    print("❌ CLOUDFLARE_API_TOKEN not found!")
    print("\nTo create a Cloudflare Logpush job, you need an API token with 'Logs Edit' permission.")
    print("\nSteps to create token:")
    print("1. Go to: https://dash.cloudflare.com/profile/api-tokens")
    print("2. Click 'Create Token'")
    print("3. Use 'Custom token' template")
    print("4. Add permission: Account / Logs / Edit")
    print("5. Create token and add to .env as CLOUDFLARE_API_TOKEN=xxx")
    print("\nOr create the Logpush job manually via Cloudflare Dashboard:")
    print("https://dash.cloudflare.com/?to=/:account/logs")
    exit(1)

print(f"✅ Using Cloudflare Account ID: {CLOUDFLARE_ACCOUNT_ID}")
print(f"✅ Azure SAS URL loaded")

# Build Logpush job configuration
# For Azure, Cloudflare expects: azure://rawnotesstorage.blob.core.windows.net/container?SAS_params
# Strip https:// and add azure:// prefix
azure_destination = AZURE_SAS_URL.replace("https://", "azure://")

logpush_job = {
    "name": "workers-trace-events-azure",
    "output_options": {
        "field_names": [
            "Event",
            "EventTimestampMs", 
            "Outcome",
            "Exceptions",
            "Logs",
            "ScriptName",
            "ScriptTags",
            "DispatchNamespace"
        ],
        "timestamp_format": "rfc3339"
    },
    "destination_conf": azure_destination,
    "dataset": "workers_trace_events",
    "enabled": True
}

print("\n📤 Creating Logpush job...")
print(f"   Dataset: workers_trace_events")
print(f"   Destination: Azure Blob Storage (cloudflare-logs container)")

# Create the Logpush job
headers = {
    "Authorization": f"Bearer {CLOUDFLARE_API_TOKEN}",
    "Content-Type": "application/json"
}

response = requests.post(
    f"https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/logpush/jobs",
    headers=headers,
    json=logpush_job
)

result = response.json()

if response.status_code == 200 and result.get("success"):
    job = result.get("result", {})
    print(f"\n✅ SUCCESS! Logpush job created!")
    print(f"   Job ID: {job.get('id')}")
    print(f"   Job Name: {job.get('name')}")
    print(f"   Dataset: {job.get('dataset')}")
    print(f"   Enabled: {job.get('enabled')}")
    print(f"\nLogs will be exported to: cloudflare-logs/worker-logs/")
    
    # Save job ID for reference
    with open("cloudflare_logpush_job.txt", "w") as f:
        f.write(json.dumps(job, indent=2))
    print("✅ Job details saved to: cloudflare_logpush_job.txt")
else:
    print(f"\n❌ Failed to create Logpush job")
    print(f"   Status: {response.status_code}")
    print(f"   Response: {json.dumps(result, indent=2)}")
    
    if "authentication" in str(result).lower() or response.status_code == 401:
        print("\n⚠️  Authentication failed. Your API token may not have 'Logs Edit' permission.")
        print("   Create a new token with the correct permissions at:")
        print("   https://dash.cloudflare.com/profile/api-tokens")
