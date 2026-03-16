"""
Reindex all documents to store full chunk content in Vectorize.

Previously, content was truncated to 1000 chars. This script:
1. Fetches all note_chunks from Supabase
2. Re-upserts to Cloudflare Vectorize with full content

Usage:
    python scripts/reindex_full_content.py [--dry-run] [--user-id UUID]
"""

import asyncio
import os
import sys
import json
import argparse
import httpx
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY")
WORKER_URL = os.getenv("VECTORIZE_WORKER_URL", "https://notesapp-vector-search.monocle0712.workers.dev")
WORKER_API_KEY = os.getenv("VECTORIZE_WORKER_API_KEY", "Infosys0712!")

# Batch size for upserts (Vectorize limit is 1000)
BATCH_SIZE = 100


async def fetch_all_chunks(user_id: str = None) -> list:
    """Fetch all note_chunks with their embeddings from Supabase."""
    
    headers = {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/json"
    }
    
    # Build query - join with notes to get title, tag
    # note_chunks has: id, note_id, chunk_index, content, embedding
    # notes has: id, title, tag, user_id, file_type, blob_url
    
    async with httpx.AsyncClient(timeout=60.0) as client:
        all_chunks = []
        offset = 0
        limit = 1000
        
        while True:
            # Fetch chunks with note metadata
            query = f"{SUPABASE_URL}/rest/v1/note_chunks?select=id,note_id,chunk_index,content,embedding,notes(title,tag,user_id,file_type,blob_url)"
            
            if user_id:
                query += f"&notes.user_id=eq.{user_id}"
            
            query += f"&offset={offset}&limit={limit}&order=note_id,chunk_index"
            
            response = await client.get(query, headers=headers)
            
            if response.status_code != 200:
                print(f"Error fetching chunks: {response.status_code} - {response.text}")
                break
            
            chunks = response.json()
            if not chunks:
                break
            
            # Filter out chunks where notes is None (shouldn't happen but safety check)
            valid_chunks = [c for c in chunks if c.get("notes")]
            all_chunks.extend(valid_chunks)
            
            print(f"  Fetched {len(valid_chunks)} chunks (offset={offset})")
            
            if len(chunks) < limit:
                break
            
            offset += limit
        
        return all_chunks


async def upsert_to_vectorize(vectors: list, dry_run: bool = False) -> dict:
    """Upsert vectors to Cloudflare Vectorize via Worker."""
    
    if dry_run:
        print(f"  [DRY RUN] Would upsert {len(vectors)} vectors")
        return {"success": True, "count": len(vectors)}
    
    headers = {
        "Content-Type": "application/json",
        "X-API-Key": WORKER_API_KEY
    }
    
    async with httpx.AsyncClient(timeout=120.0) as client:
        response = await client.post(
            f"{WORKER_URL}/upsert",
            headers=headers,
            json={"vectors": vectors}
        )
        
        if response.status_code != 200:
            print(f"  Error upserting: {response.status_code} - {response.text[:500]}")
            return {"success": False, "error": response.text}
        
        return response.json()


