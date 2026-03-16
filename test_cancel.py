"""Test cancel upload functionality"""
import requests
import time
import json
import os
import jwt
import datetime

WORKER_URL = 'https://notesapp-vector-search.monocle0712.workers.dev'
SB_URL = 'https://vnpqsmiuismvwsynpmfu.supabase.co'
SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8'
# The actual JWT secret from Supabase
JWT_SECRET = 'zbPmJm3wN3fUk1LjjuYNsOFOPnXEJPNMY0qqU+FCtqo6lf43xh0FLRO96FYECnJ4wCFTsWAMIAGxApWBjZzL2w=='
HEADERS = {'apikey': SB_KEY, 'Authorization': f'Bearer {SB_KEY}'}

def get_fresh_jwt():
    """Get fresh JWT for a test user"""
    # First, list users
    r = requests.get(f'{SB_URL}/auth/v1/admin/users', headers=HEADERS)
    if r.status_code == 200:
        data = r.json()
        users = data.get('users', [])
        for u in users[:5]:
            print(f"User: {u.get('email')} - {u.get('id')}")
        if users:
            # Generate token for first user
            user_id = users[0]['id']
            email = users[0]['email']
            r2 = requests.post(f'{SB_URL}/auth/v1/admin/generateLink', headers={
                **HEADERS, 
                'Content-Type': 'application/json'
            }, json={
                'type': 'magiclink',
                'email': email
            })
            print(f"Generate link status: {r2.status_code}")
            if r2.status_code == 200:
                link_data = r2.json()
                print(f"Link data: {json.dumps(link_data, indent=2)[:500]}")
                # The hashed_token can be used
                return link_data.get('hashed_token'), user_id
    else:
        print(f"Error: {r.text[:500]}")
    return None, None

def test_with_jwt_creation():
    """Create a JWT manually using PyJWT"""
    # Get a user ID
    r = requests.get(f'{SB_URL}/auth/v1/admin/users', headers=HEADERS)
    if r.status_code == 200:
        users = r.json().get('users', [])
        if users:
            user_id = users[0]['id']
            email = users[0]['email']
            print(f"Testing with user: {email} ({user_id})")
            
            # Create a JWT manually
            now = datetime.datetime.utcnow()
            payload = {
                'aud': 'authenticated',
                'exp': int((now + datetime.timedelta(hours=1)).timestamp()),
                'iat': int(now.timestamp()),
                'iss': 'supabase',
                'sub': user_id,
                'email': email,
                'phone': '',
                'app_metadata': {
                    'provider': 'email',
                    'providers': ['email']
                },
                'user_metadata': {},
                'role': 'authenticated'
            }
            
            import base64
            # Decode the base64 secret
            secret_bytes = base64.b64decode(JWT_SECRET)
            
            token = jwt.encode(payload, secret_bytes, algorithm='HS256')
            print(f"Created JWT token: {token[:50]}...")
            return token, user_id
    
    return None, None

def test_upload_and_cancel():
    """Test uploading and then cancelling"""
    # Get a fresh token
    jwt_token, user_id = test_with_jwt_creation()
    
    if not jwt_token:
        print("\nFailed to get JWT token. Let's try another approach.")
        return
    
    print(f"\nGot JWT token: {jwt_token[:50]}...")
    
    # Now upload a file
    upload_url = f'{WORKER_URL}/api/v1/upload/file'
    
    # Create test file
    test_content = b'%PDF-1.4\n%test pdf content for cancel test\n' + b'x' * 1000
    
    files = {
        'file': ('test_cancel.pdf', test_content, 'application/pdf')
    }
    
    headers = {
        'Authorization': f'Bearer {jwt_token}'
    }
    
    print("Uploading file...")
    r = requests.post(upload_url, files=files, headers=headers)
    print(f"Upload status: {r.status_code}")
    
    if r.status_code == 200:
        data = r.json()
        trace_id = data.get('trace_id')
        print(f"Upload started! Trace ID: {trace_id}")
        
        # Wait 2 seconds then cancel
        print("Waiting 2 seconds...")
        time.sleep(2)
        
        # Cancel
        cancel_url = f'{WORKER_URL}/api/v1/upload/cancel/{trace_id}'
        r2 = requests.post(cancel_url, headers=headers)
        print(f"Cancel status: {r2.status_code}")
        print(f"Cancel response: {r2.text}")
        
        # Check status
        time.sleep(1)
        r3 = requests.get(f'{SB_URL}/rest/v1/upload_traces?trace_id=eq.{trace_id}&select=*', headers=HEADERS)
        print(f"\nFinal trace status: {json.dumps(r3.json()[0] if r3.json() else {}, indent=2)[:500]}")
    else:
        print(f"Upload error: {r.text}")

if __name__ == '__main__':
    # First just list users
    r = requests.get(f'{SB_URL}/auth/v1/admin/users', headers=HEADERS)
    print(f"Users status: {r.status_code}")
    if r.status_code == 200:
        users = r.json().get('users', [])
        print(f"Found {len(users)} users")
        for u in users[:3]:
            print(f"  - {u.get('email')} ({u.get('id')})")
        
        # Now try to get a token
        test_upload_and_cancel()
    else:
        print(f"Error: {r.text}")
