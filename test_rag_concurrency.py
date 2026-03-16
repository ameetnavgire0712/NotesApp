"""
RAG Search Concurrency Test
Tests the /api/v1/search endpoint with concurrent requests
"""
import asyncio
import aiohttp
import time
import random
import statistics
from dataclasses import dataclass
from typing import List

# Configuration
BASE_URL = "https://notesapp-gateway.monocle0712.workers.dev"
API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

# Test queries - varied to avoid caching effects
TEST_QUERIES = [
    "ai marketing strategy",
    "machine learning deployment",
    "data pipeline architecture",
    "resume tips",
    "python best practices",
    "cloud infrastructure",
    "api design patterns",
    "database optimization",
    "security compliance",
    "project management",
    "cognee ai github",
    "rag search flow",
    "vector embeddings",
    "kubernetes deployment",
    "azure functions",
    "authentication flow",
    "caching strategies",
    "error handling",
    "logging best practices",
    "performance tuning",
    "microservices architecture",
    "devops automation",
    "ci cd pipeline",
    "docker containers",
    "serverless computing",
    "data visualization",
    "natural language processing",
    "recommendation systems",
    "time series analysis",
    "feature engineering",
    "model training",
    "hyperparameter tuning",
    "a b testing",
    "user analytics",
    "business intelligence",
    "data governance",
    "privacy compliance",
    "gdpr requirements",
    "api rate limiting",
    "load balancing",
    "auto scaling",
    "cost optimization",
    "monitoring alerts",
    "incident response",
    "disaster recovery",
    "backup strategies",
    "network security",
    "encryption standards",
    "access control",
    "identity management",
]

@dataclass
class RequestResult:
    query: str
    status_code: int
    duration_ms: float
    results_count: int
    error: str = None
    backend_duration_ms: float = None

async def make_search_request(session: aiohttp.ClientSession, query: str, request_id: int) -> RequestResult:
    """Make a single search request and measure timing"""
    url = f"{BASE_URL}/api/v1/search"
    headers = {
        "X-API-Key": API_KEY,
        "Content-Type": "application/json"
    }
    payload = {
        "query": query,
        "max_results": 5
    }
    
    start_time = time.time()
    try:
        async with session.post(url, json=payload, headers=headers, timeout=aiohttp.ClientTimeout(total=60)) as response:
            duration_ms = (time.time() - start_time) * 1000
            
            if response.status == 200:
                data = await response.json()
                results_count = len(data.get("results", []))
                backend_duration = data.get("duration_ms") or data.get("timing", {}).get("total_ms")
                return RequestResult(
                    query=query,
                    status_code=200,
                    duration_ms=duration_ms,
                    results_count=results_count,
                    backend_duration_ms=backend_duration
                )
            else:
                error_text = await response.text()
                return RequestResult(
                    query=query,
                    status_code=response.status,
                    duration_ms=duration_ms,
                    results_count=0,
                    error=error_text[:200]
                )
    except asyncio.TimeoutError:
        duration_ms = (time.time() - start_time) * 1000
        return RequestResult(
            query=query,
            status_code=0,
            duration_ms=duration_ms,
            results_count=0,
            error="Timeout"
        )
    except Exception as e:
        duration_ms = (time.time() - start_time) * 1000
        return RequestResult(
            query=query,
            status_code=0,
            duration_ms=duration_ms,
            results_count=0,
            error=str(e)[:200]
        )

