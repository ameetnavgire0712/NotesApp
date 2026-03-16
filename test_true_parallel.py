#!/usr/bin/env python3
"""True parallel test using asyncio - mimics real concurrent users"""

import asyncio
import aiohttp
import time
from datetime import datetime

WORKER_URL = 'https://notesapp-vector-search.monocle0712.workers.dev'
API_KEY = 'na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU'

async def single_request(session, num, test_id):
    """Single RAG search request"""
    start = time.time()
    try:
        async with session.post(
            f'{WORKER_URL}/rag-search-auth',
            json={'query': f'asynctest_{test_id} query {num}'},
            headers={'X-API-Key': API_KEY, 'Content-Type': 'application/json'},
            timeout=aiohttp.ClientTimeout(total=60)
        ) as resp:
            data = await resp.json()
            worker_ms = data.get('metadata', {}).get('timing', {}).get('total_ms', 0)
            return {
                'num': num, 
                'ok': resp.status == 200, 
                'client_ms': int((time.time() - start) * 1000),
                'worker_ms': worker_ms
            }
    except Exception as e:
        return {'num': num, 'ok': False, 'error': str(e)[:50]}

async def run_test(count):
    """Run N concurrent requests"""
    test_id = int(time.time())
    
    print(f"\n{'='*60}")
    print(f"  TRUE PARALLEL TEST: {count} concurrent requests")
    print(f"{'='*60}")
    print(f"Test ID: asynctest_{test_id}")
    print(f"Launch time: {datetime.now().strftime('%H:%M:%S.%f')[:-3]}")
    
    connector = aiohttp.TCPConnector(limit=count, limit_per_host=count)
    async with aiohttp.ClientSession(connector=connector) as session:
        start = time.time()
        
        # All tasks created and launched together - TRUE PARALLEL
        tasks = [single_request(session, i, test_id) for i in range(1, count + 1)]
        results = await asyncio.gather(*tasks)
        
        total_ms = int((time.time() - start) * 1000)
    
    # Analyze results
    ok = [r for r in results if r.get('ok')]
    failed = [r for r in results if not r.get('ok')]
    
    print(f"\nRESULTS:")
    print(f"  Total wall-clock time: {total_ms}ms")
    print(f"  Success: {len(ok)}/{count}")
    print(f"  Failed: {len(failed)}")
    
    if ok:
        client_times = [r['client_ms'] for r in ok]
        worker_times = [r['worker_ms'] for r in ok if r.get('worker_ms')]
        
        print(f"\nTIMING:")
        print(f"  Client-side: min={min(client_times)}ms, max={max(client_times)}ms, avg={sum(client_times)//len(client_times)}ms")
        if worker_times:
            print(f"  Worker-side: min={min(worker_times)}ms, max={max(worker_times)}ms, avg={sum(worker_times)//len(worker_times)}ms")
        
        # Calculate if parallel
        sequential_estimate = sum(client_times)
        parallelism = sequential_estimate / total_ms if total_ms > 0 else 0
        
        print(f"\nPARALLELISM ANALYSIS:")
        print(f"  If sequential would take: ~{sequential_estimate}ms")
        print(f"  Actual time: {total_ms}ms")
        print(f"  Parallelism factor: {parallelism:.1f}x")
        
        if total_ms < 5000:
            print(f"  ✅ PARALLEL - {count} queries completed in {total_ms}ms (close to single query time)")
        elif total_ms < count * 1000:
            print(f"  ⚠️  PARTIALLY PARALLEL")
        else:
            print(f"  ❌ SEQUENTIAL")
    
    if failed:
        print(f"\nFAILURES:")
        for f in failed[:3]:
            print(f"  Query {f['num']}: {f.get('error', 'unknown')}")
    
    return test_id, total_ms, len(ok)

async def fetch_logs(test_id):
    """Fetch logs from Supabase to verify arrival times"""
    import os
    try:
        from supabase import create_client
        url = 'https://fvacgkxvpsxesxyeddls.supabase.co'
        key = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ2YWNna3h2cHN4ZXN4eWVkZGxzIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTczNjYyNjgxMiwiZXhwIjoyMDUyMjAyODEyfQ.JjJJfJbjgvCEuDefEVrODJX1E1NfALsLaBuXZcaPlz0'
        client = create_client(url, key)
        
        result = client.table('user_activities').select('created_at, query, total_time_ms, metadata').ilike('query', f'%asynctest_{test_id}%').order('created_at').execute()
        
        print(f"\n{'='*60}")
        print(f"  SERVER-SIDE LOG ANALYSIS")
        print(f"{'='*60}")
        
        if not result.data:
            print("No logs found yet (may take a few seconds to sync)")
            return
        
        # Extract arrival timestamps from worker_request_id
        arrivals = []
        for row in result.data:
            metadata = row.get('metadata', {})
            wr_id = metadata.get('worker_request_id', '')
            if wr_id:
                # Extract timestamp from wr_1770907867123_abc format
                ts_str = wr_id.split('_')[1] if '_' in wr_id else '0'
                arrivals.append({
                    'arrival_ms': int(ts_str),
                    'query': row['query'],
                    'duration': row.get('total_time_ms', 0)
                })
        
        if arrivals:
            arrivals.sort(key=lambda x: x['arrival_ms'])
            first = arrivals[0]['arrival_ms']
            
            print(f"{'ARRIVAL (ms from first)':<25} | {'DURATION':<10} | QUERY")
            print("-"*70)
            for a in arrivals:
                offset = a['arrival_ms'] - first
                print(f"+{offset:>6}ms                   | {a['duration']:>6}ms   | {a['query']}")
            
            spread = arrivals[-1]['arrival_ms'] - first
            print(f"\nARRIVAL SPREAD: {spread}ms")
            if spread < 100:
                print("✅ TRUE PARALLEL - All requests arrived within 100ms of each other")
            elif spread < 1000:
                print("⚠️  MOSTLY PARALLEL - Requests arrived within 1 second")
            else:
                print("❌ NOT PARALLEL - Requests arrived over multiple seconds")
                
    except ImportError:
        print("supabase package not installed - can't fetch logs")
    except Exception as e:
        print(f"Error fetching logs: {e}")

async def main():
    print("="*60)
    print("  CLOUDFLARE WORKER CONCURRENCY TEST")
    print("  Using Python asyncio for TRUE parallel requests")
    print("="*60)
    
    # Test with 100 concurrent
    test_id, total_ms, success = await run_test(100)
    
    # Wait a moment for logs to sync
    print("\nWaiting 2 seconds for logs to sync...")
    await asyncio.sleep(2)
    
    # Fetch and analyze server-side logs
    await fetch_logs(test_id)

if __name__ == "__main__":
    asyncio.run(main())
