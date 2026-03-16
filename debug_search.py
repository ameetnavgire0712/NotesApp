"""Debug hybrid search with reranking using full content"""
import asyncio

async def test():
    from app.services.retrieval_tools import get_retrieval_tools_service
    
    tools = get_retrieval_tools_service()
    user_id = "default_user"
    
    # Test with different query phrasings
    queries = [
        "name on aadhar card",
        "what is my aadhaar name",
        "aadhaar card name",
        "identification document name"
    ]
    
    for query in queries:
        print(f"\n{'=' * 70}")
        print(f"Query: {query}")
        print("=" * 70)
        
        results = await tools.hybrid_search(
            query=query,
            user_id=user_id,
            limit=3,
            rerank=True
        )
        
        for i, r in enumerate(results):
            rerank = r.metadata.get('rerank_score', 'N/A')
            print(f"  {i+1}. {r.title[:55]}... (rerank={rerank:.2f})" if isinstance(rerank, float) else f"  {i+1}. {r.title[:55]}...")

if __name__ == "__main__":
    asyncio.run(test())
