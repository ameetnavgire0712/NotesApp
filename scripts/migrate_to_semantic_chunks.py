"""
Migration Script: Update Existing Documents with Semantic Chunking

This script re-processes all existing documents in the database using 
Docling's semantic chunker and updates their chunk embeddings.

Usage:
    python scripts/migrate_to_semantic_chunks.py [--dry-run] [--user-id USER_ID] [--limit N]

Options:
    --dry-run       Show what would be processed without making changes
    --user-id       Process only documents for a specific user
    --limit N       Process only N documents (for testing)
    --note-id ID    Process a single specific note
"""
import asyncio
import argparse
import sys
import os
import time
from datetime import datetime

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Set environment variable before imports
os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'

from supabase import create_client
from app.core.config import get_settings
from app.services.semantic_chunker import get_semantic_chunker
from app.services.local_embeddings import get_local_embeddings_service


class SemanticChunkMigration:
    """Migrate existing documents to use semantic chunking"""
    
    def __init__(self, dry_run: bool = False):
        self.dry_run = dry_run
        self.settings = get_settings()
        self.supabase = create_client(
            self.settings.supabase_url,
            self.settings.supabase_service_key
        )
        self.embeddings_service = get_local_embeddings_service()
        self.semantic_chunker = get_semantic_chunker()
        
        # Stats
        self.processed = 0
        self.skipped = 0
        self.errors = 0
        self.total_old_chunks = 0
        self.total_new_chunks = 0
    
    def get_notes(self, user_id: str = None, limit: int = None, note_id: str = None):
        """Fetch notes to process"""
        query = self.supabase.table("notes").select(
            "id, user_id, title, content_markdown, created_at"
        )
        
        if note_id:
            query = query.eq("id", note_id)
        elif user_id:
            query = query.eq("user_id", user_id)
        
        query = query.order("created_at", desc=False)
        
        if limit:
            query = query.limit(limit)
        
        result = query.execute()
        return result.data
    
    def get_existing_chunks(self, note_id: str):
        """Get existing chunks for a note"""
        result = self.supabase.table("note_chunks").select(
            "id, chunk_index"
        ).eq("note_id", note_id).execute()
        return result.data
    
    def delete_existing_chunks(self, note_id: str):
        """Delete existing chunks for a note"""
        if self.dry_run:
            return
        
        self.supabase.table("note_chunks").delete().eq(
            "note_id", note_id
        ).execute()
    
    def insert_new_chunks(self, note_id: str, chunks: list):
        """Insert new chunks with embeddings"""
        if self.dry_run:
            return
        
        for chunk in chunks:
            # Prepare chunk data
            chunk_data = {
                "note_id": note_id,
                "chunk_index": chunk["chunk_index"],
                "content": chunk.get("contextualized_content", chunk["content"]),
                "embedding": chunk["embedding"]
            }
            
            self.supabase.table("note_chunks").insert(chunk_data).execute()
    
    async def process_note(self, note: dict) -> dict:
        """Process a single note with semantic chunking"""
        note_id = note["id"]
        title = note.get("title", "")
        content = note.get("content_markdown", "")
        
        if not content or not content.strip():
            return {"status": "skipped", "reason": "empty content"}
        
        # Get existing chunks count
        existing = self.get_existing_chunks(note_id)
        old_chunk_count = len(existing)
        
        try:
            # Process with semantic chunking
            result = await self.embeddings_service.process_document(
                markdown_content=content,
                title=title,
                use_semantic_chunking=True
            )
            
            new_chunks = result.get("chunks", [])
            new_chunk_count = len(new_chunks)
            chunking_method = result.get("chunking_metadata", {}).get("chunking_method", "unknown")
            
            if not self.dry_run:
                # Delete old chunks
                self.delete_existing_chunks(note_id)
                
                # Insert new chunks
                self.insert_new_chunks(note_id, new_chunks)
                
                # Update document embedding
                doc_embedding = result.get("document_embedding")
                if doc_embedding:
                    self.supabase.table("notes").update({
                        "embedding": doc_embedding
                    }).eq("id", note_id).execute()
            
            return {
                "status": "success",
                "old_chunks": old_chunk_count,
                "new_chunks": new_chunk_count,
                "method": chunking_method
            }
            
        except Exception as e:
            return {
                "status": "error",
                "error": str(e),
                "old_chunks": old_chunk_count
            }
    
    async def run(self, user_id: str = None, limit: int = None, note_id: str = None):
        """Run the migration"""
        print("=" * 70)
        print("SEMANTIC CHUNKING MIGRATION")
        print("=" * 70)
        
        if self.dry_run:
            print("[!] DRY RUN MODE - No changes will be made")
        
        print(f"\nSemantic chunker available: {self.semantic_chunker.is_available}")
        if not self.semantic_chunker.is_available:
            print("[X] Semantic chunker not available. Install docling:")
            print("   pip install docling docling-core[chunking]")
            return
        
        # Warmup
        print("\nWarming up semantic chunker...")
        await self.semantic_chunker.chunk_from_markdown("warmup test", title="Test")
        print("[OK] Semantic chunker ready")
        
        # Fetch notes
        print(f"\nFetching notes...")
        if note_id:
            print(f"  - Specific note: {note_id}")
        elif user_id:
            print(f"  - User filter: {user_id}")
        if limit:
            print(f"  - Limit: {limit}")
        
        notes = self.get_notes(user_id=user_id, limit=limit, note_id=note_id)
        total_notes = len(notes)
        print(f"  - Found {total_notes} notes to process")
        
        if total_notes == 0:
            print("\nNo notes to process.")
            return
        
        # Process each note
        print(f"\nProcessing notes...")
        print("-" * 70)
        
        start_time = time.time()
        
        for i, note in enumerate(notes, 1):
            note_id = note["id"]
            title = note.get("title", "Untitled")[:50]
            
            result = await self.process_note(note)
            status = result["status"]
            
            if status == "success":
                self.processed += 1
                self.total_old_chunks += result["old_chunks"]
                self.total_new_chunks += result["new_chunks"]
                
                print(f"[{i}/{total_notes}] [OK] {title}")
                print(f"           Chunks: {result['old_chunks']} -> {result['new_chunks']} ({result['method']})")
                
            elif status == "skipped":
                self.skipped += 1
                print(f"[{i}/{total_notes}] [SKIP] {title} - {result['reason']}")
                
            else:
                self.errors += 1
                print(f"[{i}/{total_notes}] [ERR] {title}")
                print(f"           Error: {result.get('error', 'Unknown')}")
        
        elapsed = time.time() - start_time
        
        # Summary
        print("\n" + "=" * 70)
        print("MIGRATION SUMMARY")
        print("=" * 70)
        print(f"Mode:           {'DRY RUN' if self.dry_run else 'LIVE'}")
        print(f"Total notes:    {total_notes}")
        print(f"Processed:      {self.processed}")
        print(f"Skipped:        {self.skipped}")
        print(f"Errors:         {self.errors}")
        print(f"Time:           {elapsed:.2f}s")
        print("-" * 70)
        print(f"Old chunks:     {self.total_old_chunks}")
        print(f"New chunks:     {self.total_new_chunks}")
        
        if self.total_old_chunks > 0:
            change = ((self.total_new_chunks - self.total_old_chunks) / self.total_old_chunks) * 100
            print(f"Change:         {change:+.1f}%")
        
        print("=" * 70)
        
        if self.dry_run and self.processed > 0:
            print("\n💡 Run without --dry-run to apply changes")


async def main():
    parser = argparse.ArgumentParser(
        description="Migrate existing documents to semantic chunking"
    )
    parser.add_argument(
        "--dry-run", 
        action="store_true",
        help="Show what would be processed without making changes"
    )
    parser.add_argument(
        "--user-id",
        type=str,
        help="Process only documents for a specific user ID"
    )
    parser.add_argument(
        "--limit",
        type=int,
        help="Limit number of documents to process"
    )
    parser.add_argument(
        "--note-id",
        type=str,
        help="Process a single specific note by ID"
    )
    
    args = parser.parse_args()
    
    migration = SemanticChunkMigration(dry_run=args.dry_run)
    await migration.run(
        user_id=args.user_id,
        limit=args.limit,
        note_id=args.note_id
    )


if __name__ == "__main__":
    asyncio.run(main())
