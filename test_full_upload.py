"""Test complete upload flow (no cancel)"""
import requests
import time
import json

WORKER_URL = 'https://notesapp-vector-search.monocle0712.workers.dev'
SB_URL = 'https://vnpqsmiuismvwsynpmfu.supabase.co'
SB_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc5NDM3OTUsImV4cCI6MjA4MzUxOTc5NX0.D-U6mkNHxh8mGYwgQy9-qEKh3e2wLNirppV2ASivrUg'
SB_SERVICE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8'

def get_session_token():
    """Get a real Supabase session token"""
    email = 'cancel_test@example.com'
    password = 'TestCancel123!'
    
    r = requests.post(
        f'{SB_URL}/auth/v1/token?grant_type=password',
        headers={
            'apikey': SB_ANON_KEY,
            'Content-Type': 'application/json'
        },
        json={
            'email': email,
            'password': password
        },
        timeout=10
    )
    
    if r.status_code == 200:
        data = r.json()
        return data.get('access_token'), data.get('user', {}).get('id')
    else:
        print(f"Login error: {r.text}")
        return None, None

def wait_for_completion(trace_id, max_wait=120):
    """Poll database for completion"""
    for i in range(max_wait // 2):
        r = requests.get(
            f'{SB_URL}/rest/v1/upload_traces?trace_id=eq.{trace_id}&select=*',
            headers={
                'apikey': SB_SERVICE_KEY,
                'Authorization': f'Bearer {SB_SERVICE_KEY}'
            },
            timeout=10
        )
        if r.status_code == 200:
            traces = r.json()
            if traces:
                trace = traces[0]
                status = trace.get('status')
                print(f"  [{i*2}s] Status: {status}")
                if status in ('completed', 'failed', 'cancelled'):
                    return trace
        time.sleep(2)
    return None

def test_full_upload():
    """Test a full upload to completion"""
    jwt_token, user_id = get_session_token()
    
    if not jwt_token:
        print("Failed to get JWT token")
        return
    
    print(f"User ID: {user_id}")
    
    # Upload a PDF file
    upload_url = f'{WORKER_URL}/api/v1/upload/file'
    pdf_path = r'c:\Users\ameet\Documents\NotesApp\test_upload.pdf'
    
    with open(pdf_path, 'rb') as f:
        pdf_content = f.read()
    
    files = {
        'file': ('complete_upload_test.pdf', pdf_content, 'application/pdf')
    }
    
    headers = {
        'Authorization': f'Bearer {jwt_token}'
    }
    
    print("\nUploading file (full completion test)...")
    r = requests.post(upload_url, files=files, headers=headers, timeout=30)
    print(f"Upload status: {r.status_code}")
    
    if r.status_code in (200, 202):
        data = r.json()
        trace_id = data.get('trace_id')
        print(f"Trace ID: {trace_id}")
        
        # Wait for completion
        print("\nWaiting for upload to complete...")
        trace = wait_for_completion(trace_id)
        
        if trace:
            print(f"\n=== Final Result ===")
            print(f"Status: {trace.get('status')}")
            print(f"Note ID: {trace.get('note_id')}")
            print(f"Title: {trace.get('title')}")
            print(f"Error: {trace.get('error_message')}")
            
            # Show timing
            timing = trace.get('step_timing', {})
            if isinstance(timing, str):
                timing = json.loads(timing)
            if timing:
                print(f"\nTiming breakdown:")
                for step, ms in timing.items():
                    print(f"  {step}: {ms}ms")
        else:
            print("Timed out waiting for completion")
    else:
        print(f"Upload error: {r.text}")

if __name__ == '__main__':
    test_full_upload()
