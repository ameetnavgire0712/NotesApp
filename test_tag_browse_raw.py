import requests, json

resp = requests.post(
    'https://notesapp-vector-search.monocle0712.workers.dev/rag-search',
    headers={'Content-Type': 'application/json', 'X-API-Key': 'Infosys0712!'},
    json={'query': 'tag personal docs', 'user_id': '2649b4d0-c40d-4ab1-ac04-928fe1cf5969'}
)
data = resp.json()
print("Results count:", len(data.get('results', [])))
print("Path taken:", data.get('path_taken'))
print("Answer:", data.get('answer', '')[:200])
print()
results = data.get('results', [])
for i, r in enumerate(results):
    print(f"  {i+1}. note_id={r.get('note_id', '')[:15]}")
    print(f"     title={r.get('title', '')[:80]}")
    print(f"     tag={r.get('tag', '')}")
    print(f"     view_url={'YES' if r.get('view_url') else 'MISSING'}")
    print()

# Also dump full results array keys
if results:
    print("Keys in first result:", list(results[0].keys()))
