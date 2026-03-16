"""Quick test to debug PAN card search"""
import asyncio
import os
import sys
sys.path.insert(0, '.')
os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'

from app.services.retrieval_tools import get_retrieval_tools_service

async def test():
    rt = get_retrieval_tools_service()
    
    results = await rt.hybrid_search(
        query='PAN card number',
        user_id='ameet',
        limit=10,
        rerank=True
    )
    print(f'\n=== Found {len(results)} results ===')
    for r in results:
        print(f'  {r.title}: {r.similarity_score:.4f}')

if __name__ == "__main__":
    asyncio.run(test())
