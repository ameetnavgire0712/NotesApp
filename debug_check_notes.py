"""Check if notes were actually created despite traces being stuck"""
import requests

SUPABASE_URL = "https://vnpqsmiuismvwsynpmfu.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8"
USER_ID = "2649b4d0-c40d-4ab1-ac04-928fe1cf5969"

headers = {
    "apikey": SUPABASE_KEY,
    "Authorization": f"Bearer {SUPABASE_KEY}",
}

# Check recent notes
print("=== Recent Notes (last 5) ===")
r = requests.get(
    f"{SUPABASE_URL}/rest/v1/notes?user_id=eq.{USER_ID}&order=created_at.desc&limit=5&select=id,title,original_filename,created_at,file_type",
    headers=headers
)
for note in r.json():
    print(f"  {note['created_at'][:19]}  {note.get('original_filename','?'):40s} title={note.get('title','?')[:50]}")

# Check recent upload traces
print("\n=== Recent Upload Traces (last 5) ===")
r = requests.get(
    f"{SUPABASE_URL}/rest/v1/upload_traces?user_id=eq.{USER_ID}&order=request_received_at.desc&limit=5&select=trace_id,original_filename,status,request_received_at,processing_started_at,note_id,error_message,conversion_method",
    headers=headers
)
for t in r.json():
    print(f"  {t['request_received_at'][:19]}  status={t['status']:10s}  file={t.get('original_filename','?'):40s}")
    print(f"    processing_started={t.get('processing_started_at','null')}")
    print(f"    note_id={t.get('note_id','null')}  method={t.get('conversion_method','null')}")
    print(f"    error={t.get('error_message','null')}")
