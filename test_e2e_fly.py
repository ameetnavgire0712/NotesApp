"""
End-to-end test through Fly.io - 50 concurrent queries.
Tests the full RAG search flow: Fly.io -> Worker -> back
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

# Configuration - Test through Fly.io
FLY_URL = "https://notesapp-search.fly.dev"
API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"  # API key for auth
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
    "wifi password",
    "social media accounts",
]

async def run_single_query(client: httpx.AsyncClient, query: str, query_id: int):
    """Run a single RAG search query through Fly.io"""
    start = time.time()
    try:
        response = await client.post(
            f"{FLY_URL}/api/v1/search",
            json={"query": query, "max_results": 5},
            headers={
                "X-API-Key": API_KEY,
                "Content-Type": "application/json"
            },
            timeout=60.0  # Increased timeout for e2e
        )
        elapsed = (time.time() - start) * 1000
        
        if response.status_code == 200:
            data = response.json()
            return {
                "query_id": query_id,
                "query": query,
                "status": "success",
                "latency_ms": elapsed,
                "documents_count": len(data.get("documents", [])),
                "has_answer": bool(data.get("answer")),
                "total_duration_ms": data.get("total_duration_ms", 0)
            }
        else:
            return {
                "query_id": query_id,
                "query": query,
                "status": f"error_{response.status_code}",
                "latency_ms": elapsed,
                "error": response.text[:200]
            }
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        return {
            "query_id": query_id,
            "query": query,
            "status": "exception",
            "latency_ms": elapsed,
            "error": f"{type(e).__name__}: {str(e)}"
        }

async def run_concurrent_test(num_queries: int = 50):
    """Run concurrent queries through Fly.io"""
    print(f"\n{'='*60}")
    print(f"END-TO-END TEST THROUGH FLY.IO")
    print(f"{'='*60}")
    print(f"Target: {FLY_URL}")
    print(f"Queries: {num_queries}")
    print(f"API Key: {API_KEY[:10]}..." if API_KEY else "API Key: NOT SET!")
    
    if not API_KEY:
        print("\n❌ ERROR: NOTESAPP_API_KEY not set in environment")
        return
    
    # Use queries cyclically
    test_queries = [(QUERIES[i % len(QUERIES)], i) for i in range(num_queries)]
    
    # Record start time for log query
    test_start = datetime.now(timezone.utc)
    print(f"Test start time: {test_start.isoformat()}")
    
    # Run all queries concurrently
    print(f"\n🚀 Starting {num_queries} concurrent queries...")
    start_time = time.time()
    
    async with httpx.AsyncClient() as client:
        tasks = [run_single_query(client, q, i) for q, i in test_queries]
        results = await asyncio.gather(*tasks)
    
    total_time = time.time() - start_time
    
    # Analyze results
    successful = [r for r in results if r["status"] == "success"]
    failed = [r for r in results if r["status"] != "success"]
    
    print(f"\n{'='*60}")
    print("TEST RESULTS")
    print(f"{'='*60}")
    print(f"Total time: {total_time:.2f}s")
    print(f"Successful: {len(successful)}/{num_queries}")
    print(f"Failed: {len(failed)}/{num_queries}")
    print(f"Throughput: {len(successful)/total_time:.1f} queries/sec")
    
    if successful:
        latencies = [r["latency_ms"] for r in successful]
        server_times = [r.get("total_duration_ms", 0) for r in successful if r.get("total_duration_ms")]
        
        latencies.sort()
        print(f"\n📊 Client-side Latency (includes network):")
        print(f"  Min: {min(latencies):.0f}ms")
        print(f"  Max: {max(latencies):.0f}ms")
        print(f"  Avg: {sum(latencies)/len(latencies):.0f}ms")
        print(f"  P50: {latencies[len(latencies)//2]:.0f}ms")
        print(f"  P95: {latencies[int(len(latencies)*0.95)]:.0f}ms")
        
        if server_times:
            server_times.sort()
            print(f"\n📊 Server-side Duration (from response):")
            print(f"  Min: {min(server_times):.0f}ms")
            print(f"  Max: {max(server_times):.0f}ms")
            print(f"  Avg: {sum(server_times)/len(server_times):.0f}ms")
    
    if failed:
        print(f"\n❌ Failed Queries:")
        for r in failed[:5]:
            print(f"  Query {r['query_id']}: {r['status']} - {r.get('error', 'unknown')[:100]}")
    
    # Wait for logs to be written
    print(f"\n⏳ Waiting 3s for logs to be written...")
    await asyncio.sleep(3)
    
    # Query Supabase for logs
    return await analyze_logs(test_start, num_queries, successful)

async def analyze_logs(start_time: datetime, num_queries: int, results: list):
    """Analyze logs from Supabase after test"""
    print(f"\n{'='*60}")
    print("LOG ANALYSIS FROM SUPABASE")
    print(f"{'='*60}")
    
    supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
    
    # Query worker_logs
    print("\n📋 Worker Logs (Cloudflare Worker):")
    worker_logs = supabase.table("worker_logs").select("*").gte(
        "created_at", start_time.isoformat()
    ).order("created_at", desc=False).execute()
    
    if worker_logs.data:
        print(f"  Total entries: {len(worker_logs.data)}")
        
        # Group by endpoint
        by_endpoint = defaultdict(list)
        for log in worker_logs.data:
            by_endpoint[log.get("endpoint", "unknown")].append(log)
        
        for endpoint, logs in by_endpoint.items():
            print(f"\n  {endpoint}:")
            print(f"    Count: {len(logs)}")
            
            if endpoint == "/search":
                embed_times = [l.get("embedding_time_ms", 0) for l in logs if l.get("embedding_time_ms")]
                vectorize_times = [l.get("vectorize_time_ms", 0) for l in logs if l.get("vectorize_time_ms")]
                total_times = [l.get("total_time_ms", 0) for l in logs if l.get("total_time_ms")]
                
                if embed_times:
                    print(f"    Embedding: avg={sum(embed_times)/len(embed_times):.0f}ms, max={max(embed_times):.0f}ms")
                if vectorize_times:
                    print(f"    Vectorize: avg={sum(vectorize_times)/len(vectorize_times):.0f}ms, max={max(vectorize_times):.0f}ms")
                if total_times:
                    print(f"    Total: avg={sum(total_times)/len(total_times):.0f}ms, max={max(total_times):.0f}ms")
            
            elif endpoint in ["/embed", "/embed-batch"]:
                embed_times = [l.get("embedding_time_ms", 0) for l in logs if l.get("embedding_time_ms")]
                if embed_times:
                    print(f"    Embedding: avg={sum(embed_times)/len(embed_times):.0f}ms, max={max(embed_times):.0f}ms")
    else:
        print("  No worker logs found")
    
    # Query application_logs
    print("\n📋 Application Logs (Fly.io):")
    app_logs = supabase.table("application_logs").select("*").gte(
        "timestamp", start_time.isoformat()
    ).order("timestamp", desc=False).execute()
    
    if app_logs.data:
        print(f"  Total entries: {len(app_logs.data)}")
        
        # Look for timing info
        timing_logs = [l for l in app_logs.data if l.get("metadata") and "duration" in str(l.get("metadata", {}))]
        if timing_logs:
            print(f"  Timing entries: {len(timing_logs)}")
    else:
        print("  No application logs found for rag_agent")
    
    # Also check for any error logs
    error_logs = supabase.table("application_logs").select("*").gte(
        "timestamp", start_time.isoformat()
    ).eq("level", "ERROR").order("timestamp", desc=False).execute()
    
    if error_logs.data:
        print(f"\n⚠️ Error Logs: {len(error_logs.data)}")
        for log in error_logs.data[:3]:
            print(f"  - {log.get('message', 'No message')[:100]}")
    
    # Calculate bottleneck analysis
    if worker_logs.data:
        search_logs = [l for l in worker_logs.data if l.get("endpoint") == "/search"]
        embed_logs = [l for l in worker_logs.data if l.get("endpoint") == "/embed"]
        rerank_logs = [l for l in worker_logs.data if l.get("endpoint") == "/rerank"]
        
        print(f"\n{'='*60}")
        print("BOTTLENECK ANALYSIS")
        print(f"{'='*60}")
        
        if search_logs:
            embed_times = [l.get("embedding_time_ms", 0) for l in search_logs if l.get("embedding_time_ms")]
            vectorize_times = [l.get("vectorize_time_ms", 0) for l in search_logs if l.get("vectorize_time_ms")]
            total_times = [l.get("total_time_ms", 0) for l in search_logs if l.get("total_time_ms")]
            
            if total_times:
                print(f"\n  Worker /search ({len(search_logs)} calls):")
                print(f"    Embedding: avg={sum(embed_times)/len(embed_times):.0f}ms, max={max(embed_times):.0f}ms")
                print(f"    Vectorize: avg={sum(vectorize_times)/len(vectorize_times):.0f}ms, max={max(vectorize_times):.0f}ms")
                print(f"    Total: avg={sum(total_times)/len(total_times):.0f}ms, max={max(total_times):.0f}ms")
        
        if embed_logs:
            embed_times = [l.get("embedding_time_ms", 0) for l in embed_logs if l.get("embedding_time_ms")]
            total_times = [l.get("total_time_ms", 0) for l in embed_logs if l.get("total_time_ms")]
            if embed_times:
                print(f"\n  Worker /embed ({len(embed_logs)} calls):")
                print(f"    Embedding: avg={sum(embed_times)/len(embed_times):.0f}ms, max={max(embed_times):.0f}ms")
                print(f"    Total: avg={sum(total_times)/len(total_times):.0f}ms, max={max(total_times):.0f}ms")
        
        if rerank_logs:
            total_times = [l.get("total_time_ms", 0) for l in rerank_logs if l.get("total_time_ms")]
            if total_times:
                print(f"\n  Worker /rerank ({len(rerank_logs)} calls):")
                print(f"    Total: avg={sum(total_times)/len(total_times):.0f}ms, max={max(total_times):.0f}ms")
        
        # Calculate overall Worker time vs total request time
        total_worker_time = sum(
            l.get("total_time_ms", 0) for l in worker_logs.data if l.get("total_time_ms")
        )
        print(f"\n  Total Worker time: {total_worker_time/1000:.1f}s")
        print(f"  Total Test time: {num_queries * sum(r.get('total_duration_ms', 0) for r in results if r.get('total_duration_ms'))/len([r for r in results if r.get('total_duration_ms')])/1000:.1f}s avg per query")
    
    return worker_logs.data if worker_logs.data else []

if __name__ == "__main__":
    asyncio.run(run_concurrent_test(50))
