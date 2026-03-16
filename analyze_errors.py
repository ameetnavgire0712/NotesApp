"""Analyze the logs from the 100 query test - detailed errors."""
import os
import re
from collections import defaultdict, Counter
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()
supabase = create_client(os.getenv('SUPABASE_URL'), os.getenv('SUPABASE_SERVICE_KEY') or os.getenv('SUPABASE_KEY'))

# Get logs from the last 10 minutes
ten_min_ago = (datetime.now(tz=timezone.utc) - timedelta(minutes=10)).isoformat()

# Get ERROR logs specifically
errors = supabase.table('application_logs').select('*').eq('level', 'ERROR').gte('timestamp', ten_min_ago).order('timestamp', desc=False).limit(100).execute()

print(f"=== ERROR LOGS ({len(errors.data)}) ===")
print()

# Group errors by type
error_types = Counter()
for e in errors.data:
    msg = e.get('message', '')
    # Extract error type
    if 'VECTOR_QUERY_ERROR' in msg:
        error_types['VECTOR_QUERY_ERROR'] += 1
    elif 'Worker search failed' in msg:
        error_types['Worker search failed'] += 1
    elif "'<' not supported" in msg:
        error_types['Type comparison error'] += 1
    elif 'Rerank' in msg:
        error_types['Rerank error'] += 1
    elif 'timeout' in msg.lower():
        error_types['Timeout'] += 1
    else:
        error_types['Other'] += 1

print("Error types:")
for etype, count in error_types.most_common():
    print(f"  {etype}: {count}")

print("\n=== SAMPLE ERRORS ===")
for e in errors.data[:10]:
    ts = e.get('timestamp', '')[:19]
    msg = e.get('message', '')
    print(f"\n[{ts}]")
    print(f"  Logger: {e.get('logger_name', 'N/A')}")
    print(f"  File: {e.get('filename', 'N/A')}:{e.get('line_number', 'N/A')}")
    print(f"  Message: {msg[:500]}")
