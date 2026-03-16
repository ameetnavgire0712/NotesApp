"""
Concurrent search test with detailed timing analysis for specific queries.
"""
import asyncio
import aiohttp
import time
from datetime import datetime

# API configuration
API_URL = "https://notesapp-search.fly.dev/api/v1/search"
API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

# Test queries
QUERIES = [
    "centric consulting",
    "msc software",
    "resume",
    "nitor infotech",
    "bitwise",
    "modality specific chunking",
    "rag",
    "cognee ai memory",
    "cognee",
    "what is redis pricing?",
    "give me my latest resume",
    "different data ingestion techniques",
    "centric job openings",
    "show me the relieving letter",
    "what are different rag chunking methods?",
    "show me the rag search flow",
    "what is redis?",
    "how to sign in to microsoft?",
    "AI marketing strategy",
    "AI logo builder",
    "what is elsa?"
]

async def search_query(session: aiohttp.ClientSession, query: str, query_num: int) -> dict:
    """Execute a single search query and return detailed results."""
    start_time = time.time()
    
    try:
        async with session.post(
            API_URL,
            json={"query": query, "max_results": 5},
            headers={
                "Content-Type": "application/json",
                "X-API-Key": API_KEY
            },
            timeout=aiohttp.ClientTimeout(total=60)
        ) as response:
            elapsed = time.time() - start_time
            
            if response.status == 200:
                data = await response.json()
                answer = data.get("answer") or ""
                return {
                    "query_num": query_num,
                    "query": query,
                    "status": "success",
                    "status_code": 200,
                    "elapsed_ms": round(elapsed * 1000),
                    "answer_preview": (answer[:150] + "...") if len(answer) > 150 else answer,
                    "documents_count": len(data.get("documents", []) or []),
                    "documents": [d.get("title", "Unknown")[:60] for d in (data.get("documents", []) or [])[:3]],
                    "metadata": data.get("metadata", {}),
                    "total_duration_ms": data.get("total_duration_ms", 0),
                    "agent_steps": data.get("agent_steps", []) or []
                }
            else:
                error_text = await response.text()
                return {
                    "query_num": query_num,
                    "query": query,
                    "status": "error",
                    "status_code": response.status,
                    "elapsed_ms": round(elapsed * 1000),
                    "error": error_text[:200]
                }
    except asyncio.TimeoutError:
        return {
            "query_num": query_num,
            "query": query,
            "status": "timeout",
            "elapsed_ms": round((time.time() - start_time) * 1000)
        }
    except Exception as e:
        return {
            "query_num": query_num,
            "query": query,
            "status": "exception",
            "elapsed_ms": round((time.time() - start_time) * 1000),
            "error": str(e)
        }

