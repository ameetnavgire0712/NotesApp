"""
Pydantic schemas for request/response models
"""
from typing import Optional, List, Literal
from pydantic import BaseModel, Field
from datetime import datetime


# =============================================================================
# Request Schemas
# =============================================================================

class QuickNoteRequest(BaseModel):
    """Request for creating a quick text note"""
    content: str = Field(..., description="The text content of the note")
    title: Optional[str] = Field(None, description="Optional title for the note")
    tag: Optional[str] = Field(None, description="Category/tag for the note")


class SearchRequest(BaseModel):
    """Request for searching notes"""
    query: str = Field(..., description="Natural language search query")
    tag: Optional[str] = Field(None, description="Filter by tag")
    limit: int = Field(5, ge=1, le=20, description="Maximum number of results")
    # NOTE: deep_search removed - chunk search now uses Vectorize via /rag-search endpoint


# =============================================================================
# Response Schemas
# =============================================================================

class NoteResponse(BaseModel):
    """Response schema for a single note"""
    id: str
    user_id: str
    title: Optional[str]
    content_markdown: Optional[str]
    tag: Optional[str]
    file_type: Literal["screenshot", "quick_note", "uploaded_file"]
    original_filename: Optional[str]
    blob_url: Optional[str]
    created_at: Optional[datetime]
    
    class Config:
        from_attributes = True


class NoteSearchResult(BaseModel):
    """Search result with similarity score"""
    id: str
    title: Optional[str]
    content_markdown: Optional[str]
    tag: Optional[str]
    file_type: Optional[str]
    blob_url: Optional[str]
    similarity: float = Field(..., description="Similarity score (0-1)")


class ChunkSearchResult(BaseModel):
    """Chunk search result with parent note info"""
    chunk_id: str
    note_id: str
    chunk_index: int
    content: str
    title: Optional[str]
    tag: Optional[str]
    blob_url: Optional[str]
    similarity: float


class UploadResponse(BaseModel):
    """Response after successful upload"""
    success: bool
    note_id: Optional[str] = None
    message: str
    blob_url: Optional[str] = None
    chunks_created: int = 0


class SearchResponse(BaseModel):
    """Response for search queries"""
    query: str
    results: List[NoteSearchResult]
    # NOTE: chunk_results removed - use /rag-search endpoint for chunk-level search
    total_results: int


class TagsResponse(BaseModel):
    """Response for listing all tags"""
    tags: List[str]
    count: int


class NoteListItem(BaseModel):
    """A note item for list view"""
    id: str
    title: Optional[str]
    tag: Optional[str]
    file_type: Optional[str]
    created_at: Optional[datetime]
    view_url: Optional[str] = None


class NotesListResponse(BaseModel):
    """Response for listing notes"""
    notes: List[NoteListItem]
    total: int
    page: int
    page_size: int
    has_more: bool


class UserStatsResponse(BaseModel):
    """Response for user statistics"""
    total_notes: int
    total_api_keys: int
    api_calls_today: int
    last_activity: Optional[datetime] = None


class ErrorResponse(BaseModel):
    """Standard error response"""
    success: bool = False
    error: str
    detail: Optional[str] = None
