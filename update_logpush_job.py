"""
Update Cloudflare Logpush job with correct SAS URL (srt=o)
"""
import requests
import json

CLOUDFLARE_ACCOUNT_ID = '540f86da830862f033e02d84633d59dd'
JOB_ID = 1453570

with open('.env', 'r') as f:
    for line in f:
        if line.startswith('CLOUDFLARE_API_TOKEN=') and 'OLD' not in line:
            CLOUDFLARE_API_TOKEN = line.split('=', 1)[1].strip()
            break

with open('azure_sas_url.txt', 'r') as f:
    AZURE_SAS_URL = f.read().strip()

# Convert https:// to azure:// and add {DATE} for daily folders
azure_dest = AZURE_SAS_URL.replace('https://', 'azure://')
# Insert {DATE} before the query params
if '?' in azure_dest:
    base, params = azure_dest.split('?', 1)
    azure_dest = f"{base}/{{DATE}}?{params}"

print(f"Updating Logpush job {JOB_ID}...")
print(f"New destination: {azure_dest[:80]}...")

headers = {
    'Authorization': f'Bearer {CLOUDFLARE_API_TOKEN}',
    'Content-Type': 'application/json'
}

# Update the job with correct SAS URL
response = requests.put(
    f'https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/logpush/jobs/{JOB_ID}',
    headers=headers,
    json={
        'destination_conf': azure_dest
    }
)

result = response.json()

if result.get('success'):
    print("\n✅ SUCCESS! Logpush job updated with correct SAS URL")
    job = result.get('result', {})
    print(f"   Job ID: {job.get('id')}")
    print(f"   Enabled: {job.get('enabled')}")
    print("\nLogs should start flowing to Azure within 2-5 minutes.")
else:
    print(f"\n❌ Failed to update job")
    print(f"   Status: {response.status_code}")
    print(f"   Response: {json.dumps(result, indent=2)}")
