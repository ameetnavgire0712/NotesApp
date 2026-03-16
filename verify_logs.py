"""Verify all request logs have correlation_id."""
from supabase import create_client
import os
from dotenv import load_dotenv
from datetime import datetime, timedelta, timezone

load_dotenv()
url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY')
supabase = create_client(url, key)

# Check last 10 minutes
since = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
result = supabase.table('application_logs').select('correlation_id, level, logger_name').gte('timestamp', since).order('timestamp', desc=True).limit(100).execute()

print(f'Total logs (10 min): {len(result.data)}')

# Separate startup logs from request logs
startup = [l for l in result.data if 'main_search' in l.get('logger_name', '') or 'embeddings' in l.get('logger_name', '').lower()]
request = [l for l in result.data if l not in startup]

startup_null = sum(1 for l in startup if l.get('correlation_id') is None)
request_null = sum(1 for l in request if l.get('correlation_id') is None)

print(f'\nStartup logs: {len(startup)} ({startup_null} null cid) - expected NULL')
print(f'Request logs: {len(request)} ({request_null} null cid)')

if request_null > 0:
    print('\nRequest logs with NULL correlation_id:')
    for l in request:
        if l.get('correlation_id') is None:
            level = l.get("level")
            logger = l.get("logger_name")
            print(f'  {level}: {logger}')
else:
    print('\n*** SUCCESS: All request logs have correlation_id! ***')
