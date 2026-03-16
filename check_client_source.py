"""
Check if client_source column exists and has data in search_traces
"""
import os
from supabase import create_client

SUPABASE_URL = os.environ.get('SUPABASE_URL', 'https://brtnegebfbxijmfxmubt.supabase.co')
SUPABASE_KEY = os.environ.get('SUPABASE_SERVICE_KEY')

if not SUPABASE_KEY:
    print("Error: SUPABASE_SERVICE_KEY not set")
    exit(1)

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)

# Check recent search_traces with client_source
print("=== Recent search_traces with client_source ===")
result = supabase.table('search_traces').select('correlation_id, user_id, query, client_source, created_at').order('created_at', desc=True).limit(10).execute()

for row in result.data:
    print(f"  {row['created_at'][:19]} | {row['client_source'] or 'NULL'} | {row['query'][:40] if row['query'] else 'N/A'}...")

# Count by client_source
print("\n=== Counts by client_source ===")
all_result = supabase.table('search_traces').select('client_source').execute()
counts = {}
for row in all_result.data:
    src = row['client_source'] or 'NULL'
    counts[src] = counts.get(src, 0) + 1

for src, count in sorted(counts.items(), key=lambda x: -x[1]):
    print(f"  {src}: {count}")
