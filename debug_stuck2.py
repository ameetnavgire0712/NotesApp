"""Check if notes were created despite stuck traces"""
import requests

SUPABASE_URL = "https://vnpqsmiuismvwsynpmfu.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8"
h = {"apikey": SUPABASE_KEY, "Authorization": f"Bearer {SUPABASE_KEY}"}

# Check for Rehire Policy note
r = requests.get(f"{SUPABASE_URL}/rest/v1/notes?original_filename=ilike.*Rehire*&order=created_at.desc&limit=3&select=id,title,original_filename,created_at", headers=h)
notes = r.json()
print("=== Rehire Policy Notes ===")
for n in notes:
    print(f"  {n['created_at'][:19]}  id={n['id'][:20]}...  file={n.get('original_filename','?')}")
if not notes:
    print("  (none found)")

# Check all recent notes
print()
print("=== All Recent Notes (last 8) ===")
r = requests.get(f"{SUPABASE_URL}/rest/v1/notes?order=created_at.desc&limit=8&select=id,title,original_filename,created_at", headers=h)
for n in r.json():
    fname = n.get('original_filename', '?') or '?'
    print(f"  {n['created_at'][:19]}  file={fname[:40]}")

# Check stuck traces with more detail
print()
print("=== Stuck 'processing' Traces ===")
r = requests.get(f"{SUPABASE_URL}/rest/v1/upload_traces?status=eq.processing&order=request_received_at.desc&select=trace_id,original_filename,processing_started_at,blob_url,conversion_started_at,conversion_completed_at,timing_conversion_ms", headers=h)
for t in r.json():
    print(f"  {t.get('original_filename','?')}")
    print(f"    proc_started: {t.get('processing_started_at','?')}")
    print(f"    blob_url: {t.get('blob_url','null')}")
    print(f"    conv_started: {t.get('conversion_started_at','null')}")
    print(f"    conv_completed: {t.get('conversion_completed_at','null')}")
    print(f"    conv_ms: {t.get('timing_conversion_ms','null')}")
