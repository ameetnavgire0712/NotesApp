"""Test direct search without RAG agent"""
import asyncio
import os
from dotenv import load_dotenv

load_dotenv()

from app.services.retrieval_tools import get_retrieval_tools_service

async def test_direct_search():
    svc = get_retrieval_tools_service()
    
    print("=" * 60)
    print("Testing Direct Vector Search for CV")
    print("=" * 60)
    
    query = "CV resume"
    print(f"\nQuery: '{query}'")
    print("-" * 40)
    
    results = await svc.vector_search(
        query=query,
        user_id="default_user",
        limit=5
    )
    
    print(f"\nResults: {len(results)}")
    for i, r in enumerate(results):
        created_at = r.metadata.get("created_at", "N/A") if r.metadata else "N/A"
        print(f"  {i+1}. {r.title} (score: {r.similarity_score:.3f}, created: {created_at})")
    
if __name__ == "__main__":
    asyncio.run(test_direct_search())
