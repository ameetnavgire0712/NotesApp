"""Test full content synthesis with reranking"""
import asyncio
import logging

# Enable INFO level logging only
logging.basicConfig(level=logging.INFO, format='%(name)s - %(levelname)s - %(message)s')
# Suppress noisy loggers
logging.getLogger("httpcore").setLevel(logging.WARNING)
logging.getLogger("groq").setLevel(logging.WARNING)
logging.getLogger("httpx").setLevel(logging.WARNING)

async def test():
    from app.services.rag_agent import get_rag_agent_service
    
    agent = get_rag_agent_service()
    
    # Test the query - use correct user_id
    query = "whats the name on my aadhar card"
    user_id = "default_user"
    
    print(f"Query: {query}")
    print(f"User ID: {user_id}")
    print("=" * 60)
    
    result = await agent.search(query=query, user_id=user_id)
    
    print(f"\nDocuments found: {len(result.documents)}")
    for i, doc in enumerate(result.documents, 1):
        title = doc.get("title", "?")[:60]
        score = doc.get("similarity_score", 0)
        source = doc.get("source", "?")
        rerank = doc.get("metadata", {}).get("rerank_score", "N/A")
        print(f"  {i}. [{source}] {title}")
        print(f"      score={score:.3f}, rerank={rerank}")
    
    print()
    print("ANSWER:")
    print(result.answer if result.answer else "[No answer]")
    
    print()
    print("Agent Steps:")
    for step in result.agent_steps:
        print(f"  {step.step_number}. {step.action} ({step.duration_ms}ms)")

if __name__ == "__main__":
    asyncio.run(test())
