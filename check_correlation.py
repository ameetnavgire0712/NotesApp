import os
from dotenv import load_dotenv
from supabase import create_client

# Load from .env file
load_dotenv()

url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY')  # Use SERVICE_KEY not KEY

if not key:
    # Try reading directly
    with open('.env', 'r') as f:
        for line in f:
            if line.startswith('SUPABASE_KEY='):
                key = line.split('=', 1)[1].strip()
            if line.startswith('SUPABASE_URL='):
                url = line.split('=', 1)[1].strip()

client = create_client(url, key)

cid = '4dd2d61a-64e5-4e23-8728-d4c94901fbb4'

# Test if v_operation_details view exists and works
print('=== TESTING v_operation_details VIEW (exact Grafana query) ===')
try:
    result = client.table('v_operation_details').select('timestamp, log_type, log_level, component, operation, duration_ms, message, metadata').eq('correlation_id', cid).order('timestamp').execute()
    print(f'Found {len(result.data)} rows from v_operation_details')
    for r in result.data:
        print(f"{r.get('timestamp')} | {r.get('log_level')} | {r.get('component')} | {r.get('operation')} | {r.get('duration_ms')}ms | {r.get('message')}")
        print(f"  Metadata: {r.get('metadata')}")
except Exception as e:
    print(f'Error querying v_operation_details: {e}')
    print('View may not exist. Need to run grafana_search_deepdive.sql in Supabase')

print()
print('=== TESTING v_search_query_full VIEW (exact Grafana query) ===')
try:
    result = client.table('v_search_query_full').select('correlation_id, user_id, query_text, client_source, status, duration_ms, results_count, is_fast_path, reranker_used, spell_corrected, search_type, query_type, detected_tags, total_candidates, created_at').eq('correlation_id', cid).execute()
    print(f'Found {len(result.data)} rows from v_search_query_full')
    for r in result.data:
        print(f"Query: {r.get('query_text')}")
        print(f"User: {r.get('user_id')}")
        print(f"Client Source: {r.get('client_source')}")
        print(f"Status: {r.get('status')}")
        print(f"Duration: {r.get('duration_ms')}ms")
        print(f"Results: {r.get('results_count')}")
        print(f"Fast Path: {r.get('is_fast_path')}")
        print(f"Reranker: {r.get('reranker_used')}")
        print(f"Spell Corrected: {r.get('spell_corrected')}")
        print(f"Search Type: {r.get('search_type')}")
        print(f"Created: {r.get('created_at')}")
except Exception as e:
    print(f'Error querying v_search_query_full: {e}')
