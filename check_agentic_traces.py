"""
Query Supabase search_traces table for the new agentic RAG columns.
Shows intent classification, tool invoked, timing, errors, and LLM calls.
"""
import requests
import json

SUPABASE_URL = "https://fvacgkxvpsxesxyeddls.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ2YWNna3h2cHN4ZXN4eWVkZGxzIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTczNjYyNjgxMiwiZXhwIjoyMDUyMjAyODEyfQ.JjJJfJbjgvCEuDefEVrODJX1E1NfALsLaBuXZcaPlz0"

# Get traces — query last 30 to cover our test run
# Use descending order and take last 30, then reverse

print("=" * 100)
print("  SUPABASE SEARCH_TRACES — AGENTIC RAG COLUMNS ANALYSIS")
print("=" * 100)

# Query search_traces with the new columns
url = f"{SUPABASE_URL}/rest/v1/search_traces"
params = {
    "select": "correlation_id,query,intent_classification,intent_confidence,intent_reasoning,timing_intent_router_ms,tool_invoked,path_taken,timing_total_ms,error_occurred,error_message,error_type,llm_calls,answer_generated,answer_preview,collection_doc_count,final_count,created_at",
    "order": "created_at.desc",
    "limit": "30"
}
headers = {
    "apikey": SUPABASE_KEY,
    "Authorization": f"Bearer {SUPABASE_KEY}",
    "Content-Type": "application/json"
}

response = requests.get(url, params=params, headers=headers)

if response.status_code != 200:
    print(f"  ❌ Supabase error: {response.status_code} — {response.text[:500]}")
    exit(1)

traces = response.json()
# Reverse to chronological order (we queried desc)
traces = list(reversed(traces))
print(f"\n  Found {len(traces)} traces (most recent 30)\n")

if not traces:
    print("  No traces found. The worker may not have logged yet (waitUntil is async).")
    exit(0)

# === TABLE 1: Query → Intent → Tool → Timing ===
print(f"{'─' * 100}")
print(f"  {'#':<3} {'Query':<35} {'Intent':<20} {'Conf':<6} {'Tool':<22} {'Router':<8} {'Total':<8} {'Err'}")
print(f"{'─' * 100}")

errors = []
intent_counts = {}
tool_counts = {}
router_times = []
total_times = []
suspiciously_fast = []

for i, t in enumerate(traces, 1):
    query = (t.get("query") or "")[:33]
    intent = t.get("intent_classification") or "—"
    confidence = t.get("intent_confidence") or "—"
    tool = t.get("tool_invoked") or "—"
    router_ms = t.get("timing_intent_router_ms") or 0
    total_ms = t.get("timing_total_ms") or 0
    err = "❌" if t.get("error_occurred") else "✅"
    
    # Track stats
    intent_counts[intent] = intent_counts.get(intent, 0) + 1
    tool_counts[tool] = tool_counts.get(tool, 0) + 1
    if router_ms > 0:
        router_times.append(router_ms)
    total_times.append(total_ms)
    
    if t.get("error_occurred"):
        errors.append(t)
    
    if router_ms > 0 and router_ms < 50:
        suspiciously_fast.append(t)
    
    print(f"  {i:<3} {query:<35} {intent:<20} {confidence:<6} {tool:<22} {router_ms:>5}ms {total_ms:>6}ms {err}")

# === TABLE 2: Intent Distribution ===
print(f"\n{'=' * 60}")
print(f"  INTENT DISTRIBUTION (from Supabase)")
print(f"{'=' * 60}")
for intent, count in sorted(intent_counts.items(), key=lambda x: -x[1]):
    bar = "█" * count
    print(f"  {intent:<22} {count:>3}  {bar}")

# === TABLE 3: Tool Distribution ===
print(f"\n{'=' * 60}")
print(f"  TOOL DISTRIBUTION (from Supabase)")
print(f"{'=' * 60}")
for tool, count in sorted(tool_counts.items(), key=lambda x: -x[1]):
    bar = "█" * count
    print(f"  {tool:<22} {count:>3}  {bar}")

# === TABLE 4: LLM Calls Detail ===
print(f"\n{'=' * 60}")
print(f"  LLM CALLS BREAKDOWN (from Supabase)")
print(f"{'=' * 60}")
llm_purpose_stats = {}
for t in traces:
    llm_calls = t.get("llm_calls") or []
    for call in llm_calls:
        purpose = call.get("purpose", "unknown")
        dur = call.get("duration_ms", 0)
        if purpose not in llm_purpose_stats:
            llm_purpose_stats[purpose] = {"count": 0, "total_ms": 0, "min_ms": 99999, "max_ms": 0}
        llm_purpose_stats[purpose]["count"] += 1
        llm_purpose_stats[purpose]["total_ms"] += dur
        llm_purpose_stats[purpose]["min_ms"] = min(llm_purpose_stats[purpose]["min_ms"], dur)
        llm_purpose_stats[purpose]["max_ms"] = max(llm_purpose_stats[purpose]["max_ms"], dur)

