"""
Search and Retrieval API endpoints
Handles semantic search and note retrieval
"""
import time
import logging
import hmac
import hashlib
from fastapi import APIRouter, HTTPException, Query, Depends
from fastapi.responses import RedirectResponse
from typing import Optional, List

from app.models.schemas import (
    SearchRequest,
    SearchResponse,
    NoteSearchResult,
    NoteResponse,
    TagsResponse,
    NotesListResponse,
    NoteListItem,
    UserStatsResponse
)
from app.services.embeddings import get_embeddings_service
from app.services.notes_db import get_notes_db_service
from app.services.blob_storage import get_blob_service
from app.core.log_decorators import log_activity
from app.core.dependencies import get_current_user, require_read_scope, require_write_scope
from app.services.auth_service import AuthenticatedUser
from app.core.config import get_settings

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/notes", tags=["Notes"])

# =============================================================================
# View Token Helpers (for browser-clickable secure links)
# =============================================================================

def generate_view_token(note_id: str, user_id: str, expiry_minutes: int = 5) -> str:
    """Generate a signed token for document viewing.
    
    Token format: {note_id}:{user_id}:{expiry_timestamp}:{signature}
    """
    settings = get_settings()
    expiry_ts = int(time.time()) + (expiry_minutes * 60)
    
    # Create message to sign
    message = f"{note_id}:{user_id}:{expiry_ts}"
    
    # Sign with JWT secret
    secret = settings.supabase_jwt_secret or settings.supabase_service_key
    signature = hmac.new(
        secret.encode(),
        message.encode(),
        hashlib.sha256
    ).hexdigest()[:16]  # Short signature is fine for short-lived tokens
    
    return f"{message}:{signature}"


def verify_view_token(token: str, note_id: str) -> Optional[str]:
    """Verify a view token and return the user_id if valid.
    
    Returns None if token is invalid or expired.
    """
    try:
        settings = get_settings()
        parts = token.split(":")
        if len(parts) != 4:
            return None
        
        token_note_id, user_id, expiry_ts, provided_sig = parts
        
        # Verify note_id matches
        if token_note_id != note_id:
            return None
        
        # Verify not expired
        if int(expiry_ts) < int(time.time()):
            logger.warning(f"View token expired for note {note_id[:8]}...")
            return None
        
        # Verify signature
        message = f"{token_note_id}:{user_id}:{expiry_ts}"
        secret = settings.supabase_jwt_secret or settings.supabase_service_key
        expected_sig = hmac.new(
            secret.encode(),
            message.encode(),
            hashlib.sha256
        ).hexdigest()[:16]
        
        if not hmac.compare_digest(provided_sig, expected_sig):
            logger.warning(f"Invalid view token signature for note {note_id[:8]}...")
            return None
        
        return user_id
        
    except Exception as e:
        logger.error(f"View token verification error: {e}")
        return None


