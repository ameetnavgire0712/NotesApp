"""Quick test: tag browse result count and response tone."""
import requests, json

API_URL = 'https://notesapp-vector-search.monocle0712.workers.dev'
API_KEY = 'Infosys0712!'
USER_ID = '2b70d283-f76c-4ef0-8280-55dae1992e17'

# Test 1: Tag browse
print("=" * 70)
print("TEST 1: Tag browse for 'personal docs'")
print("=" * 70)
r = requests.post(f'{API_URL}/rag-search',
    headers={'Content-Type': 'application/json', 'X-API-Key': API_KEY},
    json={'query': 'show me all docs tagged personal docs', 'user_id': USER_ID, 'top_k': 10},
    timeout=30)
d = r.json()
print(f"Path: {d.get('path_taken')}")
print(f"Results: {len(d.get('results', []))}")
print(f"Answer: {d.get('answer', '')}")
for i, doc in enumerate(d.get('results', [])):
    print(f"  {i+1}. {doc['title']} (source={doc.get('source','?')})")
print()

# Test 2: Summarize (check if friendly)
print("=" * 70)
print("TEST 2: Collection summary - check tone")
print("=" * 70)
r = requests.post(f'{API_URL}/rag-search',
    headers={'Content-Type': 'application/json', 'X-API-Key': API_KEY},
    json={'query': 'summarize my documents', 'user_id': USER_ID, 'top_k': 5},
    timeout=30)
d = r.json()
print(f"Path: {d.get('path_taken')}")
print(f"Results: {len(d.get('results', []))}")
print(f"Answer:\n{d.get('answer', '')}")
print()

# Test 3: Content search (check if friendly synthesis)
print("=" * 70)
print("TEST 3: Content search - check tone")
print("=" * 70)
r = requests.post(f'{API_URL}/rag-search',
    headers={'Content-Type': 'application/json', 'X-API-Key': API_KEY},
    json={'query': 'what is in my resume?', 'user_id': USER_ID, 'top_k': 5},
    timeout=30)
d = r.json()
print(f"Path: {d.get('path_taken')}")
print(f"Results: {len(d.get('results', []))}")
print(f"Answer:\n{d.get('answer', '')}")
for i, doc in enumerate(d.get('results', [])):
    print(f"  {i+1}. {doc['title']}")