print(f"  {'Purpose':<22} {'Count':>5} {'Avg ms':>8} {'Min ms':>8} {'Max ms':>8}")
print(f"  {'─' * 60}")
for purpose, stats in sorted(llm_purpose_stats.items()):
    avg = stats["total_ms"] // stats["count"] if stats["count"] > 0 else 0
    print(f"  {purpose:<22} {stats['count']:>5} {avg:>7}ms {stats['min_ms']:>7}ms {stats['max_ms']:>7}ms")

# === ERRORS ===
if errors:
    print(f"\n{'=' * 60}")
    print(f"  ❌ ERRORS ({len(errors)} total)")
    print(f"{'=' * 60}")
    for e in errors:
        print(f"  Query: \"{e.get('query', '?')[:60]}\"")
        print(f"  Error Type: {e.get('error_type', '?')}")
        print(f"  Error Message: {e.get('error_message', '?')[:200]}")
        print(f"  Time: {e.get('timing_total_ms', 0)}ms")
        print()
else:
    print(f"\n  ✅ No errors found in traces")

# === SUSPICIOUSLY FAST INTENT ROUTER ===
if suspiciously_fast:
    print(f"\n{'=' * 60}")
    print(f"  ⚠️  SUSPICIOUSLY FAST INTENT ROUTER (<50ms) — Possible Groq errors")
    print(f"{'=' * 60}")
    for s in suspiciously_fast:
        print(f"  Query: \"{s.get('query', '?')[:50]}\"")
        print(f"  Router: {s.get('timing_intent_router_ms')}ms → Intent: {s.get('intent_classification')} → Tool: {s.get('tool_invoked')}")
        print(f"  Reasoning: {s.get('intent_reasoning', '?')[:100]}")
        print()

# === ANSWER PREVIEW ===
print(f"\n{'=' * 60}")
print(f"  ANSWERS GENERATED")
print(f"{'=' * 60}")
answers = [t for t in traces if t.get("answer_generated")]
no_answers = [t for t in traces if not t.get("answer_generated")]
print(f"  With answer:    {len(answers)}")
print(f"  Without answer: {len(no_answers)}")
if answers:
    print(f"\n  Sample answers:")
    for a in answers[:5]:
        preview = (a.get("answer_preview") or "")[:120]
        print(f"    [{a.get('tool_invoked','?'):<20}] \"{a.get('query','?')[:30]}\" → {preview}...")

# === PERFORMANCE SUMMARY ===
print(f"\n{'=' * 60}")
print(f"  PERFORMANCE SUMMARY")
print(f"{'=' * 60}")
if total_times:
    print(f"  Total request:  min={min(total_times)}ms  avg={sum(total_times)//len(total_times)}ms  max={max(total_times)}ms")
if router_times:
    print(f"  Intent router:  min={min(router_times)}ms  avg={sum(router_times)//len(router_times)}ms  max={max(router_times)}ms")

# === Also check user_activities for the new metadata ===
print(f"\n{'=' * 80}")
print(f"  USER_ACTIVITIES — NEW METADATA CHECK")
print(f"{'=' * 80}")

url2 = f"{SUPABASE_URL}/rest/v1/user_activities"
params2 = {
    "select": "action,status,duration_ms,metadata,created_at",
    "action": "eq.chat_search",
    "order": "created_at.desc",
    "limit": "30"
}
response2 = requests.get(url2, params=params2, headers=headers)
if response2.status_code == 200:
    activities = response2.json()
    print(f"\n  Found {len(activities)} chat_search activities in the last 15 minutes\n")
    
    has_intent = 0
    has_tool = 0
    has_error = 0
    
    for a in activities:
        meta = a.get("metadata") or {}
        if meta.get("intent"):
            has_intent += 1
        if meta.get("tool_invoked"):
            has_tool += 1
        if meta.get("error_occurred"):
            has_error += 1
    
    print(f"  With intent metadata:      {has_intent}/{len(activities)}")
    print(f"  With tool_invoked metadata: {has_tool}/{len(activities)}")
    print(f"  With error metadata:        {has_error}/{len(activities)}")
    
    if activities:
        sample = activities[0].get("metadata", {})
        print(f"\n  Sample metadata keys: {list(sample.keys())}")
else:
    print(f"  ❌ Failed to query user_activities: {response2.status_code}")

print(f"\n{'=' * 100}")
print(f"  ANALYSIS COMPLETE")
print(f"{'=' * 100}\n")
