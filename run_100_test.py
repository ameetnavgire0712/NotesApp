"""Run 100 concurrent query test with detailed timing."""
import asyncio
import aiohttp
import time
from datetime import datetime
import os
from dotenv import load_dotenv

load_dotenv()

API_URL = "https://notesapp-search.fly.dev"
API_KEY = os.getenv("SEARCH_API_KEY") or "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

QUERIES = [
    "What is my aadhaar number",
    "Show me my passport details",
    "What is my PAN card number",
    "Find notes about meetings",
    "What are my bank account details",
    "Show all documents from last month",
    "Important deadlines",
    "Contact information",
    "Medical records",
    "Travel plans",
    # Repeat to get 100 queries
]

# Extend to 100 queries
while len(QUERIES) < 100:
    QUERIES.extend(QUERIES[:10])
QUERIES = QUERIES[:100]

async def run_query(session, query, idx):
    """Run a single query and return timing info."""
    start = time.time()
    try:
        async with session.post(
            f"{API_URL}/api/v1/search",
            json={"query": query, "top_k": 5},
            headers={"Authorization": f"Bearer {API_KEY}"},
            timeout=aiohttp.ClientTimeout(total=120)
        ) as resp:
            end = time.time()
            data = await resp.json()
            duration = end - start
            return {
                "idx": idx,
                "query": query[:30],
                "status": resp.status,
                "duration": duration,
                "success": resp.status == 200,
                "error": data.get("detail") if resp.status != 200 else None
            }
    except Exception as e:
        end = time.time()
        return {
            "idx": idx,
            "query": query[:30],
            "status": 0,
            "duration": end - start,
            "success": False,
            "error": str(e)[:50]
        }

async def main():
    print(f"Starting 100 query test at {datetime.now().strftime('%H:%M:%S')}")
    print("=" * 80)
    
    # Create session
    connector = aiohttp.TCPConnector(limit=100)
    async with aiohttp.ClientSession(connector=connector) as session:
        start_all = time.time()
        
        # Run all queries concurrently
        tasks = [run_query(session, q, i) for i, q in enumerate(QUERIES, 1)]
        results = await asyncio.gather(*tasks)
        
        end_all = time.time()
        
    # Sort by completion order (duration)
    results.sort(key=lambda x: x['duration'])
    
    # Print results
    print(f"\n{'#':>3} | {'Query':<30} | {'Status':>6} | {'Duration':>10} | Error")
    print("-" * 80)
    
    success = [r for r in results if r['success']]
    failed = [r for r in results if not r['success']]
    
    for r in results[:20]:
        status_str = "OK" if r['success'] else f"ERR:{r['status']}"
        error = r['error'][:30] if r['error'] else ""
        print(f"{r['idx']:>3} | {r['query']:<30} | {status_str:>6} | {r['duration']:>9.2f}s | {error}")
    
    if len(results) > 20:
        print(f"... ({len(results) - 20} more results)")
    
    # Statistics
    print("\n" + "=" * 80)
    print("STATISTICS")
    print("=" * 80)
    print(f"Total queries: {len(results)}")
    print(f"Successful:    {len(success)}")
    print(f"Failed:        {len(failed)}")
    print(f"Total time:    {end_all - start_all:.2f}s")
    
    if success:
        durations = [r['duration'] for r in success]
        print(f"\nSuccessful queries timing:")
        print(f"  Min:    {min(durations):.2f}s")
        print(f"  Max:    {max(durations):.2f}s")
        print(f"  Avg:    {sum(durations)/len(durations):.2f}s")
        print(f"  P50:    {sorted(durations)[len(durations)//2]:.2f}s")
        print(f"  P90:    {sorted(durations)[int(len(durations)*0.9)]:.2f}s")
        print(f"  P99:    {sorted(durations)[int(len(durations)*0.99)]:.2f}s")
        
        # Distribution
        print(f"\nDuration distribution:")
        print(f"  <5s:   {sum(1 for d in durations if d < 5)} queries")
        print(f"  5-10s: {sum(1 for d in durations if 5 <= d < 10)} queries")
        print(f"  10-20s: {sum(1 for d in durations if 10 <= d < 20)} queries")
        print(f"  20-30s: {sum(1 for d in durations if 20 <= d < 30)} queries")
        print(f"  30-60s: {sum(1 for d in durations if 30 <= d < 60)} queries")
        print(f"  >60s:  {sum(1 for d in durations if d >= 60)} queries")
    
    if failed:
        print(f"\nFailed queries:")
        for r in failed[:10]:
            print(f"  Query {r['idx']}: {r['error']}")
    
    print(f"\nTest completed at {datetime.now().strftime('%H:%M:%S')}")

if __name__ == "__main__":
    asyncio.run(main())
