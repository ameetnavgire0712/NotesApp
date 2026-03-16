"""
Migration Script: Re-embed all documents with local BGE model

This script:
1. Fetches all documents from Supabase
2. Regenerates embeddings using local BGE model (768 dimensions)
3. Updates the embeddings in the database
4. Also regenerates chunk embeddings

Usage:
    python scripts/migrate_to_local_embeddings.py

Note: The Supabase table needs to be updated to support 768 dimensions
(or you need to run the alter_embedding_dimensions.sql migration first)
"""
import asyncio
import logging
import time
import sys
import os

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.core.config import get_settings
from app.services.local_embeddings import get_local_embeddings_service
from supabase import create_client

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


async def migrate_embeddings():
    """Migrate all document embeddings from OpenAI (1536d) to BGE (768d)"""
    
    settings = get_settings()
    supabase = create_client(settings.supabase_url, settings.supabase_service_key)
    embeddings_service = get_local_embeddings_service()
    
    logger.info("=" * 60)
    logger.info("Starting embedding migration: OpenAI (1536d) → BGE (768d)")
    logger.info("=" * 60)
    
    # Step 1: Fetch all notes
    logger.info("\n📥 Fetching all notes from database...")
    result = supabase.table("notes").select(
        "id, title, content_markdown, tag"
    ).execute()
    
    notes = result.data
    logger.info(f"Found {len(notes)} notes to process")
    
    if not notes:
        logger.info("No notes found. Nothing to migrate.")
        return
    
    # Step 2: Process each note
    success_count = 0
    error_count = 0
    start_time = time.time()
    
    for i, note in enumerate(notes):
        note_id = note["id"]
        title = note.get("title", "Untitled")
        content = note.get("content_markdown", "")
        
        logger.info(f"\n[{i+1}/{len(notes)}] Processing: {title[:50]}...")
        
        try:
            note_start = time.time()
            
            # Generate new embeddings using local model
            result = await embeddings_service.process_document(
                markdown_content=content,
                title=title
            )
            
            doc_embedding = result["document_embedding"]
            chunks = result["chunks"]
            chunk_embeddings = result["chunk_embeddings"]
            
            # Update note embedding
            supabase.table("notes").update({
                "embedding": doc_embedding
            }).eq("id", note_id).execute()
            
            # Delete old chunks
            supabase.table("note_chunks").delete().eq("note_id", note_id).execute()
            
            # Insert new chunks with new embeddings
            for idx, (chunk, chunk_emb) in enumerate(zip(chunks, chunk_embeddings)):
                supabase.table("note_chunks").insert({
                    "note_id": note_id,
                    "chunk_index": idx,
                    "content": chunk,
                    "embedding": chunk_emb
                }).execute()
            
            elapsed = time.time() - note_start
            logger.info(f"   ✅ Done in {elapsed:.2f}s - {len(chunks)} chunks")
            success_count += 1
            
        except Exception as e:
            logger.error(f"   ❌ Error: {str(e)}")
            error_count += 1
    
    # Summary
    total_time = time.time() - start_time
    logger.info("\n" + "=" * 60)
    logger.info("Migration Complete!")
    logger.info("=" * 60)
    logger.info(f"Total notes processed: {len(notes)}")
    logger.info(f"Successful: {success_count}")
    logger.info(f"Errors: {error_count}")
    logger.info(f"Total time: {total_time:.1f}s")
    logger.info(f"Average time per note: {total_time/len(notes):.2f}s")


async def verify_dimensions():
    """Verify the new embedding dimensions"""
    settings = get_settings()
    supabase = create_client(settings.supabase_url, settings.supabase_service_key)
    
    # Check a sample note
    result = supabase.table("notes").select("id, title, embedding").limit(1).execute()
    
    if result.data:
        note = result.data[0]
        embedding = note.get("embedding", [])
        logger.info(f"\nVerification:")
        logger.info(f"Note: {note['title'][:50]}")
        logger.info(f"Embedding dimensions: {len(embedding)}")
        logger.info(f"Expected: 768 (BGE-base)")
        
        if len(embedding) == 768:
            logger.info("✅ Dimensions correct!")
        else:
            logger.warning(f"⚠️ Unexpected dimensions: {len(embedding)}")


if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("EMBEDDING MIGRATION: OpenAI → Local BGE")
    print("=" * 60)
    print("\n⚠️  WARNING: This will re-embed ALL documents!")
    print("    Make sure you have updated the database schema to support 768 dimensions.")
    print("\n    Run this SQL in Supabase first:")
    print("    ALTER TABLE notes ALTER COLUMN embedding TYPE vector(768);")
    print("    ALTER TABLE note_chunks ALTER COLUMN embedding TYPE vector(768);")
    print("")
    
    response = input("Continue? (yes/no): ").strip().lower()
    
    if response == "yes":
        asyncio.run(migrate_embeddings())
        asyncio.run(verify_dimensions())
    else:
        print("Migration cancelled.")
