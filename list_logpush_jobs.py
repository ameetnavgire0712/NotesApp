"""
List existing Cloudflare Logpush jobs
"""
import os
import requests
import json

CLOUDFLARE_ACCOUNT_ID = "540f86da830862f033e02d84633d59dd"

# Read API token from .env
with open(".env", "r") as f:
    for line in f:
        if line.startswith("CLOUDFLARE_API_TOKEN=") and "OLD" not in line:
            CLOUDFLARE_API_TOKEN = line.split("=", 1)[1].strip()
            break

headers = {
    "Authorization": f"Bearer {CLOUDFLARE_API_TOKEN}",
    "Content-Type": "application/json"
}

print("📋 Listing existing Logpush jobs...\n")

response = requests.get(
    f"https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/logpush/jobs",
    headers=headers
)

result = response.json()

if result.get("success"):
    jobs = result.get("result", [])
    print(f"Found {len(jobs)} existing Logpush job(s):\n")
    
    for job in jobs:
        print(f"  Job ID: {job.get('id')}")
        print(f"  Name: {job.get('name')}")
        print(f"  Dataset: {job.get('dataset')}")
        print(f"  Enabled: {job.get('enabled')}")
        print(f"  Destination: {job.get('destination_conf', 'N/A')[:80]}...")
        print()
    
    # Save job IDs
    with open("cloudflare_existing_jobs.json", "w") as f:
        json.dump(jobs, f, indent=2)
    print("✅ Job details saved to: cloudflare_existing_jobs.json")
else:
    print(f"❌ Failed to list jobs: {json.dumps(result, indent=2)}")
