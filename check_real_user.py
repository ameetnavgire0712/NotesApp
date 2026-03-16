"""Check the real user's personal docs query and trace data."""
import requests, json

WORKER_URL = "https://notesapp-vector-search.monocle0712.workers.dev"
LOGS_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"
REAL_USER = "2649b4d0-c40d-4ab1-ac04-928fe1cf5969"

r = requests.get(f'{WORKER_URL}/api/v1/logs/dashboard/activities',
    headers={'X-API-Key': LOGS_KEY},
    params={'user_id': REAL_USER, 'hours': '24', 'limit': '15'},
    timeout=15)
data = r.json()
acts = data.get('activities', [])
print(f"Found {len(acts)} activities for real user\n")

for a in acts:
    meta = a.get('metadata', {})
    td = a.get('trace_data', {})
    query = meta.get('query', '')
    intent = td.get('intent_classification', '')
    tool = td.get('tool_invoked', '')
    path = td.get('path_taken', '')
    final_count = td.get('final_count', '?')
    answer_preview = td.get('answer_preview', '')
    error_occurred = td.get('error_occurred', False)
    error_type = td.get('error_type', '')
    error_msg = td.get('error_message', '')
    
    print(f"  Query: \"{query}\"")
    print(f"  Intent: {intent} | Tool: {tool} | Path: {path}")
    print(f"  Results: {final_count}")
    if answer_preview:
        print(f"  Answer: {answer_preview[:150]}...")
    if error_occurred:
        print(f"  ⚠️ Error: [{error_type}] {error_msg[:200]}")
    
    # Check individual results
    results = td.get('final_results', [])
    if results:
        print(f"  Documents returned ({len(results)}):")
        for i, r_item in enumerate(results):
            print(f"    {i+1}. {r_item.get('title', 'Untitled')} (note_id={r_item.get('note_id', '?')[:12]}...)")
    print()
