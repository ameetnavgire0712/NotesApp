"""Test if reranking is working"""
import asyncio
from app.services.retrieval_tools import get_retrieval_tools_service

async def test():
    tools = get_retrieval_tools_service()
    
    # Force reranker to load
    reranker = tools._get_reranker()
    print(f"Reranker loaded: {reranker is not None}")
    
    results = await tools.hybrid_search(
        query="whats the name on my aadhaar card",
        user_id="default_user",
        limit=5,
        rerank=True
    )
    
    print(f"Results count: {len(results)}")
    for i, r in enumerate(results):
        print(f"  {i+1}. {r.title[:50]}...")
        print(f"      source={r.source}")
        if r.metadata and "rerank_score" in r.metadata:
            score = r.metadata["rerank_score"]
            print(f"      rerank_score={score:.3f}")

asyncio.run(test())
