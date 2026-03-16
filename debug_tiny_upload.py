"""Upload a TINY PDF and check trace for debug info"""
import requests
import time
from fpdf import FPDF

WORKER_URL = "https://notesapp-vector-search.monocle0712.workers.dev"
API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"
SUPABASE_URL = "https://vnpqsmiuismvwsynpmfu.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8"

# Create TINY PDF - just 1 page with a few words
pdf = FPDF()
pdf.add_page()
pdf.set_font("Helvetica", "", 12)
pdf.cell(0, 10, "Hello World. This is a tiny test document.")
pdf_bytes = bytes(pdf.output())
print(f"Tiny PDF size: {len(pdf_bytes)} bytes")

# Upload
files = {"file": ("tiny_test.pdf", pdf_bytes, "application/pdf")}
headers = {"X-API-Key": API_KEY}
resp = requests.post(f"{WORKER_URL}/api/v1/upload/file", files=files, data={"tag": "test"}, headers=headers)
print(f"Upload: {resp.status_code}")
result = resp.json()
print(f"Result: {result}")
trace_id = result.get("trace_id", "")

if not trace_id:
    print("No trace_id!")
    exit(1)

# Poll for status
print(f"\nPolling: {trace_id}")
for i in range(40):
    time.sleep(2)
    r = requests.get(f"{WORKER_URL}/api/v1/upload/status/{trace_id}", headers=headers)
    s = r.json()
    status = s.get("status", "?")
    conv_method = s.get("conversion_method")
    note_id = s.get("note_id")
    error = s.get("error")
    
    print(f"  [{i+1:2d}] status={status:12s} method={conv_method} note={note_id} error={error}")
    
    if status in ("completed", "failed"):
        break

# Get full trace details from Supabase
print("\n=== Full Trace Details ===")
sh = {"apikey": SUPABASE_KEY, "Authorization": f"Bearer {SUPABASE_KEY}"}
r = requests.get(
    f"{SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.{trace_id}&select=*",
    headers=sh
)
trace = r.json()[0] if r.json() else {}
for k in ["status", "processing_started_at", "blob_url", "conversion_started_at", 
          "conversion_completed_at", "conversion_method", "timing_conversion_ms",
          "error_message", "pipeline_errors", "note_id", "timing_total_ms"]:
    print(f"  {k}: {trace.get(k)}")
