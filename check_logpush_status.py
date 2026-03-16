import requests
import json

CLOUDFLARE_ACCOUNT_ID = '540f86da830862f033e02d84633d59dd'

with open('.env', 'r') as f:
    for line in f:
        if line.startswith('CLOUDFLARE_API_TOKEN=') and 'OLD' not in line:
            CLOUDFLARE_API_TOKEN = line.split('=', 1)[1].strip()
            break

headers = {
    'Authorization': f'Bearer {CLOUDFLARE_API_TOKEN}'
}

# Get job details including any errors
response = requests.get(
    f'https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/logpush/jobs/1453570',
    headers=headers
)
job = response.json().get('result', {})

print('=== Logpush Job Status ===')
print(f"Job ID: {job.get('id')}")
print(f"Name: {job.get('name')}")
print(f"Dataset: {job.get('dataset')}")
print(f"Enabled: {job.get('enabled')}")
print(f"Frequency: {job.get('frequency')}")
print(f"Last Complete: {job.get('last_complete')}")
print(f"Last Error: {job.get('last_error')}")
print(f"Error Message: {job.get('error_message')}")
print()

dest = job.get('destination_conf', '')
print('Destination Analysis:')
if '?' in dest:
    url_part = dest.split('?')[0]
    sas_part = dest.split('?')[1]
    print(f"  URL: {url_part}")
    
    # Analyze SAS params
    if 'sr=c' in sas_part:
        print("  SAS Type: Container-level (sr=c) - MAY NOT WORK")
    if 'srt=o' in sas_part:
        print("  SAS Type: Account-level Object (srt=o) - CORRECT")
    if 'sp=w' in sas_part:
        print("  Permissions: Write (sp=w) - CORRECT")
    if 'ss=b' in sas_part:
        print("  Service: Blob (ss=b) - CORRECT")
    
    # Check for issues
    if 'sr=c' in sas_part and 'srt=o' not in sas_part:
        print()
        print("⚠️  ISSUE: Container-level SAS (sr=c) may not work!")
        print("   Cloudflare requires Account-level SAS with srt=o (object)")
