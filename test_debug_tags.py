import requests, json

# Check user's tags
r = requests.post(
    'https://notesapp-vector-search.monocle0712.workers.dev/rag-search',
    headers={'Content-Type': 'application/json', 'X-API-Key': 'Infosys0712!'},
    json={'query': 'show documents under tag resume', 'user_id': '2b70d283-f76c-4ef0-8280-55dae1992e17'},
    timeout=30
)
d = r.json()
tags = d.get('metadata', {}).get('tags', {})
print('Available tags:', tags.get('available', []))
print('Detected tags:', tags.get('detected', []))
print('Path:', d.get('path_taken'))

# Also check raw response
for call in d.get('metadata', {}).get('llm_calls', []):
    print(f"LLM call: {call['purpose']} = {call['duration_ms']}ms (model: {call.get('model', '?')})")
