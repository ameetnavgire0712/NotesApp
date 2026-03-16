"""Check stuck traces with full detail"""
import requests

SUPABASE_URL = "https://vnpqsmiuismvwsynpmfu.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8"
h = {"apikey": SUPABASE_KEY, "Authorization": f"Bearer {SUPABASE_KEY}"}

# Get recent traces
r = requests.get(
    f"{SUPABASE_URL}/rest/v1/upload_traces?order=request_received_at.desc&limit=10",
    headers=h
)

print("=== Recent Upload Traces ===\n")
for t in r.json():
    print(f"File: {t.get('original_filename', '?')}")
    print(f"  Trace ID: {t.get('trace_id')}")
    print(f"  Status: {t.get('status')}")
    print(f"  Request: {t.get('request_received_at', '?')[:19] if t.get('request_received_at') else '?'}")
    print(f"  Proc Started: {t.get('processing_started_at', 'null')}")
    print(f"  Blob URL: {'set' if t.get('blob_url') else 'null'}")
    print(f"  Blob Upload: {t.get('timing_blob_upload_ms', 'null')}ms")
    print(f"  Conv Started: {t.get('conversion_started_at', 'null')}")
    print(f"  Conv Completed: {t.get('conversion_completed_at', 'null')}")
    print(f"  Conv Method: {t.get('conversion_method', 'null')}")
    print(f"  Conv Time: {t.get('timing_conversion_ms', 'null')}ms")
    print(f"  Title Gen: {t.get('timing_title_gen_ms', 'null')}ms")
    print(f"  Embedding: {t.get('timing_embedding_ms', 'null')}ms")
    print(f"  DB Insert: {t.get('timing_db_insert_ms', 'null')}ms")
    print(f"  Vectorize: {t.get('timing_vectorize_ms', 'null')}ms")
    print(f"  Total: {t.get('timing_total_ms', 'null')}ms")
    print(f"  Note ID: {t.get('note_id', 'null')}")
    print(f"  Error: {t.get('error_message', 'null')}")
    print(f"  Pipeline Errors: {t.get('pipeline_errors', 'null')}")
    print()
