"""
Detailed end-to-end test with per-query phase breakdown.
Captures timing for each step and analyzes waiting vs processing time.
"""
import asyncio
import httpx
import time
import os
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv
from supabase import create_client
from collections import defaultdict
import json

load_dotenv()

# Configuration
FLY_URL = "https://notesapp-search.fly.dev"
API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_SERVICE_KEY")

# Test queries
QUERIES = [
    "what is my pan card number",
    "aadhaar details",
    "bank account information", 
    "passport expiry date",
    "driving license number",
    "insurance policy details",
    "credit card statement",
    "investment portfolio",
    "tax returns",
    "property documents",
]

async def run_single_query(client: httpx.AsyncClient, query: str, query_id: int, start_time: float):
    """Run a single query and capture detailed timing"""
    queue_start = time.time()
    queue_wait = (queue_start - start_time) * 1000  # Time spent before this query started
    
    try:
        response = await client.post(
            f"{FLY_URL}/api/v1/search",
            json={"query": query, "max_results": 3},
            headers={"X-API-Key": API_KEY, "Content-Type": "application/json"},
            timeout=90.0
        )
        request_end = time.time()
        total_client_ms = (request_end - queue_start) * 1000
        
        if response.status_code == 200:
            data = response.json()
            
            # Extract per-phase timing from agent_steps
            phases = {}
            for step in data.get("agent_steps", []):
                action = step.get("action", "unknown")
                duration = step.get("duration_ms", 0)
                phases[action] = duration
            
            return {
                "query_id": query_id,
                "query": query[:30],
                "status": "success",
                "queue_wait_ms": queue_wait,
                "client_latency_ms": total_client_ms,
                "server_duration_ms": data.get("total_duration_ms", 0),
                "network_overhead_ms": total_client_ms - data.get("total_duration_ms", 0),
                "phases": phases,
                "iterations_used": data.get("metadata", {}).get("iterations_used", 0)
            }
        else:
            return {
                "query_id": query_id,
                "query": query[:30],
                "status": f"error_{response.status_code}",
                "queue_wait_ms": queue_wait,
                "client_latency_ms": total_client_ms,
                "error": response.text[:100]
            }
    except Exception as e:
        return {
            "query_id": query_id,
            "query": query[:30],
            "status": "exception",
            "queue_wait_ms": queue_wait,
            "client_latency_ms": (time.time() - queue_start) * 1000,
            "error": str(e)[:100]
        }

