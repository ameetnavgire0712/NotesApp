"""Test RAG agent with temporal queries"""
import asyncio
import os
from dotenv import load_dotenv

load_dotenv()

from app.services.rag_agent import get_rag_agent_service

async def test_rag_temporal():
    svc = get_rag_agent_service()
    
    print("=" * 60)
    print("Testing RAG Agent with Temporal Query")
    print("=" * 60)
    
    query = "get me my latest CV"
    print(f"\nQuery: '{query}'")
    print("-" * 40)
    
    result = await svc.search(query=query, user_id="default_user", max_results=5)
    
    print(f"\nAnalysis:")
    analysis = result.metadata.get("analysis", {})
    print(f"  temporal_sort: {analysis.get('temporal_sort', 'N/A')}")
    print(f"  limit_to_one: {analysis.get('limit_to_one', 'N/A')}")
    print(f"  intent: {analysis.get('intent', 'N/A')}")
    
    print(f"\nDocuments returned: {len(result.documents)}")
    for i, doc in enumerate(result.documents):
        metadata = doc.get("metadata", {})
        created_at = metadata.get("created_at", "N/A")
        print(f"  {i+1}. {doc['title']} (created: {created_at})")
    
    print(f"\nReasoning: {result.metadata.get('reasoning', 'N/A')}")
    print(f"Total duration: {result.total_duration_ms}ms")
    
    # Expected: Only 1 document if limit_to_one is True
    if analysis.get('limit_to_one') and len(result.documents) > 1:
        print("\n⚠️  WARNING: limit_to_one is True but more than 1 document returned!")
    elif analysis.get('limit_to_one') and len(result.documents) == 1:
        print("\n✅ SUCCESS: Correctly returned only 1 document for temporal query!")
    
if __name__ == "__main__":
    asyncio.run(test_rag_temporal())
