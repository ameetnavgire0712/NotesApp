"""
Run 50 concurrent queries and analyze logs from Supabase to identify bottlenecks.
"""
import asyncio
import httpx
import time
import os
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv
from supabase import create_client
from collections import defaultdict

load_dotenv()

# Configuration
WORKER_URL = "https://notesapp-vector-search.monocle0712.workers.dev"
WORKER_API_KEY = os.getenv("VECTORIZE_WORKER_API_KEY")
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
    "vehicle registration",
    "medical records",
    "education certificates",
    "employment history",
    "salary slips",
    "loan details",
    "electricity bill",
    "phone number contacts",
    "travel itinerary",
    "subscription services",
    "warranty information",
    "home address",
    "emergency contacts",
    "family member details",
    "pet information",
    "gym membership",
    "club memberships",
    "software licenses",
    "wifi passwords",
    "social media accounts",
    "email accounts",
    "project notes",
    "meeting notes",
    "shopping lists",
    "recipe collection",
    "book recommendations",
    "movie watchlist",
    "music playlists",
    "fitness goals",
    "diet plan",
    "medication schedule",
    "appointment reminders",
    "birthday reminders",
    "anniversary dates",
    "gift ideas",
    "bucket list items",
    "travel bucket list",
    "language learning progress",
    "skill development",
    "career goals",
]

async def run_single_query(client: httpx.AsyncClient, query: str, user_id: str, idx: int) -> dict:
    """Run a single search query."""
    start = time.time()
    try:
        response = await client.post(
            f"{WORKER_URL}/search",
            headers={"Authorization": f"Bearer {WORKER_API_KEY}"},
            json={"query": query, "user_id": user_id},
            timeout=60.0
        )
        elapsed = (time.time() - start) * 1000
        
        if response.status_code == 200:
            data = response.json()
            return {
                "idx": idx,
                "query": query[:30],
                "status": "success",
                "elapsed_ms": elapsed,
                "timing": data.get("timing", {}),
                "matches": len(data.get("matches", [])),
                "request_id": data.get("request_id")
            }
        else:
            return {
                "idx": idx,
                "query": query[:30],
                "status": "error",
                "elapsed_ms": elapsed,
                "error": response.text[:100]
            }
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        return {
            "idx": idx,
            "query": query[:30],
            "status": "exception",
            "elapsed_ms": elapsed,
            "error": str(e)[:100]
        }

async def run_concurrent_test(num_queries: int = 50):
    """Run concurrent queries."""
    print(f"=" * 80)
    print(f"Running {num_queries} concurrent queries...")
    print(f"=" * 80)
    
    test_start = datetime.now(timezone.utc)
    start_time = time.time()
    
    async with httpx.AsyncClient() as client:
        tasks = []
        for i in range(num_queries):
            query = QUERIES[i % len(QUERIES)]
            user_id = f"load-test-user-{i}"
            tasks.append(run_single_query(client, query, user_id, i))
        
        results = await asyncio.gather(*tasks)
    
    total_time = time.time() - start_time
    test_end = datetime.now(timezone.utc)
    
    # Analyze results
    successful = [r for r in results if r["status"] == "success"]
    failed = [r for r in results if r["status"] != "success"]
    
    print(f"\n{'='*80}")
    print(f"TEST RESULTS")
    print(f"{'='*80}")
    print(f"Total queries: {num_queries}")
    print(f"Successful: {len(successful)}")
    print(f"Failed: {len(failed)}")
    print(f"Total wall time: {total_time*1000:.0f}ms")
    print(f"Throughput: {num_queries/total_time:.1f} queries/sec")
    
    if successful:
        latencies = [r["elapsed_ms"] for r in successful]
        latencies.sort()
        print(f"\nLatency (client-side):")
        print(f"  Min: {min(latencies):.0f}ms")
        print(f"  Max: {max(latencies):.0f}ms")
        print(f"  Avg: {sum(latencies)/len(latencies):.0f}ms")
        print(f"  P50: {latencies[len(latencies)//2]:.0f}ms")
        print(f"  P95: {latencies[int(len(latencies)*0.95)]:.0f}ms")
        print(f"  P99: {latencies[int(len(latencies)*0.99)]:.0f}ms")
        
        # Worker timing breakdown
        embed_times = [r["timing"].get("embedding_ms", 0) for r in successful]
        vectorize_times = [r["timing"].get("vectorize_ms", 0) for r in successful]
        total_times = [r["timing"].get("total_ms", 0) for r in successful]
        
        print(f"\nWorker Timing Breakdown (from response):")
        print(f"  Embedding: avg={sum(embed_times)/len(embed_times):.0f}ms, max={max(embed_times)}ms")
        print(f"  Vectorize: avg={sum(vectorize_times)/len(vectorize_times):.0f}ms, max={max(vectorize_times)}ms")
        print(f"  Total:     avg={sum(total_times)/len(total_times):.0f}ms, max={max(total_times)}ms")
    
    if failed:
        print(f"\nFailed queries:")
        for r in failed[:5]:
            print(f"  [{r['idx']}] {r['query']}: {r.get('error', 'unknown')}")
    
    return test_start, test_end, results

