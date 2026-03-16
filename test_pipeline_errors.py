"""Test comprehensive pipeline error capture across all intent types."""
import requests
import json
import time

API_URL = 'https://notesapp-vector-search.monocle0712.workers.dev'
API_KEY = 'Infosys0712!'
LOGS_KEY = 'na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU'
USER_ID = '2b70d283-f76c-4ef0-8280-55dae1992e17'

queries = [
    'What is machine learning?',
    'Give me a summary of my collection',
    'What topics do I have notes about?',
    'Show me notes tagged with python',
    'What did I save last week?',
]

req_ids = []
print("=" * 70)
print("RUNNING TEST QUERIES")
print("=" * 70)

for q in queries:
    print(f"\nQuery: {q}")
    try:
        r = requests.post(
            f'{API_URL}/rag-search',
            headers={'Content-Type': 'application/json', 'X-API-Key': API_KEY},
            json={'query': q, 'user_id': USER_ID, 'top_k': 5},
            timeout=30
        )
        data = r.json()
        path = data.get('path_taken', 'unknown')
        req_id = data.get('request_id', 'N/A')
        count = len(data.get('results', []))
        answer = 'Yes' if data.get('answer') else 'No'
        print(f"  path={path}, results={count}, answer={answer}, req_id={req_id}")
        req_ids.append(req_id)
    except Exception as e:
        print(f"  ERROR: {e}")
    time.sleep(1)

# Wait for traces to be written (fire and forget, needs a few seconds)
print("\nWaiting 5s for traces to be written...")
time.sleep(5)

# Now fetch the traces to check error capture
print("\n" + "=" * 70)
print("CHECKING TRACES FOR ERROR CAPTURE")
print("=" * 70)

try:
    r = requests.get(
        f'{API_URL}/api/v1/logs/dashboard/activities',
        headers={'X-API-Key': LOGS_KEY},
        params={'user_id': USER_ID, 'hours': '1', 'limit': '20'},
        timeout=15
    )
    data = r.json()
    activities = data.get('activities', [])
    print(f"\nFetched {len(activities)} recent activities")
    
    errors_found = 0
    partial_errors = 0
    clean = 0
    
    for act in activities[:10]:
        meta = act.get('metadata', {})
        td = act.get('trace_data', {})
        query = meta.get('query', td.get('query', 'N/A'))[:50]
        intent = td.get('intent_classification', meta.get('intent', 'N/A'))
        tool = td.get('tool_invoked', meta.get('tool_invoked', ''))
        error_occurred = td.get('error_occurred', meta.get('error_occurred', False))
        error_type = td.get('error_type', meta.get('error_type', ''))
        error_msg = td.get('error_message', meta.get('error_message', ''))
        status = act.get('status', '')
        
        if error_occurred:
            if error_type in ('UnknownError', 'Error', 'TypeError'):
                errors_found += 1
                icon = "❌ FATAL"
            else:
                partial_errors += 1
                icon = "⚠️  PARTIAL"
        else:
            clean += 1
            icon = "✅ CLEAN"
        
        print(f"\n  {icon}")
        print(f"    Query: {query}")
        print(f"    Intent: {intent}, Tool: {tool}")
        print(f"    Status: {status}")
        if error_occurred:
            print(f"    Error Type: {error_type}")
            print(f"    Error Msg: {error_msg[:300]}")
    
    print(f"\n{'=' * 70}")
    print(f"SUMMARY: {clean} clean, {partial_errors} partial errors, {errors_found} fatal errors")
    print(f"{'=' * 70}")
    
except Exception as e:
    print(f"Failed to fetch traces: {e}")
    import traceback; traceback.print_exc()
