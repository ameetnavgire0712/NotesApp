import asyncio
import httpx
import time
import uuid
from datetime import datetime

API_KEY = 'na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU'
BASE_URL = 'https://notesapp-search.fly.dev'

QUERIES = ['meeting', 'project', 'deadline', 'budget', 'client', 'team', 'schedule', 'invoice', 'contract', 'proposal'] * 10

async def search(client, i, query):
    request_id = str(uuid.uuid4())[:8]
    start = time.time()
    start_dt = datetime.now().isoformat()
    try:
        resp = await client.get(
            f'{BASE_URL}/api/v1/search/instant',
            params={'q': query},
            headers={'X-API-Key': API_KEY, 'X-Request-ID': f'test-{i:03d}-{request_id}'},
            timeout=180.0
        )
        elapsed = time.time() - start
        end_dt = datetime.now().isoformat()
        return (i, query, resp.status_code, elapsed, start_dt, end_dt, request_id, None)
    except Exception as e:
        elapsed = time.time() - start
        end_dt = datetime.now().isoformat()
        return (i, query, 0, elapsed, start_dt, end_dt, request_id, str(e)[:80])

async def main():
    print(f'Starting 100 concurrent queries at {datetime.now().isoformat()}...')
    t0 = time.time()
    
    async with httpx.AsyncClient() as client:
        tasks = [search(client, i, q) for i, q in enumerate(QUERIES)]
        results = await asyncio.gather(*tasks, return_exceptions=True)
    
    wall = time.time() - t0
    
    # Filter out exceptions
    valid_results = [r for r in results if isinstance(r, tuple)]
    exceptions = [r for r in results if not isinstance(r, tuple)]
    
    # Save results to file
    with open('c:/Users/ameet/Documents/NotesApp/query_results.txt', 'w') as f:
        f.write('100 Concurrent Query Test Results\n')
        f.write('=' * 120 + '\n\n')
        
        successes = [r for r in valid_results if r[2] == 200]
        failures = [r for r in valid_results if r[2] != 200]
        
        f.write(f'Total: {len(results)} queries\n')
        f.write(f'Success: {len(successes)}\n')
        f.write(f'Failed: {len(failures)}\n')
        f.write(f'Exceptions: {len(exceptions)}\n')
        f.write(f'Wall-clock time: {wall:.2f}s\n\n')
        
        f.write('ALL QUERIES (sorted by index):\n')
        f.write('-' * 120 + '\n')
        f.write(f'Idx  | Query        | Status |  Duration | Start Time                 | End Time                   | Req ID\n')
        f.write('-' * 120 + '\n')
        
        for r in sorted(valid_results, key=lambda x: x[0]):
            status = 'OK' if r[2] == 200 else f'ERR'
            err = f' [{r[7]}]' if r[7] else ''
            f.write(f'{r[0]:>4} | {r[1]:12} | {status:>6} | {r[3]:>8.2f}s | {r[4]:26} | {r[5]:26} | {r[6]}{err}\n')
        
        if successes:
            times = [r[3] for r in successes]
            f.write(f'\n\nTiming Statistics (successful queries):\n')
            f.write(f'  Min: {min(times):.2f}s\n')
            f.write(f'  Max: {max(times):.2f}s\n')
            f.write(f'  Avg: {sum(times)/len(times):.2f}s\n')
    
    print(f'Results: {len(successes)}/100 succeeded')
    print(f'Wall-clock time: {wall:.2f}s')
    print(f'Results saved to query_results.txt')

if __name__ == '__main__':
    asyncio.run(main())
