"""Check worker logs for user_id values."""
from supabase import create_client
import os
from dotenv import load_dotenv

load_dotenv()
url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY')
supabase = create_client(url, key)

# Check recent worker logs
result = supabase.table('worker_logs').select('*').order('timestamp', desc=True).limit(15).execute()

print(f"Worker logs: {len(result.data)}")
print()

null_user = sum(1 for l in result.data if l.get('user_id') is None)
print(f"NULL user_id: {null_user}")
print(f"Valid user_id: {len(result.data) - null_user}")
print()

print("Recent worker logs:")
print("-" * 80)
for log in result.data[:10]:
    endpoint = log.get('endpoint', '?')
    user_id = log.get('user_id') or 'NULL'
    total_ms = log.get('timing_total_ms', 0)
    ts = str(log.get('timestamp', ''))[-12:-1]
    print(f"{ts} | {endpoint:12} | user: {user_id:20} | {total_ms}ms")
