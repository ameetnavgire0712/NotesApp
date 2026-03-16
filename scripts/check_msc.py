"""Check if Amit CVs contain MSC Software and test hybrid search"""
from supabase import create_client
from app.core.config import get_settings
import numpy as np

settings = get_settings()
client = create_client(settings.supabase_url, settings.supabase_service_key)

# Get a sample embedding to test
from app.services.local_embeddings import get_local_embeddings_service
import asyncio

async def test():
    embeddings = get_local_embeddings_service()
    query_emb = await embeddings.generate_embedding("msc software", is_query=True)
    
    print(f"Embedding dimensions: {len(query_emb)}")
    
    # Test the hybrid search RPC directly
    result = client.rpc(
        "hybrid_search_notes",
        {
            "query_embedding": query_emb,
            "query_text": "msc software",
            "match_limit": 20,
            "match_user_id": "default_user",
            "match_tag": None,
            "vector_weight": 0.7,
            "text_weight": 0.3
        }
    ).execute()
    
    print(f"\nHybrid search returned {len(result.data)} results:")
    for r in result.data:
        print(f"  {r['id'][:8]}: combined={r.get('combined_score', 0):.4f}, vector={r.get('vector_similarity', 0):.4f}, text={r.get('text_rank', 0):.4f}")

asyncio.run(test())