def analyze_supabase_logs(test_start: datetime, test_end: datetime):
    """Analyze logs from Supabase to identify bottlenecks."""
    print(f"\n{'='*80}")
    print(f"ANALYZING SUPABASE LOGS")
    print(f"{'='*80}")
    
    supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
    
    # Add buffer for log flush delay
    query_start = (test_start - timedelta(seconds=5)).isoformat()
    query_end = (test_end + timedelta(seconds=30)).isoformat()
    
    # =========================================================================
    # WORKER LOGS ANALYSIS
    # =========================================================================
    print(f"\n--- Worker Logs (Cloudflare Worker) ---")
    
    worker_logs = supabase.table("worker_logs").select("*")\
        .gte("timestamp", query_start)\
        .lte("timestamp", query_end)\
        .order("timestamp", desc=False)\
        .execute()
    
    print(f"Worker log entries: {len(worker_logs.data)}")
    
    if worker_logs.data:
        # Group by endpoint
        by_endpoint = defaultdict(list)
        for log in worker_logs.data:
            by_endpoint[log["endpoint"]].append(log)
        
        for endpoint, logs in by_endpoint.items():
            embed_times = [l.get("timing_embedding_ms") or 0 for l in logs]
            vectorize_times = [l.get("timing_vectorize_ms") or 0 for l in logs]
            rerank_times = [l.get("timing_rerank_ms") or 0 for l in logs]
            total_times = [l.get("timing_total_ms") or 0 for l in logs]
            
            print(f"\n  {endpoint} ({len(logs)} requests):")
            if any(embed_times):
                print(f"    Embedding:  avg={sum(embed_times)/len(embed_times):.0f}ms, max={max(embed_times)}ms")
            if any(vectorize_times):
                print(f"    Vectorize:  avg={sum(vectorize_times)/len(vectorize_times):.0f}ms, max={max(vectorize_times)}ms")
            if any(rerank_times):
                print(f"    Rerank:     avg={sum(rerank_times)/len(rerank_times):.0f}ms, max={max(rerank_times)}ms")
            if any(total_times):
                print(f"    Total:      avg={sum(total_times)/len(total_times):.0f}ms, max={max(total_times)}ms")
        
        # Identify slow queries
        slow_threshold = 1000  # 1 second
        slow_logs = [l for l in worker_logs.data if (l.get("timing_total_ms") or 0) > slow_threshold]
        if slow_logs:
            print(f"\n  ⚠️  Slow queries (>{slow_threshold}ms): {len(slow_logs)}")
            for log in slow_logs[:5]:
                print(f"    {log['endpoint']}: {log.get('timing_total_ms')}ms (embed={log.get('timing_embedding_ms')}ms)")
    
    # =========================================================================
    # APPLICATION LOGS ANALYSIS
    # =========================================================================
    print(f"\n--- Application Logs (Fly.io) ---")
    
    app_logs = supabase.table("application_logs").select("*")\
        .gte("timestamp", query_start)\
        .lte("timestamp", query_end)\
        .order("timestamp", desc=False)\
        .execute()
    
    print(f"Application log entries: {len(app_logs.data)}")
    
    if app_logs.data:
        # Group by level
        by_level = defaultdict(int)
        for log in app_logs.data:
            by_level[log.get("level", "UNKNOWN")] += 1
        
        print(f"\n  By level:")
        for level, count in sorted(by_level.items()):
            print(f"    {level}: {count}")
        
        # Group by logger
        by_logger = defaultdict(int)
        for log in app_logs.data:
            logger = log.get("logger_name", "unknown")
            # Simplify logger name
            if "." in logger:
                logger = ".".join(logger.split(".")[-2:])
            by_logger[logger] += 1
        
        print(f"\n  By logger (top 10):")
        for logger, count in sorted(by_logger.items(), key=lambda x: -x[1])[:10]:
            print(f"    {logger}: {count}")
        
        # Check for errors
        errors = [l for l in app_logs.data if l.get("level") in ("ERROR", "CRITICAL")]
        if errors:
            print(f"\n  ⚠️  Errors: {len(errors)}")
            for err in errors[:5]:
                msg = err.get("message", "")[:100]
                print(f"    {err.get('logger_name', 'unknown')}: {msg}")
        
        # Check for warnings
        warnings = [l for l in app_logs.data if l.get("level") == "WARNING"]
        if warnings:
            print(f"\n  ⚠️  Warnings: {len(warnings)}")
        
        # Unique correlation IDs (represents unique requests)
        correlation_ids = set(l.get("correlation_id") for l in app_logs.data if l.get("correlation_id"))
        print(f"\n  Unique correlation IDs: {len(correlation_ids)}")
    
    # =========================================================================
    # BOTTLENECK SUMMARY
    # =========================================================================
    print(f"\n{'='*80}")
    print(f"BOTTLENECK ANALYSIS")
    print(f"{'='*80}")
    
    if worker_logs.data:
        search_logs = [l for l in worker_logs.data if l["endpoint"] == "/search"]
        if search_logs:
            embed_times = [l.get("timing_embedding_ms") or 0 for l in search_logs]
            vectorize_times = [l.get("timing_vectorize_ms") or 0 for l in search_logs]
            total_times = [l.get("timing_total_ms") or 0 for l in search_logs]
            
            avg_embed = sum(embed_times) / len(embed_times)
            avg_vectorize = sum(vectorize_times) / len(vectorize_times)
            avg_total = sum(total_times) / len(total_times)
            
            print(f"\nSearch Request Breakdown ({len(search_logs)} requests):")
            print(f"  1. Embedding (Workers AI):  {avg_embed:.0f}ms avg ({avg_embed/avg_total*100:.0f}% of total)")
            print(f"  2. Vectorize Search:        {avg_vectorize:.0f}ms avg ({avg_vectorize/avg_total*100:.0f}% of total)")
            overhead = avg_total - avg_embed - avg_vectorize
            print(f"  3. Overhead (parsing, etc): {overhead:.0f}ms avg ({overhead/avg_total*100:.0f}% of total)")
            
            # Identify the bottleneck
            if avg_embed > avg_vectorize:
                print(f"\n  🔴 BOTTLENECK: Embedding generation (Workers AI)")
                print(f"     Consider: caching embeddings, query batching, or warm-up requests")
            else:
                print(f"\n  🔴 BOTTLENECK: Vector search (Vectorize)")
                print(f"     Consider: index optimization, reducing result count, or region optimization")
            
            # Cold start detection
            max_embed = max(embed_times)
            if max_embed > 5000:
                print(f"\n  ⚠️  COLD START detected: {max_embed}ms embedding time")
                print(f"     Workers AI may have cold started during the test")

async def main():
    print(f"Starting 50-query concurrent test at {datetime.now()}")
    print(f"Worker URL: {WORKER_URL}")
    
    # Run the test
    test_start, test_end, results = await run_concurrent_test(50)
    
    # Wait for logs to flush to Supabase
    print(f"\nWaiting 15 seconds for logs to flush to Supabase...")
    await asyncio.sleep(15)
    
    # Analyze logs
    analyze_supabase_logs(test_start, test_end)
    
    print(f"\n{'='*80}")
    print(f"Test completed at {datetime.now()}")
    print(f"{'='*80}")

if __name__ == "__main__":
    asyncio.run(main())
