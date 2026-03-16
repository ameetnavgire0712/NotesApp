"""
Query agentic RAG traces via the Worker API (since Supabase DNS is blocked from this network).
Analyzes intent classification, tool routing, timing, errors, and LLM calls.
"""
import requests
import json

WORKER_URL = "https://notesapp-vector-search.monocle0712.workers.dev"
LOGS_API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"
USER_ID = "2b70d283-f76c-4ef0-8280-55dae1992e17"

print("=" * 100)
print("  SUPABASE SEARCH_TRACES — AGENTIC RAG COLUMNS ANALYSIS (via Worker API)")
print("=" * 100)

# Fetch activities via Worker endpoint
url = f"{WORKER_URL}/api/v1/logs/dashboard/activities"
params = {
    "user_id": USER_ID,
    "hours": "1",
    "limit": "30"
}
headers = {
    "X-API-Key": LOGS_API_KEY,
    "Content-Type": "application/json"
}

response = requests.get(url, params=params, headers=headers)

if response.status_code != 200:
    print(f"  ❌ Worker API error: {response.status_code} — {response.text[:500]}")
    exit(1)

data = response.json()
activities = data.get("activities", [])

# Reverse to chronological order (API returns desc)
activities = list(reversed(activities))

print(f"\n  Found {len(activities)} activities in the last hour\n")

if not activities:
    print("  No traces found. The worker waitUntil traces may not have been written yet.")
    exit(0)

# Each activity has trace_data which contains the full search_traces row
traces = []
for a in activities:
    td = a.get("trace_data", {})
    if td:
        traces.append(td)
    else:
        traces.append({
            "query": a.get("metadata", {}).get("query", "?"),
            "timing_total_ms": a.get("duration_ms", 0),
            "correlation_id": a.get("correlation_id", ""),
        })

# === TABLE 1: Query → Intent → Tool → Timing ===
print(f"{'─' * 110}")
print(f"  {'#':<3} {'Query':<35} {'Intent':<20} {'Conf':<6} {'Tool':<22} {'Router':<8} {'Total':<8} {'Err'}")
print(f"{'─' * 110}")

errors = []
intent_counts = {}
tool_counts = {}
router_times = []
total_times = []
suspiciously_fast = []
null_intent_count = 0

for i, t in enumerate(traces, 1):
    query = (t.get("query") or "")[:33]
    intent = t.get("intent_classification") or "—"
    confidence = t.get("intent_confidence") or "—"
    tool = t.get("tool_invoked") or "—"
    router_ms = t.get("timing_intent_router_ms") or 0
    total_ms = t.get("timing_total_ms") or 0
    err = "❌" if t.get("error_occurred") else "✅"
    
    if intent == "—":
        null_intent_count += 1
    
    intent_counts[intent] = intent_counts.get(intent, 0) + 1
    tool_counts[tool] = tool_counts.get(tool, 0) + 1
    if router_ms and router_ms > 0:
        router_times.append(router_ms)
    if total_ms:
        total_times.append(total_ms)
    
    if t.get("error_occurred"):
        errors.append(t)
    
    if router_ms and router_ms > 0 and router_ms < 50:
        suspiciously_fast.append(t)
    
    print(f"  {i:<3} {query:<35} {intent:<20} {str(confidence):<6} {tool:<22} {router_ms:>5}ms {total_ms:>6}ms {err}")

# === COLUMN POPULATION CHECK ===
print(f"\n{'=' * 60}")
print(f"  NEW COLUMN POPULATION CHECK")
print(f"{'=' * 60}")
populated = {
    "intent_classification": sum(1 for t in traces if t.get("intent_classification")),
    "intent_confidence": sum(1 for t in traces if t.get("intent_confidence")),
    "intent_reasoning": sum(1 for t in traces if t.get("intent_reasoning")),
    "timing_intent_router_ms": sum(1 for t in traces if t.get("timing_intent_router_ms")),
    "tool_invoked": sum(1 for t in traces if t.get("tool_invoked")),
    "path_taken": sum(1 for t in traces if t.get("path_taken")),
    "error_occurred": sum(1 for t in traces if t.get("error_occurred") is not None),
    "llm_calls": sum(1 for t in traces if t.get("llm_calls") and len(t.get("llm_calls", [])) > 0),
    "answer_generated": sum(1 for t in traces if t.get("answer_generated") is not None),
    "answer_preview": sum(1 for t in traces if t.get("answer_preview")),
    "collection_doc_count": sum(1 for t in traces if t.get("collection_doc_count") is not None),
}
total = len(traces)
for col, count in populated.items():
    status = "✅" if count == total else ("⚠️" if count > 0 else "❌")
    print(f"  {status} {col:<28} {count:>3}/{total}")