async def run_concurrent_test(concurrency: int) -> List[RequestResult]:
    """Run concurrent search requests"""
    # Select random queries for this test
    queries = random.sample(TEST_QUERIES, min(concurrency, len(TEST_QUERIES)))
    if concurrency > len(TEST_QUERIES):
        # Repeat queries if we need more than available
        queries = queries * (concurrency // len(TEST_QUERIES) + 1)
        queries = queries[:concurrency]
    
    print(f"\n{'='*60}")
    print(f"🚀 Starting {concurrency} concurrent requests...")
    print(f"{'='*60}")
    
    connector = aiohttp.TCPConnector(limit=concurrency + 10)
    async with aiohttp.ClientSession(connector=connector) as session:
        start_time = time.time()
        
        tasks = [
            make_search_request(session, query, i)
            for i, query in enumerate(queries)
        ]
        
        results = await asyncio.gather(*tasks)
        
        total_time = time.time() - start_time
    
    return results, total_time

def analyze_results(results: List[RequestResult], total_time: float, concurrency: int):
    """Analyze and print results summary"""
    successful = [r for r in results if r.status_code == 200]
    failed = [r for r in results if r.status_code != 200]
    
    print(f"\n📊 RESULTS SUMMARY ({concurrency} concurrent requests)")
    print(f"{'─'*60}")
    
    # Success/Failure rates
    print(f"✅ Successful: {len(successful)}/{len(results)} ({100*len(successful)/len(results):.1f}%)")
    print(f"❌ Failed: {len(failed)}/{len(results)} ({100*len(failed)/len(results):.1f}%)")
    
    if failed:
        print(f"\n⚠️  Failures:")
        error_counts = {}
        for r in failed:
            key = f"{r.status_code}: {r.error[:50] if r.error else 'Unknown'}"
            error_counts[key] = error_counts.get(key, 0) + 1
        for error, count in error_counts.items():
            print(f"   • {error} (x{count})")
    
    if successful:
        durations = [r.duration_ms for r in successful]
        backend_durations = [r.backend_duration_ms for r in successful if r.backend_duration_ms]
        
        print(f"\n⏱️  Latency (client-side, includes network):")
        print(f"   • Min:    {min(durations):.0f}ms")
        print(f"   • Max:    {max(durations):.0f}ms")
        print(f"   • Mean:   {statistics.mean(durations):.0f}ms")
        print(f"   • Median: {statistics.median(durations):.0f}ms")
        print(f"   • P95:    {sorted(durations)[int(len(durations)*0.95)]:.0f}ms")
        print(f"   • P99:    {sorted(durations)[int(len(durations)*0.99)]:.0f}ms")
        print(f"   • StdDev: {statistics.stdev(durations) if len(durations) > 1 else 0:.0f}ms")
        
        if backend_durations:
            print(f"\n⏱️  Backend Duration (from response):")
            print(f"   • Min:    {min(backend_durations):.0f}ms")
            print(f"   • Max:    {max(backend_durations):.0f}ms")
            print(f"   • Mean:   {statistics.mean(backend_durations):.0f}ms")
            print(f"   • Median: {statistics.median(backend_durations):.0f}ms")
        
        results_counts = [r.results_count for r in successful]
        print(f"\n📄 Results per query:")
        print(f"   • Min: {min(results_counts)}, Max: {max(results_counts)}, Avg: {statistics.mean(results_counts):.1f}")
    
    print(f"\n🏁 Total wall-clock time: {total_time:.2f}s")
    print(f"📈 Throughput: {len(results)/total_time:.1f} req/s")
    print(f"{'='*60}\n")
    
    return {
        "concurrency": concurrency,
        "total_requests": len(results),
        "successful": len(successful),
        "failed": len(failed),
        "success_rate": 100*len(successful)/len(results),
        "mean_latency_ms": statistics.mean([r.duration_ms for r in successful]) if successful else 0,
        "p95_latency_ms": sorted([r.duration_ms for r in successful])[int(len(successful)*0.95)] if successful else 0,
        "throughput_rps": len(results)/total_time,
        "total_time_s": total_time
    }

async def main():
    print("🔬 RAG Search Concurrency Test")
    print(f"   Target: {BASE_URL}/api/v1/search")
    
    all_summaries = []
    
    # Test with 10 concurrent
    results_10, time_10 = await run_concurrent_test(10)
    summary_10 = analyze_results(results_10, time_10, 10)
    all_summaries.append(summary_10)
    
    # Brief pause between tests
    print("⏳ Waiting 5 seconds before next test...")
    await asyncio.sleep(5)
    
    # Test with 20 concurrent (adjusted from 50 due to rate limits)
    results_20, time_20 = await run_concurrent_test(20)
    summary_20 = analyze_results(results_20, time_20, 20)
    all_summaries.append(summary_20)
    
    # Final comparison
    print("\n" + "="*60)
    print("📊 COMPARISON SUMMARY")
    print("="*60)
    print(f"{'Metric':<25} {'10 Concurrent':>15} {'20 Concurrent':>15}")
    print("-"*60)
    print(f"{'Success Rate':<25} {summary_10['success_rate']:>14.1f}% {summary_20['success_rate']:>14.1f}%")
    print(f"{'Mean Latency':<25} {summary_10['mean_latency_ms']:>13.0f}ms {summary_20['mean_latency_ms']:>13.0f}ms")
    print(f"{'P95 Latency':<25} {summary_10['p95_latency_ms']:>13.0f}ms {summary_20['p95_latency_ms']:>13.0f}ms")
    print(f"{'Throughput':<25} {summary_10['throughput_rps']:>12.1f}rps {summary_20['throughput_rps']:>12.1f}rps")
    print(f"{'Total Time':<25} {summary_10['total_time_s']:>14.2f}s {summary_20['total_time_s']:>14.2f}s")
    print("="*60)

if __name__ == "__main__":
    asyncio.run(main())
