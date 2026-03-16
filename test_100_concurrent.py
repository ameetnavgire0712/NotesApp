"""Test 100 concurrent search queries against the production API"""
import asyncio
import aiohttp
import time
import random

API_URL = 'https://notesapp-search.fly.dev/api/v1/search/instant'
API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

# Different search queries to test - expanded list
QUERIES = [
    'resume', 'pan card', 'aadhaar', 'marketing', 'logo',
    'personal documents', 'work experience', 'education', 'skills', 'projects',
    'certificate', 'bank statement', 'tax', 'invoice', 'contract',
    'passport', 'license', 'id proof', 'address proof', 'insurance',
]


async def search(session: aiohttp.ClientSession, query: str, idx: int, semaphore: asyncio.Semaphore = None) -> dict:
    """Execute a single search query"""
    start = time.time()
    headers = {"X-API-Key": API_KEY}
    
    async def do_search():
        try:
            async with session.get(
                f'{API_URL}?q={query}', 
                headers=headers,
                timeout=aiohttp.ClientTimeout(total=60)  # Increased timeout
            ) as resp:
                data = await resp.json()
                elapsed = time.time() - start
                count = len(data.get('results', []))
                return {
                    'idx': idx, 
                    'query': query, 
                    'status': resp.status, 
                    'results': count, 
                    'time': elapsed
                }
        except Exception as e:
            elapsed = time.time() - start
            return {
                'idx': idx, 
                'query': query, 
                'status': 'error', 
                'error': str(e), 
                'time': elapsed
            }
    
    if semaphore:
        async with semaphore:
            return await do_search()
    return await do_search()


async def run_test(num_queries: int, use_semaphore: bool = False, max_concurrent: int = None):
    """Run concurrent search test"""
    print(f'\n{"="*60}')
    print(f'Running {num_queries} concurrent search queries...')
    if use_semaphore:
        print(f'Using semaphore with max {max_concurrent} concurrent')
    print('='*60 + '\n')
    
    overall_start = time.time()
    
    # Create a connector with higher limits
    connector = aiohttp.TCPConnector(limit=200, limit_per_host=100)
    
    semaphore = asyncio.Semaphore(max_concurrent) if use_semaphore else None
    
    async with aiohttp.ClientSession(connector=connector) as session:
        # Generate queries - cycle through the list
        queries = [QUERIES[i % len(QUERIES)] for i in range(num_queries)]
        
        tasks = [search(session, q, i, semaphore) for i, q in enumerate(queries)]
        results = await asyncio.gather(*tasks)
    
    overall_time = time.time() - overall_start
    
    # Aggregate stats
    times = []
    errors = 0
    success_count = 0
    
    for r in results:
        times.append(r['time'])
        if r.get('status') == 'error' or r.get('status', 200) != 200:
            errors += 1
        else:
            success_count += 1
    
    # Print summary
    print(f"\n{'='*60}")
    print("RESULTS SUMMARY")
    print('='*60)
    print(f"Total queries:        {num_queries}")
    print(f"Successful:           {success_count}")
    print(f"Errors:               {errors}")
    print(f"")
    print(f"Wall-clock time:      {overall_time:.3f}s")
    print(f"Sum of response times:{sum(times):.3f}s")
    print(f"Avg response time:    {sum(times)/len(times):.3f}s")
    print(f"Min response time:    {min(times):.3f}s")
    print(f"Max response time:    {max(times):.3f}s")
    print(f"")
    print(f"Throughput:           {num_queries/overall_time:.1f} queries/sec")
    print(f"Concurrency factor:   {sum(times)/overall_time:.1f}x")
    print('='*60)
    
    # Show first 10 and last 10 results for timing breakdown
    sorted_by_time = sorted(results, key=lambda x: x['time'])
    
    print(f"\n10 FASTEST:")
    print(f"{'Idx':<6} {'Query':<20} {'Status':<8} {'Time (s)':<10}")
    print('-' * 50)
    for r in sorted_by_time[:10]:
        print(f"{r['idx']:<6} {r['query']:<20} {r.get('status','?'):<8} {r['time']:.3f}")
    
    print(f"\n10 SLOWEST:")
    print(f"{'Idx':<6} {'Query':<20} {'Status':<8} {'Time (s)':<10}")
    print('-' * 50)
    for r in sorted_by_time[-10:]:
        print(f"{r['idx']:<6} {r['query']:<20} {r.get('status','?'):<8} {r['time']:.3f}")
    
    # Check for errors
    if errors > 0:
        print(f"\n⚠️  ERRORS ({errors}):")
        for r in results:
            if r.get('status') == 'error' or r.get('status', 200) != 200:
                print(f"  [{r['idx']}] {r['query']}: {r.get('error', r.get('status'))}")
    
    return results


async def main():
    # Test 100 concurrent queries
    await run_test(100)


if __name__ == "__main__":
    asyncio.run(main())
