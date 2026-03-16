"""
Comprehensive test of the Agentic RAG Router.
Tests all 6 intent categories and analyzes tool invocation, output quality, and performance.
"""
import requests
import json
import time
import sys

BASE_URL = "https://notesapp-vector-search.monocle0712.workers.dev"
API_KEY = "Infosys0712!"
USER_ID = "2b70d283-f76c-4ef0-8280-55dae1992e17"

test_queries = [
    # --- CONTENT_SEARCH (should use hybrid pipeline) ---
    {"query": "show me my resume", "expected": "CONTENT_SEARCH"},
    {"query": "what is my PAN number", "expected": "CONTENT_SEARCH"},
    {"query": "redis pricing details", "expected": "CONTENT_SEARCH"},
    {"query": "find my aadhaar card", "expected": "CONTENT_SEARCH"},
    
    # --- TAG_BROWSE (must have word "tag") ---
    {"query": "show documents under tag resume", "expected": "TAG_BROWSE"},
    {"query": "list notes with tag personal", "expected": "TAG_BROWSE"},
    {"query": "what is in my finance tag", "expected": "TAG_BROWSE"},
    
    # --- COLLECTION_SUMMARY ---
    {"query": "summarize my notes", "expected": "COLLECTION_SUMMARY"},
    {"query": "how many documents do I have", "expected": "COLLECTION_SUMMARY"},
    {"query": "what topics do I have notes on", "expected": "COLLECTION_SUMMARY"},
    {"query": "give me an overview of my saved items", "expected": "COLLECTION_SUMMARY"},
    
    # --- EXPLORATORY ---
    {"query": "do I have anything about AI?", "expected": "EXPLORATORY"},
    {"query": "is there something about taxes?", "expected": "EXPLORATORY"},
    {"query": "anything related to cooking?", "expected": "EXPLORATORY"},
    
    # --- DATE_QUERY (canned response) ---
    {"query": "what did I save yesterday", "expected": "DATE_QUERY"},
    {"query": "notes from last month", "expected": "DATE_QUERY"},
    {"query": "documents saved in January", "expected": "DATE_QUERY"},
    
    # --- MULTI_STEP (canned response) ---
    {"query": "compare my two resume versions", "expected": "MULTI_STEP"},
    {"query": "merge my tax documents together", "expected": "MULTI_STEP"},
    
    # --- EDGE CASES / AMBIGUOUS ---
    {"query": "show me all my resumes", "expected": "CONTENT_SEARCH"},  # no "tag" keyword
    {"query": "what do I have?", "expected": "COLLECTION_SUMMARY"},
    {"query": "hello", "expected": "CONTENT_SEARCH"},
    {"query": "latest document", "expected": "DATE_QUERY"},
]

INTENT_TO_PATH = {
    "CONTENT_SEARCH": ["hybrid", "tag"],
    "TAG_BROWSE": ["tag_browse"],
    "COLLECTION_SUMMARY": ["collection_summary"],
    "EXPLORATORY": ["exploratory"],
    "DATE_QUERY": ["hybrid"],  # canned, uses hybrid as placeholder path
    "MULTI_STEP": ["hybrid"],  # canned, uses hybrid as placeholder path
}

print("=" * 90)
print("  AGENTIC RAG ROUTER — COMPREHENSIVE TEST SUITE")
print("=" * 90)

results_summary = []
total_start = time.time()

