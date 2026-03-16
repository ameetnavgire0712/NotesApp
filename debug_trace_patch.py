"""Deep diagnosis: compare notes vs traces to find the disconnect"""
import requests

SUPABASE_URL = "https://vnpqsmiuismvwsynpmfu.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8"
USER_ID = "2649b4d0-c40d-4ab1-ac04-928fe1cf5969"

headers = {
    "apikey": SUPABASE_KEY,
    "Authorization": f"Bearer {SUPABASE_KEY}",
}

# Check ALL recent notes (last 10)
print("=== ALL Recent Notes (last 10) ===")
r = requests.get(
    f"{SUPABASE_URL}/rest/v1/notes?user_id=eq.{USER_ID}&order=created_at.desc&limit=10&select=id,title,original_filename,created_at,file_type",
    headers=headers
)
for note in r.json():
    print(f"  {note['created_at'][:19]}  file={note.get('original_filename','?')}")
    print(f"    id={note['id']}  title={note.get('title','?')[:60]}")

# Check ALL recent traces (last 10)
print("\n=== ALL Recent Traces (last 10) ===")
r = requests.get(
    f"{SUPABASE_URL}/rest/v1/upload_traces?user_id=eq.{USER_ID}&order=request_received_at.desc&limit=10&select=trace_id,original_filename,status,request_received_at,processing_started_at,note_id,error_message,conversion_method,timing_total_ms,completed_at",
    headers=headers
)
for t in r.json():
    print(f"  {t['request_received_at'][:19]}  status={t['status']:12s}  file={t.get('original_filename','?')}")
    print(f"    proc_started={str(t.get('processing_started_at','null'))[:19]:20s}  completed={str(t.get('completed_at','null'))[:19]}")
    print(f"    note_id={t.get('note_id','null')}  method={t.get('conversion_method','null')}  total_ms={t.get('timing_total_ms','null')}")

# Test updateUploadTrace directly - try patching a stuck trace
print("\n=== Testing PATCH on stuck trace ===")
stuck_traces = requests.get(
    f"{SUPABASE_URL}/rest/v1/upload_traces?user_id=eq.{USER_ID}&status=eq.accepted&order=request_received_at.desc&limit=1&select=trace_id",
    headers=headers
).json()

if stuck_traces:
    tid = stuck_traces[0]['trace_id']
    print(f"Patching trace: {tid}")
    
    # Try a minimal PATCH
    patch_resp = requests.patch(
        f"{SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.{tid}",
        headers={
            **headers,
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        },
        json={"status": "test_patch"}
    )
    print(f"  PATCH status: {patch_resp.status_code}")
    print(f"  PATCH response: {patch_resp.text[:200] if patch_resp.text else '(empty)'}")
    
    # Revert
    if patch_resp.status_code < 300:
        requests.patch(
            f"{SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.{tid}",
            headers={**headers, "Content-Type": "application/json", "Prefer": "return=minimal"},
            json={"status": "accepted"}
        )
        print("  Reverted back to 'accepted'")
    
    # Now try with pipeline_errors (array type - potential issue?)
    print("\n  Testing with pipeline_errors array...")
    patch_resp2 = requests.patch(
        f"{SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.{tid}",
        headers={**headers, "Content-Type": "application/json", "Prefer": "return=representation"},
        json={
            "status": "test_with_array",
            "pipeline_errors": ["error1", "error2"],
        }
    )
    print(f"  PATCH with array: {patch_resp2.status_code}")
    if patch_resp2.status_code >= 300:
        print(f"  Error: {patch_resp2.text[:300]}")
    
    # Revert
    if patch_resp2.status_code < 300:
        requests.patch(
            f"{SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.{tid}",
            headers={**headers, "Content-Type": "application/json", "Prefer": "return=minimal"},
            json={"status": "accepted", "pipeline_errors": None}
        )
        print("  Reverted")
