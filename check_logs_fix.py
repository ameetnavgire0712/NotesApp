"""Check if correlation_id fix is working in application_logs."""
from supabase import create_client
import os
from dotenv import load_dotenv
from datetime import datetime, timedelta, timezone

load_dotenv()

url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY')
supabase = create_client(url, key)

# Query recent logs (last 5 minutes)
since = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
result = supabase.table('application_logs').select('*').gte('timestamp', since).order('timestamp', desc=True).limit(30).execute()

print(f"Recent logs: {len(result.data)}")
print()

if result.data:
    # Count null vs non-null correlation_ids
    null_cid = sum(1 for log in result.data if log.get('correlation_id') is None)
    non_null = len(result.data) - null_cid
    print(f"NULL correlation_id: {null_cid}")
    print(f"Valid correlation_id: {non_null}")
    print()
    
    print("Sample logs:")
    print("-" * 100)
    for log in result.data[:15]:
        level = log.get('level', '?')
        cid = log.get('correlation_id')
        cid_short = str(cid)[:20] if cid else 'NULL'
        logger = log.get('logger_name', '?')[-25:]
        print(f"{level:8} | {cid_short:22} | {logger}")