for i, test in enumerate(test_queries, 1):
    query = test["query"]
    expected = test["expected"]
    
    print(f"\n{'━' * 90}")
    print(f"  TEST {i}/{len(test_queries)}: \"{query}\"")
    print(f"  Expected Intent: {expected}")
    print(f"{'━' * 90}")
    
    start = time.time()
    try:
        resp = requests.post(
            f"{BASE_URL}/rag-search",
            headers={"Content-Type": "application/json", "X-API-Key": API_KEY},
            json={"query": query, "user_id": USER_ID},
            timeout=45
        )
        elapsed_ms = int((time.time() - start) * 1000)
        
        if resp.status_code != 200:
            print(f"  ❌ HTTP {resp.status_code}: {resp.text[:300]}")
            results_summary.append({
                "query": query, "expected": expected, "actual_path": "ERROR",
                "match": False, "total_ms": elapsed_ms, "error": True
            })
            time.sleep(1)
            continue
        
        data = resp.json()
        path = data.get("path_taken", "?")
        results_count = len(data.get("results", []))
        answer = data.get("answer", "")
        llm_calls = data.get("metadata", {}).get("llm_calls", [])
        timing = data.get("metadata", {}).get("timing", {})
        tags_info = data.get("metadata", {}).get("tags", {})
        cache_hits = data.get("metadata", {}).get("cache_hits", {})
        
        # Determine intent match
        valid_paths = INTENT_TO_PATH.get(expected, [])
        intent_match = path in valid_paths
        
        # === TOOLS INVOKED ===
        print(f"\n  📋 TOOLS INVOKED:")
        for call in llm_calls:
            purpose = call.get("purpose", "?")
            model = call.get("model", "?")
            dur = call.get("duration_ms", 0)
            icon = "🤖" if "llama" in str(model) else "🔧"
            print(f"     {icon} {purpose:<22} | model: {model:<28} | {dur:>5}ms")
        
        # === ROUTING ===
        print(f"\n  🔀 ROUTING:")
        print(f"     Path taken:    {path}")
        print(f"     Expected:      {expected} → paths {valid_paths}")
        print(f"     Match:         {'✅ CORRECT' if intent_match else '❌ MISMATCH'}")
        
        # === TIMING BREAKDOWN ===
        print(f"\n  ⏱️  TIMING BREAKDOWN:")
        timing_items = [
            ("Intent Router", timing.get("intent_router_ms")),
            ("Tags Fetch", timing.get("tags_fetch_ms")),
            ("Embedding", timing.get("embedding_ms")),
            ("Vector Search", timing.get("vector_search_ms")),
            ("Keyword Search", timing.get("keyword_search_ms")),
            ("Rerank", timing.get("rerank_ms")),
            ("Relevance Check", timing.get("relevance_check_ms")),
            ("Synthesis", timing.get("synthesis_ms")),
            ("Tag Intent", timing.get("tag_intent_ms")),
            ("Analysis", timing.get("analysis_ms")),
        ]
        for label, ms in timing_items:
            if ms and ms > 0:
                bar = "█" * min(int(ms / 20), 40)
                print(f"     {label:<18} {ms:>6}ms  {bar}")
        total_ms = timing.get("total_ms", elapsed_ms)
        print(f"     {'TOTAL':<18} {total_ms:>6}ms  {'━' * min(int(total_ms / 20), 40)}")
        
        # === CACHE ===
        cache_items = [(k, v) for k, v in cache_hits.items() if v]
        if cache_items:
            print(f"\n  💾 CACHE HITS: {', '.join(k for k, v in cache_items)}")
        
        # === RESULTS ===
        print(f"\n  📄 RESULTS: {results_count} documents returned")
        if data.get("results"):
            for j, r in enumerate(data["results"][:5], 1):
                title = r.get("title", "Untitled")[:55]
                tag = r.get("tag", "—")
                has_view = "✅" if r.get("view_url") else "❌"
                has_blob = "✅" if r.get("blob_url") else "—"
                score = r.get("rerank_score") or r.get("similarity_score") or 0
                src = r.get("source", "?")
                print(f"     {j}. \"{title}\"")
                print(f"        tag={tag} | score={score:.3f} | src={src} | view_url={has_view} | blob_url={has_blob}")
            if results_count > 5:
                print(f"     ... and {results_count - 5} more")
        
        # === ANSWER ===
        if answer:
            truncated = answer[:300].replace('\n', ' ')
            if len(answer) > 300:
                truncated += "..."
            print(f"\n  💬 ANSWER ({len(answer)} chars):")
            print(f"     {truncated}")
        else:
            print(f"\n  💬 ANSWER: (none)")
        
        # === TAGS ===
        avail_tags = tags_info.get("available", [])
        if avail_tags:
            print(f"\n  🏷️  TAGS: {len(avail_tags)} available: {', '.join(avail_tags[:10])}")
        
        results_summary.append({
            "query": query,
            "expected": expected,
            "actual_path": path,
            "match": intent_match,
            "total_ms": total_ms,
            "intent_router_ms": timing.get("intent_router_ms", 0),
            "results_count": results_count,
            "has_answer": bool(answer),
            "llm_calls": len(llm_calls),
            "error": False,
        })
        
    except Exception as e:
        elapsed_ms = int((time.time() - start) * 1000)
        print(f"  ❌ Exception: {e}")
        results_summary.append({
            "query": query, "expected": expected, "actual_path": "EXCEPTION",
            "match": False, "total_ms": elapsed_ms, "error": True
        })
    
    # Small delay to avoid Groq rate limits
    time.sleep(0.5)

