"""Test if HNSW index is active in Supabase."""

import asyncio
import time
from supabase import create_client
from app.core.config import get_settings
from app.services.local_embeddings import get_local_embeddings_service

async def main():
    settings = get_settings()
    supabase = create_client(settings.supabase_url, settings.supabase_service_key)

    # Generate a test embedding
    embeddings = get_local_embeddings_service()
    query_embedding = await embeddings.generate_embedding('test query')

    # Time a direct chunk search - run multiple times to warm up
    print("Running HNSW index test...")
    print("-" * 40)

    times = []
    for i in range(5):
        start = time.time()
        result = supabase.rpc('search_chunks_with_context', {
            'query_embedding': query_embedding,
            'match_limit': 30,
            'match_user_id': '2649b4d0-c40d-4ab1-ac04-928fe1cf5969',
            'match_tag': None
        }).execute()
        elapsed = (time.time() - start) * 1000
        times.append(elapsed)
        print(f"Run {i+1}: {elapsed:.0f}ms ({len(result.data)} results)")

    avg = sum(times[1:]) / len(times[1:])  # Skip first run (cold start)
    print("-" * 40)
    print(f"Average (excluding cold): {avg:.0f}ms")

    if avg < 100:
        print(">>> HNSW index ACTIVE (fast vector search)")
    elif avg < 300:
        print(">>> HNSW index likely active (network latency included)")
    else:
        print(">>> HNSW index may NOT be active (slow)")

    # Show similarity scores
    if result.data:
        print(f"\nTop 3 similarities:")
        for chunk in result.data[:3]:
            print(f"  {chunk.get('similarity', 'N/A'):.4f}")

if __name__ == "__main__":
    asyncio.run(main())
