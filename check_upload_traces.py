import requests, json

# Check latest upload traces
url = 'https://vnpqsmiuismvwsynpmfu.supabase.co/rest/v1/upload_traces?order=created_at.desc&limit=3'
headers = {
    'apikey': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8',
    'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8'
}
r = requests.get(url, headers=headers)
for t in r.json():
    print(f"trace: {t['trace_id']}")
    print(f"  file: {t.get('original_filename','')}")
    print(f"  status: {t['status']}")
    print(f"  error: {t.get('error_message','')}")
    print(f"  pipeline: {t.get('pipeline_errors','')}")
    print(f"  conversion: {t.get('conversion_method','')}")
    print(f"  chunks: {t.get('chunk_count','')}")
    print(f"  total_ms: {t.get('timing_total_ms','')}")
    print()
