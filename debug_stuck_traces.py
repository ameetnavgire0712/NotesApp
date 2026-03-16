"""Check stuck processing traces"""
import requests

SUPABASE_URL = 'https://vnpqsmiuismvwsynpmfu.supabase.co'
SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8'
h = {'apikey': SUPABASE_KEY, 'Authorization': f'Bearer {SUPABASE_KEY}'}

r = requests.get(
    f'{SUPABASE_URL}/rest/v1/upload_traces?status=eq.processing&order=request_received_at.desc&limit=5',
    headers=h
)

for t in r.json():
    fname = t.get('original_filename', '?')
    tid = t['trace_id']
    print(f"{fname} ({tid})")
    
    req = t.get('request_received_at', '?')
    print(f"  requested: {req[:19] if req else '?'}")
    
    proc = t.get('processing_started_at')
    print(f"  proc_started: {proc[:19] if proc else 'null'}")
    
    blob = t.get('blob_url')
    print(f"  blob_url: {'SET' if blob else 'null'}")
    
    conv_start = t.get('conversion_started_at')
    print(f"  conv_started: {conv_start[:19] if conv_start else 'null'}")
    
    conv_end = t.get('conversion_completed_at')
    print(f"  conv_completed: {conv_end[:19] if conv_end else 'null'}")
    
    print(f"  conv_ms: {t.get('timing_conversion_ms', 'null')}")
    print(f"  error: {t.get('error_message', 'null')}")
    print(f"  pipeline_errors: {t.get('pipeline_errors', 'null')}")
    print()
