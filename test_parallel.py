#!/usr/bin/env python3
"""Test true parallel execution of Worker endpoints"""

import asyncio
import aiohttp
import time
from datetime import datetime

WORKER_URL = "https://notesapp-vector-search.monocle0712.workers.dev"
API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

async def test_rag_search(session, query_num):
    """Single RAG search request"""
    start = time.time()
    start_dt = datetime.now()
    try:
        async with session.post(
            f"{WORKER_URL}/rag-search-auth",
            json={"query": f"parallel test {query_num}"},
            headers={"X-API-Key": API_KEY, "Content-Type": "application/json"},
            timeout=aiohttp.ClientTimeout(total=120)
        ) as resp:
            data = await resp.json()
            end = time.time()
            return {
                "num": query_num,
                "ok": resp.status == 200,
                "start": start_dt.strftime("%H:%M:%S.%f")[:-3],
                "duration_ms": int((end - start) * 1000),
                "worker_ms": data.get("metadata", {}).get("timing", {}).get("total_ms", 0)
            }
    except Exception as e:
        return {"num": query_num, "ok": False, "error": str(e)[:50]}

async def test_hybrid(session, query_num):
    """Single hybrid search request (no Groq)"""
    start = time.time()
    start_dt = datetime.now()
    try:
        async with session.post(
            f"{WORKER_URL}/hybrid",
            json={"query": "resume", "user_id": "test", "limit": 5},
            headers={"X-API-Key": "Infosys0712!", "Content-Type": "application/json"},
            timeout=aiohttp.ClientTimeout(total=60)
        ) as resp:
            data = await resp.json()
            end = time.time()
            return {
                "num": query_num,
                "ok": resp.status == 200,
                "start": start_dt.strftime("%H:%M:%S.%f")[:-3],
                "duration_ms": int((end - start) * 1000),
                "worker_ms": data.get("timing", {}).get("total_ms", 0)
            }
    except Exception as e:
        return {"num": query_num, "ok": False, "error": str(e)[:50]}

async def run_concurrent_test(count, endpoint="hybrid"):
    """Run N concurrent requests"""
    connector = aiohttp.TCPConnector(limit=count, limit_per_host=count)
    async with aiohttp.ClientSession(connector=connector) as session:
        print(f"\n{'='*60}")
        print(f"  {count} CONCURRENT to /{endpoint}")
        print(f"{'='*60}")
        
        global_start = time.time()
        start_dt = datetime.now()
        
        if endpoint == "hybrid":
            tasks = [test_hybrid(session, i+1) for i in range(count)]
        else:
            tasks = [test_rag_search(session, i+1) for i in range(count)]
        
        print(f"All {count} launched at: {start_dt.strftime('%H:%M:%S.%f')[:-3]}")
        
        results = await asyncio.gather(*tasks)
        
        global_end = time.time()
        total_ms = int((global_end - global_start) * 1000)
        
        # Analyze results
        ok_results = [r for r in results if r.get("ok")]
        failed = [r for r in results if not r.get("ok")]
        
        print(f"\nRESULTS:")
        print(f"  Total time:  {total_ms}ms")
        print(f"  Success:     {len(ok_results)}/{count}")
        print(f"  Failed:      {len(failed)}")
        
        if ok_results:
            durations = [r["duration_ms"] for r in ok_results]
            worker_times = [r.get("worker_ms", 0) for r in ok_results if r.get("worker_ms")]
            
            print(f"\nCLIENT TIMING:")
            print(f"  Min: {min(durations)}ms | Max: {max(durations)}ms | Avg: {sum(durations)//len(durations)}ms")
            
            if worker_times:
                print(f"\nWORKER TIMING:")
                print(f"  Min: {min(worker_times)}ms | Max: {max(worker_times)}ms | Avg: {sum(worker_times)//len(worker_times)}ms")
            
            # Check start time spread
            starts = sorted([r["start"] for r in ok_results])
            print(f"\nSTART TIME ANALYSIS:")
            print(f"  First start: {starts[0]}")
            print(f"  Last start:  {starts[-1]}")
            
            # Calculate parallelism factor
            theoretical_sequential = sum(durations)
            factor = theoretical_sequential / total_ms if total_ms > 0 else 0
            print(f"\nPARALLELISM:")
            print(f"  Theoretical sequential: {theoretical_sequential}ms")
            print(f"  Actual total:           {total_ms}ms")
            print(f"  Parallelism factor:     {factor:.1f}x")
            
            if factor > 0.8 * count:
                print(f"  ✅ HIGHLY PARALLEL")
            elif factor > 0.5 * count:
                print(f"  ✅ PARALLEL")
            elif factor > 2:
                print(f"  ⚠️  PARTIALLY PARALLEL")
            else:
                print(f"  ❌ SEQUENTIAL")
        
        if failed:
            print(f"\nFAILED REQUESTS:")
            for f in failed[:5]:
                print(f"  #{f['num']}: {f.get('error', 'unknown')}")
        
        return results

async def main():
    print("="*60)
    print("  WORKER PARALLELISM TEST")
    print("="*60)
    
    # Test /hybrid (no Groq) with various concurrency levels
    await run_concurrent_test(10, "hybrid")
    await run_concurrent_test(50, "hybrid")
    await run_concurrent_test(100, "hybrid")
    
    # Test /rag-search-auth (with Groq) - smaller counts
    await run_concurrent_test(10, "rag-search-auth")
    await run_concurrent_test(20, "rag-search-auth")

if __name__ == "__main__":
    asyncio.run(main())