@router.post("/search", response_model=SearchResponse)
@log_activity(
    action="search_notes",
    resource_type="note",
    extract_metadata=lambda args, r: {
        "query": args.get("request", {}).query if hasattr(args.get("request", {}), "query") else None,
        "total_results": r.total_results if hasattr(r, 'total_results') else 0
    }
)
async def search_notes(
    request: SearchRequest,
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Search notes using natural language query
    
    Uses semantic similarity to find relevant notes.
    Set `deep_search=true` to also search within document chunks for more precise results.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    try:
        embeddings_service = get_embeddings_service()
        notes_db_service = get_notes_db_service()
        
        # Generate embedding for the search query
        query_embedding = await embeddings_service.generate_embedding(request.query)
        
        # Search notes (document-level)
        note_results = await notes_db_service.search_notes(
            query_embedding=query_embedding,
            user_id=current_user.user_id,
            tag=request.tag,
            limit=request.limit
        )
        
        # Convert to response format
        results = [
            NoteSearchResult(
                id=r["id"],
                title=r.get("title"),
                content_markdown=r.get("content_markdown"),
                tag=r.get("tag"),
                file_type=r.get("file_type"),
                blob_url=r.get("blob_url"),
                similarity=r.get("similarity", 0)
            )
            for r in note_results
        ]
        
        return SearchResponse(
            query=request.query,
            results=results,
            total_results=len(results)
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Search failed: {str(e)}")


@router.get("/search", response_model=SearchResponse)
@log_activity(
    action="search_notes_get",
    resource_type="note",
    extract_metadata=lambda args, r: {
        "query": args.get("query"),
        "total_results": r.total_results if hasattr(r, 'total_results') else 0
    }
)
async def search_notes_get(
    query: str = Query(..., description="Natural language search query"),
    tag: Optional[str] = Query(None, description="Filter by tag"),
    limit: int = Query(5, ge=1, le=20, description="Maximum results"),
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Search notes using GET request (convenience endpoint)
    
    For chunk-level search with synthesis, use the /rag-search endpoint on the Worker.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    request = SearchRequest(query=query, tag=tag, limit=limit)
    return await search_notes(request, current_user)


@router.get("/stats")
@log_activity(
    action="get_stats",
    resource_type="stats",
    extract_metadata=lambda args, r: {"total_notes": r.get("total_notes", 0) if isinstance(r, dict) else 0}
)
async def get_user_stats(
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Get user statistics (note count, chunk count, etc.)
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    try:
        notes_db_service = get_notes_db_service()
        
        # Get notes count using correct method name
        notes = await notes_db_service.get_notes_by_user(current_user.user_id, limit=1000)
        total_notes = len(notes)
        
        # Get total chunks count from notes
        total_chunks = sum(note.get('chunk_count', 0) for note in notes)
        
        return {
            "total_notes": total_notes,
            "total_chunks": total_chunks,
            "total_searches": 0  # TODO: Track searches in logging_service
        }
        
    except Exception as e:
        logger.error(f"Failed to get stats: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get stats: {str(e)}")


@router.get("/{note_id}", response_model=NoteResponse)
@log_activity(
    action="get_note",
    resource_type="note",
    extract_resource_id=lambda r: r.id if hasattr(r, 'id') else None
)
async def get_note(
    note_id: str,
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Get a specific note by ID
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    try:
        notes_db_service = get_notes_db_service()
        
        note = await notes_db_service.get_note_by_id(note_id, current_user.user_id)
        
        if not note:
            raise HTTPException(status_code=404, detail="Note not found")
        
        return NoteResponse(**note)
        
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get note: {str(e)}")


@router.get("/{note_id}/view")
async def view_document(
    note_id: str,
    token: Optional[str] = Query(None, description="Signed view token (allows unauthenticated access)")
):
    """
    Secure document viewer - redirects to a short-lived signed Azure URL.
    
    This endpoint supports two authentication methods:
    1. **Signed Token** (for clickable links): Pass `?token=...` query parameter
    2. **Header Auth**: Pass Bearer token or X-API-Key header
    
    The MCP server generates signed tokens that are valid for 5 minutes.
    """
    start_time = time.time()
    user_id = None
    
    try:
        notes_db_service = get_notes_db_service()
        blob_service = get_blob_service()
        
        # Try token-based auth first (for browser clicks)
        if token:
            user_id = verify_view_token(token, note_id)
            if not user_id:
                raise HTTPException(status_code=401, detail="Invalid or expired view token")
        else:
            # No token - require header-based auth
            raise HTTPException(
                status_code=401, 
                detail="View token required. Use the link provided by the MCP server."
            )
        
        # Get the note (user_id verified from token)
        note = await notes_db_service.get_note_by_id(note_id, user_id)
        
        if not note:
            raise HTTPException(status_code=404, detail="Note not found")
        
        # Get blob name from the blob_url or metadata
        blob_url = note.get("blob_url")
        blob_name = note.get("metadata", {}).get("blob_name") if note.get("metadata") else None
        
        if not blob_name and blob_url:
            # Extract blob_name from URL: https://account.blob.../container/user/type/file.pdf
            parts = blob_url.split(f"/{blob_service.container_name}/")
            if len(parts) > 1:
                blob_name = parts[1].split("?")[0]  # Remove any existing query params
        
        if not blob_name:
            raise HTTPException(status_code=404, detail="Original file not found")
        
        # Generate short-lived SAS URL (5 minutes)
        sas_url = blob_service.generate_sas_url(blob_name, expiry_minutes=5)
        
        elapsed = (time.time() - start_time) * 1000
        logger.info(f"📄 Document proxy: note={note_id[:8]}... user={user_id[:8]}... ({elapsed:.0f}ms)")
        
        # Redirect to signed URL
        return RedirectResponse(url=sas_url, status_code=302)
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Document proxy error: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to access document: {str(e)}")


@router.get("/{note_id}/view-token")
async def get_view_token(
    note_id: str,
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Generate a signed view token for a document.
    
    The token is valid for 5 minutes and can be used with the /view endpoint.
    This is used by the MCP server to create clickable links.
    
    **Requires authentication** (Bearer token or API key)
    """
    try:
        notes_db_service = get_notes_db_service()
        
        # Verify user owns this note
        note = await notes_db_service.get_note_by_id(note_id, current_user.user_id)
        
        if not note:
            raise HTTPException(status_code=404, detail="Note not found")
        
        # Generate token with 60-minute expiry (longer for chat context)
        token = generate_view_token(note_id, current_user.user_id, expiry_minutes=60)
        
        # Get API base URL for full view URL
        settings = get_settings()
        api_base_url = settings.api_base_url or "https://notesapp-search.fly.dev"
        view_url = f"{api_base_url}/api/v1/notes/{note_id}/view?token={token}"
        
        return {
            "view_url": view_url,
            "token": token,
            "expires_in_minutes": 60
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"View token generation error: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to generate view token: {str(e)}")


@router.get("/{note_id}/download-url")
@log_activity(
    action="get_download_url",
    resource_type="note",
    extract_metadata=lambda args, r: {"expiry_hours": args.get("expiry_hours", 1)}
)
async def get_download_url(
    note_id: str,
    expiry_hours: int = Query(1, ge=1, le=24),
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Get a temporary download URL for the original file
    
    Returns a SAS URL that expires after the specified hours.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    try:
        notes_db_service = get_notes_db_service()
        blob_service = get_blob_service()
        
        note = await notes_db_service.get_note_by_id(note_id, current_user.user_id)
        
        if not note:
            raise HTTPException(status_code=404, detail="Note not found")
        
        # Get blob name from metadata
        blob_name = note.get("metadata", {}).get("blob_name")
        
        if not blob_name:
            raise HTTPException(status_code=404, detail="Original file not found")
        
        # Generate SAS URL
        sas_url = blob_service.generate_sas_url(blob_name, expiry_hours)
        
        return {
            "note_id": note_id,
            "download_url": sas_url,
            "expires_in_hours": expiry_hours
        }
        
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to generate URL: {str(e)}")


@router.get("/", response_model=List[NoteResponse])
@log_activity(
    action="list_notes",
    resource_type="note",
    extract_metadata=lambda args, r: {"count": len(r) if r else 0, "tag": args.get("tag"), "file_type": args.get("file_type")}
)
async def list_notes(
    tag: Optional[str] = Query(None, description="Filter by tag"),
    file_type: Optional[str] = Query(None, description="Filter by file type"),
    limit: int = Query(50, ge=1, le=100),
    offset: int = Query(0, ge=0),
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    List all notes with optional filters
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    try:
        notes_db_service = get_notes_db_service()
        
        notes = await notes_db_service.get_notes_by_user(
            user_id=current_user.user_id,
            tag=tag,
            file_type=file_type,
            limit=limit,
            offset=offset
        )
        
        return [NoteResponse(**note) for note in notes]
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list notes: {str(e)}")


@router.get("/tags/all", response_model=TagsResponse)
@log_activity(
    action="list_tags",
    resource_type="tag",
    extract_metadata=lambda args, r: {"count": r.count if hasattr(r, 'count') else 0}
)
async def list_tags(
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Get all unique tags for the user
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    try:
        notes_db_service = get_notes_db_service()
        
        tags = await notes_db_service.get_all_tags(current_user.user_id)
        
        return TagsResponse(tags=tags, count=len(tags))
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get tags: {str(e)}")


@router.delete("/{note_id}")
@log_activity(
    action="delete_note",
    resource_type="note",
    extract_metadata=lambda args, r: {"note_id": args.get("note_id")}
)
async def delete_note(
    note_id: str,
    current_user: AuthenticatedUser = Depends(require_write_scope)
):
    """
    Delete a note and its chunks
    
    **Requires authentication** (Bearer token or API key with 'write' scope)
    """
    try:
        notes_db_service = get_notes_db_service()
        blob_service = get_blob_service()
        
        # Get note first to get blob name
        note = await notes_db_service.get_note_by_id(note_id, current_user.user_id)
        
        if not note:
            raise HTTPException(status_code=404, detail="Note not found")
        
        # Delete from database (chunks cascade)
        await notes_db_service.delete_note(note_id, current_user.user_id)
        
        # Try to delete blob (non-critical if fails)
        blob_name = note.get("metadata", {}).get("blob_name")
        if blob_name:
            await blob_service.delete_blob(blob_name)
        
        # Invalidate search cache for this user (so deleted doc no longer appears)
        try:
            from app.services.vectorize_worker_service import get_vectorize_worker_service
            worker_service = get_vectorize_worker_service()
            await worker_service.invalidate_user_cache(current_user.user_id, cache_type="search")
        except Exception as cache_err:
            # Non-critical, just log warning
            import logging
            logging.getLogger(__name__).warning(f"Cache invalidation failed: {cache_err}")
        
        return {"success": True, "message": "Note deleted successfully"}
        
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to delete note: {str(e)}")


# =============================================================================
# Keywords Endpoint (for Chrome Extension Cache Sync)
# =============================================================================

from pydantic import BaseModel
from datetime import datetime
from typing import Dict

class KeywordsResponse(BaseModel):
    """Response for keywords sync"""
    keywords: Dict[str, List[Dict[str, str]]]  # keyword -> [{id, title}]
    total_notes: int
    last_updated: datetime


@router.get("/keywords", response_model=KeywordsResponse)
@log_activity(
    action="get_keywords",
    resource_type="notes",
    extract_metadata=lambda args, r: {
        "keywords_count": len(r.keywords) if hasattr(r, 'keywords') else 0,
        "total_notes": r.total_notes if hasattr(r, 'total_notes') else 0
    }
)
async def get_keywords_index(
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Get keyword index for Chrome Extension local cache.
    
    Returns a mapping of keywords to note IDs and titles for fast
    client-side matching without network calls.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    try:
        notes_db = get_notes_db_service()
        blob_service = get_blob_service()
        
        # Get all notes for user
        notes = await notes_db.get_notes_by_user(user_id=current_user.user_id, limit=1000)
        
        # Build keyword index from titles and tags
        keywords_index: Dict[str, List[Dict[str, str]]] = {}
        
        for note in notes:
            # Generate direct Azure SAS URL (10 years expiry - effectively permanent)
            blob_url = note.get("blob_url")
            view_url = None
            if blob_url and blob_service.container_name in blob_url:
                try:
                    blob_name = blob_url.split(f"{blob_service.container_name}/")[-1].split("?")[0]
                    view_url = blob_service.generate_sas_url(blob_name, expiry_years=10)
                except Exception:
                    view_url = blob_url  # Fallback to original URL
            else:
                view_url = blob_url
            
            note_ref = {"id": note["id"], "title": note.get("title") or "Untitled", "url": view_url}
            
            # Extract keywords from title
            title = note.get("title") or ""
            words = title.lower().split()
            
            # Filter stop words and short words
            stop_words = {"the", "a", "an", "is", "are", "was", "were", "of", "for", "to", "in", "on", "at", "by", "with", "and", "or", "-", "–", "|"}
            keywords = [w.strip(".,!?():;\"'") for w in words if len(w) > 2 and w not in stop_words]
            
            # Add tag as keyword
            if note.get("tag"):
                keywords.append(note["tag"].lower())
            
            # Add to index
            for kw in set(keywords):
                if kw:
                    if kw not in keywords_index:
                        keywords_index[kw] = []
                    # Avoid duplicates
                    if not any(n["id"] == note_ref["id"] for n in keywords_index[kw]):
                        keywords_index[kw].append(note_ref)
        
        return KeywordsResponse(
            keywords=keywords_index,
            total_notes=len(notes),
            last_updated=datetime.utcnow()
        )
        
    except Exception as e:
        logger.error(f"Failed to get keywords index: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get keywords: {str(e)}")


# =============================================================================
# Notes List Endpoint (for dashboard)
# =============================================================================

@router.get("/list")
async def list_notes(
    page: int = Query(1, ge=1, description="Page number"),
    page_size: int = Query(20, ge=1, le=100, description="Items per page"),
    tag: Optional[str] = Query(None, description="Filter by tag"),
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    List all notes for the authenticated user.
    
    Returns notes sorted by created_at descending (newest first).
    Includes clickable view URLs for each note.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    import traceback
    try:
        logger.info(f"list_notes called for user: {current_user.user_id}")
        notes_db_service = get_notes_db_service()
        logger.info("Got notes_db_service")
        
        # Build query - simplified without blob service first
        query = notes_db_service.client.table("notes")\
            .select("id, title, tag, file_type, created_at, blob_url")\
            .eq("user_id", current_user.user_id)\
            .order("created_at", desc=True)
        
        logger.info("Built query")
        
        # Apply tag filter if provided
        if tag:
            query = query.eq("tag", tag)
        
        # Get total count first
        count_result = notes_db_service.client.table("notes")\
            .select("id", count="exact")\
            .eq("user_id", current_user.user_id)
        
        if tag:
            count_result = count_result.eq("tag", tag)
        
        count_data = count_result.execute()
        total = count_data.count if count_data.count is not None else len(count_data.data)
        logger.info(f"Total notes: {total}")
        
        # Apply pagination
        offset = (page - 1) * page_size
        query = query.range(offset, offset + page_size - 1)
        
        result = query.execute()
        notes = result.data or []
        logger.info(f"Fetched {len(notes)} notes")
        
        # Generate view URLs for each note - simplified
        note_items = []
        for note in notes:
            # Just use the blob_url directly for now
            view_url = note.get("blob_url")
            
            note_items.append(NoteListItem(
                id=note["id"],
                title=note.get("title"),
                tag=note.get("tag"),
                file_type=note.get("file_type"),
                created_at=note.get("created_at"),
                view_url=view_url
            ))
        
        logger.info(f"Built {len(note_items)} note items")
        
        has_more = (offset + len(notes)) < total
        
        response = NotesListResponse(
            notes=note_items,
            total=total,
            page=page,
            page_size=page_size,
            has_more=has_more
        )
        logger.info(f"Built response successfully")
        return response
        
    except Exception as e:
        import traceback
        logger.error(f"Failed to list notes: {e}\n{traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=f"Failed to list notes: {str(e)}")


@router.get("/stats", response_model=UserStatsResponse)
async def get_user_stats(
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Get statistics for the authenticated user.
    
    Returns total notes count, API keys count, and API call count for today.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    try:
        notes_db_service = get_notes_db_service()
        
        # Get notes count
        notes_result = notes_db_service.client.table("notes")\
            .select("id", count="exact")\
            .eq("user_id", current_user.user_id)\
            .execute()
        
        total_notes = notes_result.count if notes_result.count is not None else len(notes_result.data)
        
        # Get API keys count
        keys_result = notes_db_service.client.table("user_api_keys")\
            .select("id", count="exact")\
            .eq("user_id", current_user.user_id)\
            .eq("is_active", True)\
            .execute()
        
        total_api_keys = keys_result.count if keys_result.count is not None else len(keys_result.data)
        
        # Get API calls today from activity_logs
        from datetime import datetime, timezone
        today_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
        
        try:
            logs_result = notes_db_service.client.table("activity_logs")\
                .select("id", count="exact")\
                .eq("user_id", current_user.user_id)\
                .gte("created_at", today_start.isoformat())\
                .execute()
            
            api_calls_today = logs_result.count if logs_result.count is not None else len(logs_result.data)
        except Exception:
            # activity_logs table might not exist
            api_calls_today = 0
        
        # Get last activity
        try:
            last_log = notes_db_service.client.table("activity_logs")\
                .select("created_at")\
                .eq("user_id", current_user.user_id)\
                .order("created_at", desc=True)\
                .limit(1)\
                .execute()
            
            last_activity = last_log.data[0]["created_at"] if last_log.data else None
        except Exception:
            last_activity = None
        
        return UserStatsResponse(
            total_notes=total_notes,
            total_api_keys=total_api_keys,
            api_calls_today=api_calls_today,
            last_activity=last_activity
        )
        
    except Exception as e:
        logger.error(f"Failed to get user stats: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get stats: {str(e)}")

