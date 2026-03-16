"""
Notes Database Service
Handles Supabase operations for storing and retrieving notes
"""
import logging
from typing import List, Optional
from supabase import create_client, Client
from app.core.config import get_settings
from app.core.log_decorators import log_operation

logger = logging.getLogger(__name__)


class NotesDBService:
    """Service for Supabase database operations"""
    
    def __init__(self):
        settings = get_settings()
        self.client: Client = create_client(
            settings.supabase_url,
            settings.supabase_service_key
        )
    
    @log_operation(
        service="notes_db",
        operation="create_note",
        extract_input=lambda args, kwargs: {"user_id": kwargs.get("user_id"), "file_type": kwargs.get("file_type"), "has_embedding": bool(kwargs.get("embedding"))},
        extract_output=lambda r: {"note_id": r.get("id") if r else None}
    )
    async def create_note(
        self,
        user_id: str,
        title: Optional[str],
        content_markdown: str,
        tag: Optional[str],
        file_type: str,
        original_filename: Optional[str],
        blob_url: str,
        embedding: List[float],
        metadata: dict = None
    ) -> dict:
        """
        Create a new note in the database
        
        Args:
            user_id: User identifier
            title: Note title
            content_markdown: Markdown content
            tag: User-provided tag/category
            file_type: 'screenshot', 'quick_note', or 'uploaded_file'
            original_filename: Original filename (for uploaded files)
            blob_url: Azure Blob Storage URL
            embedding: Document-level embedding vector
            metadata: Additional metadata (JSONB)
        
        Returns:
            Created note record
        """
        logger.debug(f"notes_db.create_note: user={user_id}, type={file_type}, title='{title[:50] if title else 'None'}...', content_len={len(content_markdown)}")
        
        note_data = {
            "user_id": user_id,
            "title": title,
            "content_markdown": content_markdown,
            "tag": tag,
            "file_type": file_type,
            "original_filename": original_filename,
            "blob_url": blob_url,
            "embedding": embedding,
            "metadata": metadata or {}
        }
        
        result = self.client.table("notes").insert(note_data).execute()
        
        if result.data:
            logger.debug(f"notes_db.create_note: success, note_id={result.data[0].get('id')}")
            return result.data[0]
        logger.error("notes_db.create_note: failed - no data returned")
        raise Exception("Failed to create note")
    
    # NOTE: create_note_chunks removed - chunks are stored only in Cloudflare Vectorize
    # See upload.py for Vectorize upsert logic
    
    async def get_note_by_id(self, note_id: str, user_id: str = "default_user") -> Optional[dict]:
        """Get a note by ID"""
        result = self.client.table("notes").select("*").eq("id", note_id).eq("user_id", user_id).single().execute()
        return result.data
    
    async def get_notes_by_user(
        self,
        user_id: str = "default_user",
        tag: Optional[str] = None,
        file_type: Optional[str] = None,
        limit: int = 50,
        offset: int = 0
    ) -> List[dict]:
        """Get notes for a user with optional filters"""
        query = self.client.table("notes").select("*").eq("user_id", user_id)
        
        if tag:
            query = query.eq("tag", tag)
        if file_type:
            query = query.eq("file_type", file_type)
        
        query = query.order("created_at", desc=True).range(offset, offset + limit - 1)
        
        result = query.execute()
        return result.data or []
    
    @log_operation(
        service="notes_db",
        operation="search_notes",
        extract_input=lambda args, kwargs: {"user_id": kwargs.get("user_id"), "tag": kwargs.get("tag"), "limit": kwargs.get("limit")},
        extract_output=lambda r: {"results_count": len(r) if r else 0}
    )
    async def search_notes(
        self,
        query_embedding: List[float],
        user_id: str = "default_user",
        tag: Optional[str] = None,
        limit: int = 5
    ) -> List[dict]:
        """
        Search notes using vector similarity (document-level)
        
        Args:
            query_embedding: Embedding vector of the search query
            user_id: User identifier
            tag: Optional tag filter
            limit: Maximum number of results
        
        Returns:
            List of matching notes with similarity scores
        """
        logger.debug(f"notes_db.search_notes: user={user_id}, tag={tag}, limit={limit}, embedding_dim={len(query_embedding)}")
        
        result = self.client.rpc(
            "match_notes",
            {
                "query_embedding": query_embedding,
                "match_limit": limit,
                "match_user_id": user_id,
                "match_tag": tag
            }
        ).execute()
        
        logger.debug(f"notes_db.search_notes: returned {len(result.data or [])} results")
        return result.data or []
    
    # NOTE: search_chunks removed - chunk search now uses Cloudflare Vectorize exclusively
    # See retrieval_tools.py _vectorize_chunk_search for vector search implementation
    
    @log_operation(
        service="notes_db",
        operation="delete_note",
        extract_input=lambda args, kwargs: {"note_id": kwargs.get("note_id") or (args[1] if len(args) > 1 else None), "user_id": kwargs.get("user_id") or (args[2] if len(args) > 2 else "default_user")},
        extract_output=lambda r: {"success": r}
    )
    async def delete_note(self, note_id: str, user_id: str = "default_user") -> bool:
        """Delete a note and its chunks (cascade)"""
        logger.debug(f"notes_db.delete_note: note_id={note_id}, user={user_id}")
        try:
            self.client.table("notes").delete().eq("id", note_id).eq("user_id", user_id).execute()
            logger.debug(f"notes_db.delete_note: success")
            return True
        except Exception as e:
            logger.error(f"notes_db.delete_note: failed - {e}")
            return False
    
    async def get_all_tags(self, user_id: str = "default_user") -> List[str]:
        """Get all unique tags for a user"""
        result = self.client.table("notes").select("tag").eq("user_id", user_id).not_.is_("tag", "null").execute()
        
        tags = set()
        for row in result.data or []:
            if row.get("tag"):
                tags.add(row["tag"])
        
        return sorted(list(tags))


# Singleton instance
_notes_db_service = None

def get_notes_db_service() -> NotesDBService:
    global _notes_db_service
    if _notes_db_service is None:
        _notes_db_service = NotesDBService()
    return _notes_db_service


def get_supabase_client() -> Client:
    """Get the Supabase client for direct database operations."""
    return get_notes_db_service().client