async def run_concurrent_queries():
    """Run all queries concurrently."""
    print(f"\n{'='*80}")
    print(f"CONCURRENT SEARCH TEST - {len(QUERIES)} queries")
    print(f"Started at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*80}\n")
    
    connector = aiohttp.TCPConnector(limit=30)
    async with aiohttp.ClientSession(connector=connector) as session:
        # Create tasks for all queries
        tasks = [
            search_query(session, query, i+1) 
            for i, query in enumerate(QUERIES)
        ]
        
        # Run all concurrently
        batch_start = time.time()
        results = await asyncio.gather(*tasks)
        batch_elapsed = time.time() - batch_start
        
    # Sort by query number for display
    results.sort(key=lambda x: x["query_num"])
    
    # Print detailed results for each query
    print(f"\n{'='*80}")
    print("DETAILED RESULTS BY QUERY")
    print(f"{'='*80}\n")
    
    for r in results:
        print(f"\n[{r['query_num']:2d}] Query: \"{r['query']}\"")
        print(f"    Status: {r['status'].upper()} | Client Time: {r['elapsed_ms']}ms")
        
        if r['status'] == 'success':
            print(f"    Server Total: {r.get('total_duration_ms', 0)}ms")
            
            # Print agent steps timing
            agent_steps = r.get('agent_steps', [])
            if agent_steps:
                print(f"    Agent Steps ({len(agent_steps)}):")
                for step in agent_steps:
                    tool = step.get('tool_name', 'N/A')
                    duration = step.get('duration_ms', 0)
                    action = step.get('action', 'N/A')[:40]
                    print(f"      Step {step.get('step_number', '?')}: {duration}ms | {tool} | {action}")
            
            # Print metadata timing if available
            metadata = r.get('metadata', {})
            if metadata:
                print(f"    Metadata:")
                for key, value in metadata.items():
                    if isinstance(value, (int, float)):
                        print(f"      - {key}: {value}")
                    elif key == 'timing' and isinstance(value, dict):
                        for tk, tv in value.items():
                            print(f"      - {tk}: {tv}")
            
            print(f"    Documents: {r['documents_count']} found")
            if r['documents']:
                for d in r['documents']:
                    print(f"      - {d}")
            
            print(f"    Answer: {r['answer_preview']}")
        else:
            print(f"    Error: {r.get('error', 'Unknown')}")
    
    # Summary statistics
    print(f"\n{'='*80}")
    print("SUMMARY STATISTICS")
    print(f"{'='*80}\n")
    
    successful = [r for r in results if r['status'] == 'success']
    failed = [r for r in results if r['status'] != 'success']
    
    if successful:
        times = [r['elapsed_ms'] for r in successful]
        print(f"Successful: {len(successful)}/{len(results)}")
        print(f"Failed: {len(failed)}/{len(results)}")
        print(f"Total batch time: {batch_elapsed*1000:.0f}ms")
        print(f"Throughput: {len(results)/batch_elapsed:.2f} queries/sec")
        print(f"\nClient-side timing (successful queries):")
        print(f"  Min: {min(times)}ms")
        print(f"  Max: {max(times)}ms")
        print(f"  Mean: {sum(times)/len(times):.0f}ms")
        print(f"  Median: {sorted(times)[len(times)//2]}ms")
        
        # Aggregate server timing if available
        print(f"\nServer-side timing breakdown (averages):")
        timing_keys = set()
        for r in successful:
            timing_keys.update(r.get('timing', {}).keys())
        
        for key in sorted(timing_keys):
            values = []
            for r in successful:
                v = r.get('timing', {}).get(key)
                if isinstance(v, (int, float)):
                    values.append(v)
            if values:
                print(f"  {key}: avg={sum(values)/len(values):.0f}ms, min={min(values):.0f}ms, max={max(values):.0f}ms")
    
    if failed:
        print(f"\nFailed queries:")
        for r in failed:
            print(f"  [{r['query_num']}] \"{r['query']}\" - {r['status']}: {r.get('error', 'N/A')[:50]}")
    
    # Queries with 0 documents
    no_docs = [r for r in successful if r.get('documents_count', 0) == 0]
    if no_docs:
        print(f"\nQueries with 0 documents ({len(no_docs)}):")
        for r in no_docs:
            print(f"  [{r['query_num']}] \"{r['query']}\"")
    
    # Agent step timing analysis
    print(f"\nAgent Step Analysis:")
    all_steps = []
    for r in successful:
        for step in r.get('agent_steps', []):
            all_steps.append({
                "query": r['query'],
                "tool": step.get('tool_name'),
                "duration": step.get('duration_ms', 0)
            })
    
    # Group by tool
    tool_times = {}
    for s in all_steps:
        tool = s['tool'] or 'unknown'
        if tool not in tool_times:
            tool_times[tool] = []
        tool_times[tool].append(s['duration'])
    
    for tool, times in sorted(tool_times.items()):
        print(f"  {tool}: count={len(times)}, avg={sum(times)/len(times):.0f}ms, max={max(times)}ms")
    
    return results

if __name__ == "__main__":
    asyncio.run(run_concurrent_queries())