total_elapsed = int((time.time() - total_start) * 1000)

# =====================================================================
# SUMMARY REPORT
# =====================================================================
print(f"\n\n{'=' * 90}")
print(f"  SUMMARY REPORT")
print(f"{'=' * 90}")

correct = sum(1 for r in results_summary if r["match"])
errors = sum(1 for r in results_summary if r["error"])
total = len(results_summary)

print(f"\n  Intent Classification Accuracy: {correct}/{total} ({100*correct/total:.0f}%)")
print(f"  Errors: {errors}")
print(f"  Total Wall Time: {total_elapsed}ms ({total_elapsed/1000:.1f}s)")

# Group by expected intent
print(f"\n  {'─' * 70}")
print(f"  {'Expected Intent':<22} {'Tests':>5} {'Correct':>8} {'Avg ms':>8} {'Avg Router ms':>14}")
print(f"  {'─' * 70}")

by_intent = {}
for r in results_summary:
    key = r["expected"]
    if key not in by_intent:
        by_intent[key] = {"tests": 0, "correct": 0, "total_ms": 0, "router_ms": 0}
    by_intent[key]["tests"] += 1
    by_intent[key]["correct"] += 1 if r["match"] else 0
    by_intent[key]["total_ms"] += r["total_ms"]
    by_intent[key]["router_ms"] += r.get("intent_router_ms", 0)

for intent, stats in sorted(by_intent.items()):
    avg_ms = stats["total_ms"] // stats["tests"]
    avg_router = stats["router_ms"] // stats["tests"]
    status = "✅" if stats["correct"] == stats["tests"] else "⚠️"
    print(f"  {status} {intent:<20} {stats['tests']:>5} {stats['correct']:>8} {avg_ms:>7}ms {avg_router:>13}ms")

# Mismatches
mismatches = [r for r in results_summary if not r["match"] and not r["error"]]
if mismatches:
    print(f"\n  ⚠️  MISMATCHES:")
    for m in mismatches:
        print(f"     \"{m['query']}\" → got {m['actual_path']}, expected {m['expected']}")

# Performance analysis
all_times = [r["total_ms"] for r in results_summary if not r["error"]]
router_times = [r.get("intent_router_ms", 0) for r in results_summary if not r["error"] and r.get("intent_router_ms")]
if all_times:
    print(f"\n  📊 PERFORMANCE:")
    print(f"     Total request:  min={min(all_times)}ms  avg={sum(all_times)//len(all_times)}ms  max={max(all_times)}ms")
if router_times:
    print(f"     Intent router:  min={min(router_times)}ms  avg={sum(router_times)//len(router_times)}ms  max={max(router_times)}ms")
    print(f"     Router overhead: ~{sum(router_times)//len(router_times)}ms per query (Groq llama-3.1-8b)")

print(f"\n{'=' * 90}")
print(f"  TEST COMPLETE")
print(f"{'=' * 90}\n")
