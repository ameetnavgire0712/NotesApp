"""Test friendly responses and no-docs-for-summary behavior."""
import requests
import json
import time

API_URL = 'https://notesapp-vector-search.monocle0712.workers.dev'
API_KEY = 'Infosys0712!'
USER_ID = '2b70d283-f76c-4ef0-8280-55dae1992e17'

test_cases = [
    ("Summarize my documents", "COLLECTION_SUMMARY - should have answer, NO results"),
    ("What topics do I have notes about?", "COLLECTION_SUMMARY - should have answer, NO results"),
    ("Do I have anything about cooking?", "EXPLORATORY - answer + relevant docs only"),
    ("Show me notes tagged with resume", "TAG_BROWSE - friendly tag response"),
    ("What did I save last week?", "DATE_QUERY - friendly canned response"),
    ("Compare my resumes", "MULTI_STEP - friendly canned response"),
]

print("=" * 80)
print("TESTING FRIENDLY RESPONSES & NO-DOCS-FOR-SUMMARY")
print("=" * 80)

for query, description in test_cases:
    print(f"\n{'─' * 80}")
    print(f"TEST: {description}")
    print(f"QUERY: \"{query}\"")
    print(f"{'─' * 80}")
    
    try:
        r = requests.post(
            f'{API_URL}/rag-search',
            headers={'Content-Type': 'application/json', 'X-API-Key': API_KEY},
            json={'query': query, 'user_id': USER_ID, 'top_k': 5},
            timeout=30
        )
        data = r.json()
        path = data.get('path_taken', 'unknown')
        results_count = len(data.get('results', []))
        answer = data.get('answer', '')
        
        print(f"  Path: {path}")
        print(f"  Results: {results_count} documents")
        print(f"  Answer ({len(answer)} chars):")
        # Show the answer with proper formatting
        for line in answer.split('\n'):
            if line.strip():
                print(f"    {line}")
        
        # Verify no-results for collection_summary
        if path == 'collection_summary' and results_count > 0:
            print(f"  ❌ FAIL: collection_summary should return 0 results, got {results_count}")
        elif path == 'collection_summary' and results_count == 0:
            print(f"  ✅ PASS: collection_summary correctly returns 0 results (answer-only)")
        
    except Exception as e:
        print(f"  ❌ ERROR: {e}")
    
    time.sleep(1.5)

print(f"\n{'=' * 80}")
print("DONE!")
print(f"{'=' * 80}")
