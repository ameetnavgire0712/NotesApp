"""Test match_notes RPC with the fixed code"""
import asyncio
from app.services.notes_db import get_notes_db_service
from app.services.embeddings import get_embeddings_service

async def test():
    db = get_notes_db_service()
    emb = get_embeddings_service()
    
    # Generate embedding for 'CV'
    embedding = await emb.generate_embedding('CV', is_query=True)
    
    print("Testing notes_db.search_notes() (should now return created_at):")
    try:
        results = await db.search_notes(
            query_embedding=embedding,
            user_id='default_user',
            tag=None,
            limit=5
        )
        print(f'  Results: {len(results)}')
        for r in results[:5]:
            print(f'    {r["id"][:8]}: created_at={r.get("created_at")}')
    except Exception as e:
        print(f'  Error: {e}')

asyncio.run(test())
