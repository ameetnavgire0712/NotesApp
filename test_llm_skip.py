"""Test the LLM skip optimization"""
import asyncio
import time
from app.services.rag_agent import get_rag_agent_service


async def test():
    agent = get_rag_agent_service()
    
    print("=" * 60)
    print("LLM SKIP OPTIMIZATION TEST")
    print("=" * 60)
    
    # Test 1: Simple tag query
    print("\n--- Test 1: Simple Tag Query ---")
    start = time.time()
    result = await agent.search("show ananda cv", user_id="default_user", max_results=5)
    elapsed = time.time() - start
    
    print(f"Query: show ananda cv")
    print(f"Total time: {elapsed:.2f}s")
    print(f"Documents: {len(result.documents)}")
    print(f"Iterations used: {result.metadata.get('iterations_used', 'N/A')}")
    print(f"Reasoning: {result.metadata.get('reasoning', 'N/A')}")
    print("Agent steps:")
    for step in result.agent_steps:
        print(f"  [{step.step_number}] {step.action} - {step.tool_name} ({step.duration_ms}ms)")
    
    # Test 2: Temporal tag query
    print("\n--- Test 2: Temporal Query with Tag ---")
    start = time.time()
    result = await agent.search("show me the latest document from ananda cv tag", user_id="default_user", max_results=5)
    elapsed = time.time() - start
    
    print(f"Query: show me the latest document from ananda cv tag")
    print(f"Total time: {elapsed:.2f}s")
    print(f"Documents: {len(result.documents)}")
    print(f"Iterations used: {result.metadata.get('iterations_used', 'N/A')}")
    print(f"Temporal sort: {result.metadata.get('analysis', {}).get('temporal_sort', 'N/A')}")
    print(f"Limit to one: {result.metadata.get('analysis', {}).get('limit_to_one', 'N/A')}")
    print("Agent steps:")
    for step in result.agent_steps:
        print(f"  [{step.step_number}] {step.action} - {step.tool_name} ({step.duration_ms}ms)")
    
    # Test 3: Query requiring synthesis (should NOT skip LLM)
    print("\n--- Test 3: Query Requiring Synthesis (should use LLM) ---")
    start = time.time()
    result = await agent.search("what skills does ananda cv have?", user_id="default_user", max_results=5)
    elapsed = time.time() - start
    
    print(f"Query: what skills does ananda cv have?")
    print(f"Total time: {elapsed:.2f}s")
    print(f"Documents: {len(result.documents)}")
    print(f"Iterations used: {result.metadata.get('iterations_used', 'N/A')}")
    print(f"Needs synthesis: {result.metadata.get('analysis', {}).get('needs_synthesis', 'N/A')}")
    print("Agent steps:")
    for step in result.agent_steps:
        print(f"  [{step.step_number}] {step.action} - {step.tool_name} ({step.duration_ms}ms)")
    
    print("\n" + "=" * 60)
    print("TEST COMPLETE")
    print("=" * 60)


if __name__ == "__main__":
    asyncio.run(test())
