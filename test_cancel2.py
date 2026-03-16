"""Test cancel upload functionality - simplified"""
import requests
import time
import json

WORKER_URL = 'https://notesapp-vector-search.monocle0712.workers.dev'
SB_URL = 'https://vnpqsmiuismvwsynpmfu.supabase.co'
SB_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc5NDM3OTUsImV4cCI6MjA4MzUxOTc5NX0.D-U6mkNHxh8mGYwgQy9-qEKh3e2wLNirppV2ASivrUg'
SB_SERVICE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8'

def create_test_user():
    """Create a test user for cancel testing"""
    email = 'cancel_test@example.com'
    password = 'TestCancel123!'
    
    # Try to create user via admin API
    r = requests.post(
        f'{SB_URL}/auth/v1/admin/users',
        headers={
            'apikey': SB_SERVICE_KEY,
            'Authorization': f'Bearer {SB_SERVICE_KEY}',
            'Content-Type': 'application/json'
        },
        json={
            'email': email,
            'password': password,
            'email_confirm': True
        },
        timeout=10
    )
    
    print(f"Create user status: {r.status_code}")
    if r.status_code in (200, 201):
        data = r.json()
        print(f"Created user: {data.get('id')}")
        return email, password
    elif r.status_code == 422:  # User exists
        print("User already exists, trying login...")
        return email, password
    else:
        print(f"Create user error: {r.text}")
        return None, None

def get_session_token(email, password):
    """Get a real Supabase session token via email/password login"""
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
    
    print(f"Login status: {r.status_code}")
    if r.status_code == 200:
        data = r.json()
        return data.get('access_token'), data.get('user', {}).get('id')
    else:
        print(f"Login error: {r.text}")
        return None, None

def test_upload_and_cancel():
    """Test uploading and then cancelling"""
    # Create or get test user
    email, password = create_test_user()
    if not email:
        print("Failed to create test user")
        return
    
    jwt_token, user_id = get_session_token(email, password)
    
    if not jwt_token:
        print("Failed to get JWT token")
        return
    
    print(f"Got JWT token: {jwt_token[:50]}...")
    print(f"User ID: {user_id}")
    
    # First verify the token works
    test_url = f'{WORKER_URL}/api/v1/auth/me'
    r = requests.get(test_url, headers={'Authorization': f'Bearer {jwt_token}'}, timeout=10)
    print(f"Auth test: {r.status_code}")
    if r.status_code != 200:
        print(f"Auth error: {r.text}")
        return
    
    # Upload a file
    upload_url = f'{WORKER_URL}/api/v1/upload/file'
    
    # Use a real PDF file for testing
    pdf_path = r'c:\Users\ameet\Documents\NotesApp\test_upload.pdf'
    
    with open(pdf_path, 'rb') as f:
        pdf_content = f.read()
    
    files = {
        'file': ('test_cancel.pdf', pdf_content, 'application/pdf')
    }
    
    headers = {
        'Authorization': f'Bearer {jwt_token}'
    }
    
    print("\nUploading file...")
    r = requests.post(upload_url, files=files, headers=headers, timeout=30)
    print(f"Upload status: {r.status_code}")
    
    if r.status_code in (200, 202):
        data = r.json()
        trace_id = data.get('trace_id')
        print(f"Upload started! Trace ID: {trace_id}")
        
        # Wait a bit then cancel
        print("Waiting 3 seconds before cancel...")
        time.sleep(3)
        
        # Cancel
        cancel_url = f'{WORKER_URL}/api/v1/upload/cancel/{trace_id}'
        print(f"Cancelling at: {cancel_url}")
        r2 = requests.post(cancel_url, headers=headers, timeout=10)
        print(f"Cancel status: {r2.status_code}")
        print(f"Cancel response: {r2.text}")
        
        # Verify the trace status in database
        print("\nVerifying trace status in database...")
        time.sleep(1)
        r3 = requests.get(
            f'{SB_URL}/rest/v1/upload_traces?trace_id=eq.{trace_id}&select=trace_id,status,error_message',
            headers={
                'apikey': SB_SERVICE_KEY,
                'Authorization': f'Bearer {SB_SERVICE_KEY}'
            },
            timeout=10
        )
        print(f"Database check status: {r3.status_code}")
        if r3.status_code == 200:
            traces = r3.json()
            if traces:
                print(f"Trace from DB: {json.dumps(traces[0], indent=2)}")
            else:
                print("No trace found in database")
        else:
            print(f"DB check error: {r3.text}")
        
    else:
        print(f"Upload error: {r.text}")

if __name__ == '__main__':
    test_upload_and_cancel()
