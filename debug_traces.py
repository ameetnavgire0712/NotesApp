"""Quick debug script to check recent upload traces"""
import requests, json

SB_URL = "https://vnpqsmiuismvwsynpmfu.supabase.co"
SB_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8"
HEADERS = {"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}"}

r = requests.get(
    f"{SB_URL}/rest/v1/upload_traces?order=created_at.desc&limit=8"
    "&select=trace_id,status,original_filename,created_at,conversion_method,error_message,pipeline_errors,timing_total_ms,blob_url,note_id",
    headers=HEADERS
)
for t in r.json():
    print(f"{t['created_at'][:19]}  {t['status']:10s}  method={t.get('conversion_method') or '?':15s}  "
          f"file={t.get('original_filename') or '?':30s}  note={t.get('note_id') or '-':36s}  "
          f"errors={t.get('pipeline_errors') or '-'}")
