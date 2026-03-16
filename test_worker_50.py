"""
Test 50 concurrent queries against Worker /rag-search-auth endpoint.
Compares with previous Fly.io results.
"""
import asyncio
import aiohttp
import time
from statistics import mean, stdev

API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"
WORKER_URL = "https://notesapp-vector-search.monocle0712.workers.dev/rag-search-auth"

QUERIES = [
    "what is my resume about",
    "find documents about python",
    "search for machine learning notes",
    "what did I save about kubernetes",
    "find my travel documents",
    "notes about cooking recipes",
    "what is cognee",
    "search for interview preparation",
    "find documents about AWS",
    "what are my project notes",
    "search for budget planning",
    "find notes about meditation",
    "what did I save about fitness",
    "documents about home renovation",
    "find my reading list",
    "notes about productivity",
    "what is in my work documents",
    "search for meeting notes",
    "find documents about investments",
    "notes about learning goals",
    "what did I save about health",
    "search for vacation planning",
    "find my tech notes",
    "documents about personal growth",
    "notes about side projects",
    "what is my password manager",
    "search for shopping lists",
    "find documents about cars",
    "notes about gardening",
    "what did I save about music",
    "search for book summaries",
    "find my financial notes",
    "documents about family",
    "notes about hobbies",
    "what is in my research notes",
    "search for gift ideas",
    "find documents about insurance",
    "notes about career goals",
    "what did I save about movies",
    "search for workout routines",
    "find my study notes",
    "documents about pets",
    "notes about relationships",
    "what is my daily routine",
    "search for meal prep",
    "find documents about taxes",
    "notes about mental health",
    "what did I save about sports",
    "search for home automation",
    "find my journal entries"
]

async def search_query(session: aiohttp.ClientSession, query: str, idx: int):
    """Execute a single search query and return timing info."""
    start = time.time()
    try:
        async with session.post(
            WORKER_URL,
            json={"query": query, "max_results": 5},
            headers={
                "Content-Type": "application/json",
                "X-API-Key": API_KEY
            }
        ) as response:
            data = await response.json()
            client_ms = (time.time() - start) * 1000
            backend_ms = data.get("metadata", {}).get("timing", {}).get("total_ms", 0)
            results = len(data.get("results", []))
            success = data.get("success", False)
            return {
                "idx": idx,
                "query": query[:25],
                "success": success,
                "client_ms": round(client_ms),
                "backend_ms": round(backend_ms) if backend_ms else 0,
                "results": results
            }
    except Exception as e:
        client_ms = (time.time() - start) * 1000
        return {
            "idx": idx,
            "query": query[:25],
            "success": False,
            "client_ms": round(client_ms),
            "backend_ms": 0,
            "results": 0,
            "error": str(e)[:50]
        }

async def run_concurrent_test():
    """Run all queries concurrently and measure total time."""
    print(f"Testing 50 concurrent queries against Worker /rag-search-auth...")
    print(f"URL: {WORKER_URL}")
    print()
    
    wall_start = time.time()
    
    connector = aiohttp.TCPConnector(limit=50)  # Allow 50 concurrent connections
    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = [search_query(session, q, i) for i, q in enumerate(QUERIES)]
        results = await asyncio.gather(*tasks)
    
    wall_time = time.time() - wall_start
    
    # Print results table
    print(f"{'Query':<28} {'OK':<5} {'Client':<10} {'Backend':<10} {'Results':<8}")
    print("-" * 70)
    for r in sorted(results, key=lambda x: x["idx"]):
        ok = "Yes" if r["success"] else "No"
        print(f"{r['query']:<28} {ok:<5} {r['client_ms']:>6}ms   {r['backend_ms']:>6}ms   {r['results']:>5}")
    
    # Calculate stats
    successful = [r for r in results if r["success"]]
    failed = [r for r in results if not r["success"]]
    
    if successful:
        client_times = [r["client_ms"] for r in successful]
        backend_times = [r["backend_ms"] for r in successful if r["backend_ms"] > 0]
        
        print()
        print("=" * 50)
        print("RESULTS")
        print("=" * 50)
        print(f"Total wall clock time: {wall_time:.1f}s")
        print(f"Successful: {len(successful)} / 50")
        print(f"Failed: {len(failed)}")
        print()
        print("Client-side timing (includes network):")
        print(f"  Average: {mean(client_times):.0f}ms")
        print(f"  Min: {min(client_times)}ms")
        print(f"  Max: {max(client_times)}ms")
        if len(client_times) > 1:
            print(f"  StdDev: {stdev(client_times):.0f}ms")
        print()
        if backend_times:
            print("Backend timing (Worker reported):")
            print(f"  Average: {mean(backend_times):.0f}ms")
            print(f"  Min: {min(backend_times)}ms")
            print(f"  Max: {max(backend_times)}ms")
        print()
        print("COMPARISON WITH FLY.IO (from earlier test):")
        print("  Fly.io wall clock for 50 queries: 46s (linear queuing)")
        print(f"  Worker wall clock for 50 queries: {wall_time:.1f}s (parallel)")
        print(f"  Speedup: {46/wall_time:.1f}x faster!")
    else:
        print("All queries failed!")
        for r in failed[:5]:
            print(f"  Error: {r.get('error', 'Unknown')}")

if __name__ == "__main__":
    asyncio.run(run_concurrent_test())