async def run_test(num_queries: int = 20, concurrency: int = 20):
    """Run concurrent test with detailed per-query analysis"""
    print(f"\n{'='*70}")
    print(f"DETAILED END-TO-END TEST - {num_queries} queries, {concurrency} concurrent")
    print(f"{'='*70}")
    print(f"Target: {FLY_URL}")
    
    # Use queries cyclically
    test_queries = [(QUERIES[i % len(QUERIES)], i) for i in range(num_queries)]
    
    test_start = datetime.now(timezone.utc)
    start_time = time.time()
    
    print(f"Test start: {test_start.isoformat()}")
    print(f"\n🚀 Starting {num_queries} concurrent queries...")
    
    async with httpx.AsyncClient() as client:
        tasks = [run_single_query(client, q, i, start_time) for q, i in test_queries]
        results = await asyncio.gather(*tasks)
    
    total_time = time.time() - start_time
    
    # Analyze results
    successful = [r for r in results if r["status"] == "success"]
    failed = [r for r in results if r["status"] != "success"]
    
    print(f"\n{'='*70}")
    print("OVERALL RESULTS")
    print(f"{'='*70}")
    print(f"Total time: {total_time:.2f}s")
    print(f"Successful: {len(successful)}/{num_queries}")
    print(f"Throughput: {len(successful)/total_time:.2f} queries/sec")
    
    if failed:
        print(f"\n❌ Failed queries: {len(failed)}")
        for r in failed[:3]:
            print(f"   Query {r['query_id']}: {r.get('error', 'unknown')}")
    
    if successful:
        # Sort by server duration to find slowest
        sorted_by_server = sorted(successful, key=lambda x: x.get("server_duration_ms", 0), reverse=True)
        
        print(f"\n{'='*70}")
        print("PER-QUERY BREAKDOWN (sorted by server duration, slowest first)")
        print(f"{'='*70}")
        print(f"{'ID':>3} | {'Query':<25} | {'Client':>8} | {'Server':>8} | {'Network':>8} | {'Phases (spell/analyze/search/finalize)'}")
        print("-" * 110)
        
        for r in sorted_by_server[:15]:  # Top 15 slowest
            phases = r.get("phases", {})
            spell = phases.get("spell_check_and_tags", 0)
            analyze = phases.get("analyze_query", 0)
            search = phases.get("call_hybrid_search", 0) or phases.get("call_vector_search", 0) or phases.get("call_chunk_search", 0)
            finalize = phases.get("call_finalize_results", 0)
            
            print(f"{r['query_id']:>3} | {r['query']:<25} | {r['client_latency_ms']:>7.0f}ms | {r['server_duration_ms']:>7.0f}ms | {r['network_overhead_ms']:>7.0f}ms | {spell:>4}/{analyze:>4}/{search:>5}/{finalize:>4}ms")
        
        # Aggregate phase analysis
        print(f"\n{'='*70}")
        print("PHASE TIMING ANALYSIS (across all successful queries)")
        print(f"{'='*70}")
        
        phase_times = defaultdict(list)
        for r in successful:
            for phase, duration in r.get("phases", {}).items():
                phase_times[phase].append(duration)
        
        for phase, times in sorted(phase_times.items(), key=lambda x: sum(x[1])/len(x[1]) if x[1] else 0, reverse=True):
            avg = sum(times) / len(times)
            max_t = max(times)
            min_t = min(times)
            print(f"  {phase:<30}: avg={avg:>6.0f}ms, min={min_t:>5.0f}ms, max={max_t:>6.0f}ms")
        
        # Waiting vs Processing analysis
        print(f"\n{'='*70}")
        print("WAITING vs PROCESSING ANALYSIS")
        print(f"{'='*70}")
        
        client_latencies = [r["client_latency_ms"] for r in successful]
        server_durations = [r["server_duration_ms"] for r in successful]
        network_overheads = [r["network_overhead_ms"] for r in successful]
        
        total_client_time = sum(client_latencies)
        total_server_time = sum(server_durations)
        total_network_overhead = sum(network_overheads)
        
        print(f"  Avg Client Latency (total round-trip): {sum(client_latencies)/len(client_latencies):.0f}ms")
        print(f"  Avg Server Duration (actual processing): {sum(server_durations)/len(server_durations):.0f}ms")
        print(f"  Avg Network Overhead (client - server): {sum(network_overheads)/len(network_overheads):.0f}ms")
        print()
        print(f"  The 'Network Overhead' includes:")
        print(f"    - Network round-trip latency")
        print(f"    - Fly.io proxy/load balancer queuing")
        print(f"    - Request waiting in server queue (if overloaded)")
        
        # Identify if slow queries had high network overhead
        print(f"\n{'='*70}")
        print("SLOWEST 5 QUERIES - BOTTLENECK ANALYSIS")
        print(f"{'='*70}")
        
        for i, r in enumerate(sorted_by_server[:5], 1):
            phases = r.get("phases", {})
            total_phase_time = sum(phases.values())
            
            print(f"\n  #{i} Query {r['query_id']}: \"{r['query']}\"")
            print(f"      Client Latency: {r['client_latency_ms']:.0f}ms")
            print(f"      Server Duration: {r['server_duration_ms']:.0f}ms")
            print(f"      Network Overhead: {r['network_overhead_ms']:.0f}ms")
            print(f"      Phase breakdown:")
            for phase, duration in sorted(phases.items(), key=lambda x: x[1], reverse=True):
                pct = (duration / r['server_duration_ms'] * 100) if r['server_duration_ms'] > 0 else 0
                print(f"        - {phase}: {duration}ms ({pct:.1f}%)")
            
            # Determine bottleneck
            if r['network_overhead_ms'] > r['server_duration_ms'] * 0.5:
                print(f"      ⚠️ BOTTLENECK: High network/queuing overhead ({r['network_overhead_ms']:.0f}ms)")
            else:
                slowest_phase = max(phases.items(), key=lambda x: x[1]) if phases else ("unknown", 0)
                print(f"      ⚠️ BOTTLENECK: {slowest_phase[0]} ({slowest_phase[1]}ms)")
    
    # Wait and query Supabase for Fly.io logs
    print(f"\n⏳ Waiting 3s for logs to propagate...")
    await asyncio.sleep(3)
    
    await analyze_fly_metrics(test_start)
    
    return results

async def analyze_fly_metrics(start_time: datetime):
    """Query application logs for any performance metrics"""
    print(f"\n{'='*70}")
    print("FLY.IO APPLICATION LOGS ANALYSIS")
    print(f"{'='*70}")
    
    supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
    
    # Check for any timing/performance logs
    logs = supabase.table("application_logs").select("*").gte(
        "timestamp", start_time.isoformat()
    ).order("timestamp", desc=False).limit(500).execute()
    
    if logs.data:
        print(f"  Total log entries: {len(logs.data)}")
        
        # Group by level
        by_level = defaultdict(int)
        for log in logs.data:
            by_level[log.get("level", "UNKNOWN")] += 1
        
        print(f"  By level: {dict(by_level)}")
        
        # Look for any slow operation warnings
        slow_logs = [l for l in logs.data if "slow" in str(l.get("message", "")).lower() or "timeout" in str(l.get("message", "")).lower()]
        if slow_logs:
            print(f"\n  ⚠️ Slow/Timeout warnings found: {len(slow_logs)}")
            for log in slow_logs[:5]:
                print(f"    - {log.get('message', '')[:80]}")
    else:
        print("  No application logs found")
    
    # Query worker logs for the same period
    print(f"\n📋 Worker Logs (Cloudflare):")
    worker_logs = supabase.table("worker_logs").select("*").gte(
        "created_at", start_time.isoformat()
    ).execute()
    
    if worker_logs.data:
        by_endpoint = defaultdict(list)
        for log in worker_logs.data:
            by_endpoint[log.get("endpoint", "unknown")].append(log)
        
        for endpoint, logs in by_endpoint.items():
            total_times = [l.get("total_time_ms", 0) for l in logs if l.get("total_time_ms")]
            if total_times:
                print(f"  {endpoint}: {len(logs)} calls, avg={sum(total_times)/len(total_times):.0f}ms, max={max(total_times):.0f}ms")

if __name__ == "__main__":
    # Run with 20 concurrent queries for clearer analysis
    asyncio.run(run_test(num_queries=20, concurrency=20))
