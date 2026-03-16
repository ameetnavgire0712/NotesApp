import requests, json, time

r = requests.post(
    'https://notesapp-vector-search.monocle0712.workers.dev/rag-search',
    headers={'Content-Type': 'application/json', 'X-API-Key': 'Infosys0712!'},
    json={'query': 'show documents under tag resume', 'user_id': '2b70d283-f76c-4ef0-8280-55dae1992e17'},
    timeout=30
)
d = r.json()
print('path:', d.get('path_taken'))
print('results:', len(d.get('results', [])))
print('answer:', (d.get('answer') or '(none)')[:300])
print('llm:', [(c['purpose'], c['duration_ms']) for c in d.get('metadata', {}).get('llm_calls', [])])
