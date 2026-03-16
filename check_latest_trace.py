"""Check latest upload trace details"""
import requests
import json

SUPABASE_URL = 'https://vnpqsmiuismvwsynpmfu.supabase.co'
SERVICE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8'

resp = requests.get(
    f'{SUPABASE_URL}/rest/v1/upload_traces?order=created_at.desc&limit=2',
    headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}
)
data = resp.json()
for d in data:
    print("=" * 60)
    for key in ['trace_id', 'original_filename', 'status', 'blob_url', 'conversion_method',
                'pipeline_errors', 'timing_blob_upload_ms', 'timing_conversion_ms',
                'blob_upload_completed_at', 'conversion_started_at', 'conversion_completed_at']:
        val = d.get(key)
        if val:
            print(f"  {key}: {val}")
    print()
