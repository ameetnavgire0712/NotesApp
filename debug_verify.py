"""Check latest upload traces to verify full pipeline data"""
import requests, json

SUPABASE_URL = "https://vnpqsmiuismvwsynpmfu.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8"

headers = {
    "apikey": SUPABASE_KEY,
    "Authorization": f"Bearer {SUPABASE_KEY}",
}

resp = requests.get(
    f"{SUPABASE_URL}/rest/v1/upload_traces?order=request_received_at.desc&limit=4&select=trace_id,original_filename,status,processing_started_at,conversion_method,timing_total_ms,timing_blob_upload_ms,timing_conversion_ms,timing_title_gen_ms,timing_embedding_ms,timing_db_insert_ms,timing_vectorize_ms,note_id,content_length,chunk_count,vector_count,error_message,pipeline_errors",
    headers=headers,
)
traces = resp.json()
for t in traces:
    print(f"\n{'='*60}")
    print(f"File: {t.get('original_filename')}")
    print(f"Status: {t.get('status')}")
    print(f"Processing started: {t.get('processing_started_at')}")
    print(f"Note ID: {t.get('note_id')}")
    print(f"Conversion: {t.get('conversion_method')} | Content: {t.get('content_length')} chars")
    print(f"Chunks: {t.get('chunk_count')} | Vectors: {t.get('vector_count')}")
    print(f"Timing: total={t.get('timing_total_ms')}ms blob={t.get('timing_blob_upload_ms')}ms conv={t.get('timing_conversion_ms')}ms title={t.get('timing_title_gen_ms')}ms embed={t.get('timing_embedding_ms')}ms db={t.get('timing_db_insert_ms')}ms vec={t.get('timing_vectorize_ms')}ms")
    if t.get('error_message'): print(f"Error: {t.get('error_message')}")
    if t.get('pipeline_errors'): print(f"Pipeline errors: {t.get('pipeline_errors')}")