async def reindex(dry_run: bool = False, user_id: str = None):
    """Main reindex function."""
    
    print("=" * 60)
    print("REINDEX FULL CONTENT TO VECTORIZE")
    print("=" * 60)
    
    if dry_run:
        print("🔍 DRY RUN MODE - No changes will be made")
    
    if user_id:
        print(f"📌 Filtering by user_id: {user_id}")
    
    print()
    
    # Step 1: Fetch all chunks
    print("Step 1: Fetching chunks from Supabase...")
    chunks = await fetch_all_chunks(user_id)
    print(f"  ✓ Found {len(chunks)} chunks total")
    print()
    
    if not chunks:
        print("No chunks to reindex!")
        return
    
    # Step 2: Prepare vectors for upsert
    print("Step 2: Preparing vectors...")
    
    vectors = []
    skipped = 0
    
    for chunk in chunks:
        notes_data = chunk.get("notes", {})
        
        # Skip if no embedding
        embedding = chunk.get("embedding")
        if not embedding:
            skipped += 1
            continue
        
        # Parse embedding if it's a string (Supabase returns vector as JSON string)
        if isinstance(embedding, str):
            try:
                embedding = json.loads(embedding)
            except json.JSONDecodeError:
                print(f"  Warning: Could not parse embedding for chunk {chunk['id']}")
                skipped += 1
                continue
        
        # Validate embedding dimensions
        if not isinstance(embedding, list) or len(embedding) != 768:
            print(f"  Warning: Invalid embedding dimensions for chunk {chunk['id']}: {len(embedding) if isinstance(embedding, list) else 'not a list'}")
            skipped += 1
            continue
        
        # Get content length for stats
        content = chunk.get("content", "")
        
        vectors.append({
            "id": chunk["id"],  # chunk_id
            "values": embedding,
            "metadata": {
                "note_id": chunk["note_id"],
                "chunk_index": chunk.get("chunk_index", 0),
                "content": content,  # FULL content, not truncated!
                "title": notes_data.get("title", ""),
                "tag": notes_data.get("tag", ""),
                "file_type": notes_data.get("file_type", ""),
                "blob_url": notes_data.get("blob_url", ""),
                "user_id": notes_data.get("user_id", "")
            }
        })
    
    print(f"  ✓ Prepared {len(vectors)} vectors ({skipped} skipped - no embedding)")
    
    # Content length stats
    content_lengths = [len(v["metadata"]["content"]) for v in vectors]
    if content_lengths:
        avg_len = sum(content_lengths) / len(content_lengths)
        max_len = max(content_lengths)
        min_len = min(content_lengths)
        print(f"  📊 Content length: min={min_len}, avg={avg_len:.0f}, max={max_len} chars")
    print()
    
    # Step 3: Upsert in batches
    print(f"Step 3: Upserting to Vectorize (batch size={BATCH_SIZE})...")
    
    total_upserted = 0
    total_failed = 0
    
    for i in range(0, len(vectors), BATCH_SIZE):
        batch = vectors[i:i + BATCH_SIZE]
        batch_num = i // BATCH_SIZE + 1
        total_batches = (len(vectors) + BATCH_SIZE - 1) // BATCH_SIZE
        
        print(f"  Batch {batch_num}/{total_batches}: {len(batch)} vectors...", end=" ")
        
        result = await upsert_to_vectorize(batch, dry_run)
        
        if result.get("success"):
            total_upserted += result.get("count", len(batch))
            print("✓")
        else:
            total_failed += len(batch)
            print("✗")
        
        # Small delay between batches to avoid rate limiting
        if not dry_run and i + BATCH_SIZE < len(vectors):
            await asyncio.sleep(0.5)
    
    print()
    print("=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  Total chunks:    {len(chunks)}")
    print(f"  Vectors upserted: {total_upserted}")
    print(f"  Vectors failed:   {total_failed}")
    print(f"  Skipped (no emb): {skipped}")
    
    if dry_run:
        print()
        print("🔍 This was a DRY RUN. Run without --dry-run to apply changes.")
    else:
        print()
        print("✅ Reindex complete! Full content now stored in Vectorize.")


def main():
    parser = argparse.ArgumentParser(description="Reindex documents with full content to Vectorize")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be done without making changes")
    parser.add_argument("--user-id", type=str, help="Only reindex for a specific user")
    
    args = parser.parse_args()
    
    # Validate environment
    if not SUPABASE_URL or not SUPABASE_SERVICE_KEY:
        print("Error: SUPABASE_URL and SUPABASE_SERVICE_KEY must be set")
        sys.exit(1)
    
    asyncio.run(reindex(dry_run=args.dry_run, user_id=args.user_id))


if __name__ == "__main__":
    main()
