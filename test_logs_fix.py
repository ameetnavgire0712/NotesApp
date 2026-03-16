"""Make a test search and check logs have correlation_id."""
import httpx
import time
import os
from supabase import create_client
from dotenv import load_dotenv
from datetime import datetime, timedelta, timezone

load_dotenv()

# Get valid API key from Supabase
url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY')
supabase = create_client(url, key)

# Make a test search using notes/search endpoint
print("Making test search request...")
response = httpx.post(
    'https://notesapp-search.fly.dev/api/v1/notes/search',
    json={'query': 'test correlation fix', 'user_id': 'ameet'},
    timeout=60,
    follow_redirects=True
)
print(f"Search response: {response.status_code}")

# Wait for logs to flush
print("Waiting for logs to flush (8s)...")
time.sleep(8)

# Check recent logs
since = (datetime.now(timezone.utc) - timedelta(minutes=2)).isoformat()
result = supabase.table('application_logs').select('*').gte('timestamp', since).order('timestamp', desc=True).limit(50).execute()

print(f"\nRecent logs: {len(result.data)}")

# Count null vs non-null
null_cid = sum(1 for log in result.data if log.get('correlation_id') is None)
non_null = len(result.data) - null_cid
print(f"NULL correlation_id: {null_cid}")
print(f"Valid correlation_id: {non_null}")

# Show request-related logs (not startup)
print("\nRequest logs (excluding startup):")
print("-" * 100)
for log in result.data[:20]:
    logger = log.get('logger_name', '')
    if 'main_search' not in logger:  # Skip startup logs
        level = log.get('level', '?')
        cid = log.get('correlation_id')
        cid_short = str(cid)[:20] if cid else 'NULL'
        func = log.get('function_name', '?')
        print(f"{level:8} | {cid_short:22} | {logger[-35:]}")
