import os
import requests
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()

c = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])

# Check notes with tag=test that have blob_url
print("=== Checking blob URLs for test notes ===")
r = c.table('notes').select('id,title,blob_url').eq('tag', 'test').not_.is_('blob_url', 'null').execute()
print(f'Notes with blob_url: {len(r.data)}')
print()

for n in r.data[:2]:  # Check first 2
    blob_url = n.get('blob_url')
    if blob_url:
        print(f"Note: {n['id'][:8]}")
        print(f"Title: {n['title'][:60]}")
        print(f"Blob URL: {blob_url[:100]}...")
        try:
            # Do a GET request to check
            response = requests.get(blob_url, timeout=10)
            print(f"Status: HTTP {response.status_code}")
            print(f"Response: {response.text[:200]}")
        except Exception as e:
            print(f"ERROR: {e}")
        print()