# === Intent Distribution ===
print(f"\n{'=' * 60}")
print(f"  INTENT DISTRIBUTION")
print(f"{'=' * 60}")
for intent, count in sorted(intent_counts.items(), key=lambda x: -x[1]):
    bar = "█" * count
    print(f"  {intent:<22} {count:>3}  {bar}")

# === Tool Distribution ===
print(f"\n{'=' * 60}")
print(f"  TOOL DISTRIBUTION")
print(f"{'=' * 60}")
for tool, count in sorted(tool_counts.items(), key=lambda x: -x[1]):
    bar = "█" * count
    print(f"  {tool:<22} {count:>3}  {bar}")

# === LLM Calls Detail ===
print(f"\n{'=' * 60}")
print(f"  LLM CALLS BREAKDOWN")
print(f"{'=' * 60}")
llm_purpose_stats = {}
total_llm_calls = 0
for t in traces:
    llm_calls = t.get("llm_calls") or []
    total_llm_calls += len(llm_calls)
    for call in llm_calls:
        if isinstance(call, dict):
            purpose = call.get("purpose", "unknown")
            dur = call.get("duration_ms", 0)
            model = call.get("model", "?")
            if purpose not in llm_purpose_stats:
                llm_purpose_stats[purpose] = {"count": 0, "total_ms": 0, "min_ms": 99999, "max_ms": 0, "model": model}
            llm_purpose_stats[purpose]["count"] += 1
            llm_purpose_stats[purpose]["total_ms"] += dur
            llm_purpose_stats[purpose]["min_ms"] = min(llm_purpose_stats[purpose]["min_ms"], dur)
            llm_purpose_stats[purpose]["max_ms"] = max(llm_purpose_stats[purpose]["max_ms"], dur)

print(f"  Total LLM calls across all traces: {total_llm_calls}")
if llm_purpose_stats:
    print(f"\n  {'Purpose':<25} {'Model':<25} {'Count':>5} {'Avg':>7} {'Min':>7} {'Max':>7}")
    print(f"  {'─' * 85}")
    for purpose, stats in sorted(llm_purpose_stats.items()):
        avg = stats["total_ms"] // stats["count"] if stats["count"] > 0 else 0
        print(f"  {purpose:<25} {stats['model']:<25} {stats['count']:>5} {avg:>5}ms {stats['min_ms']:>5}ms {stats['max_ms']:>5}ms")
else:
    print("  No LLM call data found in traces")

# === Intent Reasoning Samples ===
print(f"\n{'=' * 60}")
print(f"  INTENT REASONING SAMPLES")
print(f"{'=' * 60}")
for t in traces[:8]:
    reasoning = t.get("intent_reasoning") or "—"
    intent = t.get("intent_classification") or "—"
    query = (t.get("query") or "")[:40]
    print(f"  Q: \"{query}\"")
    print(f"  → {intent} | Reasoning: {reasoning[:120]}")
    print()

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
    print(f"  ⚠️  SUSPICIOUSLY FAST INTENT ROUTER (<50ms) — Possible Groq fallback")
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
        print(f"    [{a.get('tool_invoked','?'):<20}] \"{a.get('query','?')[:30]}\" → {preview}")

# === PATH TAKEN ===
print(f"\n{'=' * 60}")
print(f"  PATH DISTRIBUTION")
print(f"{'=' * 60}")
path_counts = {}
for t in traces:
    p = t.get("path_taken") or "—"
    path_counts[p] = path_counts.get(p, 0) + 1
for p, count in sorted(path_counts.items(), key=lambda x: -x[1]):
    bar = "█" * count
    print(f"  {p:<35} {count:>3}  {bar}")

# === PERFORMANCE SUMMARY ===
print(f"\n{'=' * 60}")
print(f"  PERFORMANCE SUMMARY")
print(f"{'=' * 60}")
if total_times:
    print(f"  Total request:  min={min(total_times)}ms  avg={sum(total_times)//len(total_times)}ms  max={max(total_times)}ms")
if router_times:
    print(f"  Intent router:  min={min(router_times)}ms  avg={sum(router_times)//len(router_times)}ms  max={max(router_times)}ms")
    fast = len([r for r in router_times if r < 50])
    normal = len([r for r in router_times if r >= 50])
    print(f"  Router <50ms (Groq failures):  {fast}")
    print(f"  Router >=50ms (successful):    {normal}")

print(f"\n{'=' * 100}")
print(f"  ANALYSIS COMPLETE")
print(f"{'=' * 100}\n")
