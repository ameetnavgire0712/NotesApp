"""Test concurrent search queries against the production API"""
import asyncio
import aiohttp
import time

API_URL = 'https://notesapp-search.fly.dev/api/v1/search/instant'
API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

# Different search queries to test
QUERIES = [
    'resume',
    'pan card',
    'aadhaar',
    'marketing',
    'logo',
    'personal documents',
    'work experience',
    'education',
    'skills',
    'projects'
]

async def search(session: aiohttp.ClientSession, query: str, idx: int) -> dict:
    """Execute a single search query"""
    start = time.time()
    headers = {"X-API-Key": API_KEY}
    try:
        async with session.get(
            f'{API_URL}?q={query}', 
            headers=headers,
            timeout=aiohttp.ClientTimeout(total=30)
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

async def main():
    print('Running 10 concurrent search queries...\n')
    overall_start = time.time()
    
    async with aiohttp.ClientSession() as session:
        tasks = [search(session, q, i) for i, q in enumerate(QUERIES)]
        results = await asyncio.gather(*tasks)
    
    overall_time = time.time() - overall_start
    
    # Print results table
    print(f"{'Query':<25} {'Status':<8} {'Results':<8} {'Time (s)':<10}")
    print('-' * 55)
    
    times = []
    for r in sorted(results, key=lambda x: x['idx']):
        status = r.get('status', 'error')
        count = r.get('results', 'N/A')
        t = r['time']
        times.append(t)
        print(f"{r['query']:<25} {status:<8} {count:<8} {t:.3f}")
    
    print('-' * 55)
    print(f"Total wall-clock time: {overall_time:.3f}s")
    print(f"Sum of individual times: {sum(times):.3f}s")
    print(f"Avg response time: {sum(times)/len(times):.3f}s")
    print(f"Min: {min(times):.3f}s | Max: {max(times):.3f}s")
    print(f"Concurrency speedup: {sum(times)/overall_time:.1f}x")

if __name__ == "__main__":
    asyncio.run(main())
