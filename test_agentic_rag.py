"""Test the agentic RAG router with different query types."""
import requests
import json
import time

BASE_URL = "https://notesapp-vector-search.monocle0712.workers.dev"
API_KEY = "Infosys0712!"
USER_ID = "2b70d283-f76c-4ef0-8280-55dae1992e17"

test_queries = [
    # COLLECTION_SUMMARY
    ("summarize my notes", "COLLECTION_SUMMARY"),
    ("how many documents do I have", "COLLECTION_SUMMARY"),
    
    # EXPLORATORY
    ("do I have anything about AI?", "EXPLORATORY"),
    ("is there something about taxes?", "EXPLORATORY"),
    
    # DATE_QUERY (should get canned response)
    ("what did I save yesterday", "DATE_QUERY"),
    
    # MULTI_STEP (should get canned response)  
    ("compare my two resume versions", "MULTI_STEP"),
    
    # TAG_BROWSE (explicit "tag" keyword)
    ("show documents under tag resume", "TAG_BROWSE"),
    
    # CONTENT_SEARCH (default - hybrid search)
    ("show me my resume", "CONTENT_SEARCH"),
    ("what is my PAN number", "CONTENT_SEARCH"),
    ("redis pricing details", "CONTENT_SEARCH"),
]

print("=" * 80)
print("AGENTIC RAG ROUTER TEST")
print("=" * 80)

for query, expected_intent in test_queries:
    print(f"\n{'─' * 60}")
    print(f"Query: \"{query}\"")
    print(f"Expected Intent: {expected_intent}")
    
    start = time.time()
    try:
        resp = requests.post(
            f"{BASE_URL}/rag-search",
            headers={"Content-Type": "application/json", "X-API-Key": API_KEY},
            json={"query": query, "user_id": USER_ID},
            timeout=30
        )
        elapsed = int((time.time() - start) * 1000)
        
        if resp.status_code != 200:
            print(f"  ❌ HTTP {resp.status_code}: {resp.text[:200]}")
            continue
            
        data = resp.json()
        path = data.get("path_taken", "?")
        results_count = len(data.get("results", []))
        answer = data.get("answer", "")
        llm_calls = data.get("metadata", {}).get("llm_calls", [])
        timing = data.get("metadata", {}).get("timing", {})
        
        # Find the intent_router call to see what intent was classified
        router_call = next((c for c in llm_calls if c["purpose"] == "intent_router"), None)
        
        print(f"  Path: {path}")
        print(f"  Results: {results_count}")
        print(f"  Answer: {answer[:200]}..." if answer and len(answer) > 200 else f"  Answer: {answer}")
        print(f"  LLM calls: {', '.join(f'{c['purpose']}({c['duration_ms']}ms)' for c in llm_calls)}")
        print(f"  Total: {timing.get('total_ms', '?')}ms | Intent router: {router_call['duration_ms'] if router_call else '?'}ms")
        
        # Check if results have view_url and blob_url
        if results_count > 0:
            first = data["results"][0]
            has_view_url = bool(first.get("view_url"))
            has_blob_url = bool(first.get("blob_url"))
            print(f"  First result: \"{first['title']}\" | view_url: {'✅' if has_view_url else '❌'} | blob_url: {'✅' if has_blob_url else '❌'}")
        
        # Check match
        intent_match = "✅" if path in [expected_intent.lower(), 
            {"CONTENT_SEARCH": "hybrid", "TAG_BROWSE": "tag_browse", 
             "COLLECTION_SUMMARY": "collection_summary", "EXPLORATORY": "exploratory",
             "DATE_QUERY": "hybrid", "MULTI_STEP": "hybrid"}.get(expected_intent, "")] else "⚠️"
        print(f"  Intent Match: {intent_match}")
        
    except Exception as e:
        print(f"  ❌ Error: {e}")

print(f"\n{'=' * 80}")
print("TEST COMPLETE")
