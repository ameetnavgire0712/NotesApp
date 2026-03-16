"""Test temporal detection in query analyzer"""
import asyncio
from app.services.query_analyzer import get_query_analyzer_service, TemporalSort

async def test_temporal_detection():
    svc = get_query_analyzer_service()
    
    # Test cases
    test_queries = [
        "get me my latest CV",
        "show me the newest document",
        "find the most recent invoice",
        "get my oldest notes",
        "find the earliest report",
        "show me all CVs",  # No temporal
        "get me my first resume",  # oldest
    ]
    
    print("=" * 60)
    print("Testing Temporal Detection")
    print("=" * 60)
    
    for query in test_queries:
        result = await svc.analyze_query(query, [])
        print(f"\nQuery: '{query}'")
        print(f"  temporal_sort: {result.temporal_sort.value}")
        print(f"  limit_to_one: {result.limit_to_one}")
        print(f"  keywords: {result.keywords}")

if __name__ == "__main__":
    asyncio.run(test_temporal_detection())
