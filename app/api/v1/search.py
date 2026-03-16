"""
Search API endpoints (Phase 2 RAG)
Handles natural language search with agentic retrieval
"""
import time
import asyncio
import logging
from fastapi import APIRouter, HTTPException, Query, Depends, BackgroundTasks
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field
from datetime import datetime
# from groq import Groq  # Removed: trusting reranker instead of LLM filter

from app.services.rag_agent import get_rag_agent_service, SearchResponse as AgentSearchResponse
from app.services.retrieval_tools import get_retrieval_tools_service
from app.services.query_analyzer import get_query_analyzer_service
from app.core.log_decorators import log_activity
from app.core.log_context import current_user_id, current_correlation_id  # Import context variables for logging
from app.core.dependencies import require_read_scope
from app.services.auth_service import AuthenticatedUser
from app.core.config import get_settings
from app.api.v1.notes import generate_view_token

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/search", tags=["Search"])


# =============================================================================
# Request/Response Schemas
# =============================================================================

class RAGSearchRequest(BaseModel):
    """Request for RAG-powered search"""
    query: str = Field(..., min_length=1, max_length=1000, description="Natural language search query")
    max_results: int = Field(10, ge=1, le=50, description="Maximum number of documents to return")


class DocumentResult(BaseModel):
    """Single document in search results"""
    note_id: str
    title: Optional[str]
    content_preview: str
    tag: Optional[str]
    file_type: str
    similarity_score: float
    source: str  # 'vector', 'hybrid', 'chunk', 'tag'
    metadata: Dict[str, Any] = {}


class DownloadURL(BaseModel):
    """Download URL for a document"""
    note_id: str
    title: Optional[str]
    download_url: str
    file_type: str


class AgentStepInfo(BaseModel):
    """Information about a single agent step"""
    step_number: int
    state: str
    action: str
    tool_name: Optional[str]
    thought: str
    duration_ms: int


class RAGSearchResponse(BaseModel):
    """Response from RAG search"""
    query: str
    documents: List[DocumentResult]
    answer: Optional[str] = None
    download_urls: List[DownloadURL]
    metadata: Dict[str, Any]
    agent_steps: List[AgentStepInfo]
    total_duration_ms: int
    
    class Config:
        from_attributes = True


class TagInfo(BaseModel):
    """Tag with document count"""
    tag: str
    count: int


class TagsListResponse(BaseModel):
    """Response for listing all tags"""
    tags: List[TagInfo]
    total: int


class TagMatchResponse(BaseModel):
    """Response for fuzzy tag matching"""
    original_query: str
    matched_tag: Optional[str]
    similarity: float
    is_exact: bool
    candidates: List[Dict[str, Any]]


# =============================================================================
# Endpoints
# =============================================================================

@router.post("", response_model=RAGSearchResponse)
@log_activity(
    action="rag_search",
    resource_type="search",
    extract_metadata=lambda args, r: {
        "query": args.get("request", {}).query if hasattr(args.get("request", {}), "query") else None,
        "documents_count": len(r.documents) if hasattr(r, 'documents') else 0,
        "has_answer": bool(r.answer) if hasattr(r, 'answer') else False,
        "total_duration_ms": r.total_duration_ms if hasattr(r, 'total_duration_ms') else 0
    }
)
async def rag_search(
    request: RAGSearchRequest,
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Search notes using agentic RAG.
    
    Features:
    - Natural language understanding
    - Dynamic search strategy (vector, hybrid, chunk)
    - Fuzzy tag matching
    - Synthesized answers (when query requires)
    - Document download URLs
    
    Documents are ALWAYS returned. Answers are only provided when
    the query explicitly asks a question requiring synthesis.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    # Set user context for centralized logging
    current_user_id.set(current_user.user_id)
    
    try:
        agent = get_rag_agent_service()
        
        result: AgentSearchResponse = await agent.search(
            query=request.query,
            user_id=current_user.user_id,
            max_results=request.max_results
        )
        
        return RAGSearchResponse(
            query=result.query,
            documents=[
                DocumentResult(
                    note_id=d["note_id"],
                    title=d.get("title"),
                    content_preview=d.get("content_preview", ""),
                    tag=d.get("tag"),
                    file_type=d.get("file_type", "unknown"),
                    similarity_score=d.get("similarity_score", 0.0),
                    source=d.get("source", "unknown"),
                    metadata=d.get("metadata", {})
                )
                for d in result.documents
            ],
            answer=result.answer,
            download_urls=[
                DownloadURL(
                    note_id=u["note_id"],
                    title=u.get("title"),
                    download_url=u["download_url"],
                    file_type=u.get("file_type", "unknown")
                )
                for u in result.download_urls
            ],
            metadata=result.metadata,
            agent_steps=[
                AgentStepInfo(
                    step_number=s.step_number,
                    state=s.state.value,
                    action=s.action,
                    tool_name=s.tool_name,
                    thought=s.thought,
                    duration_ms=s.duration_ms
                )
                for s in result.agent_steps
            ],
            total_duration_ms=result.total_duration_ms
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Search failed: {str(e)}")


@router.get("/tags", response_model=TagsListResponse)
@log_activity(
    action="list_tags",
    resource_type="tag",
    extract_metadata=lambda args, r: {"total": r.total if hasattr(r, 'total') else 0}
)
async def list_tags(
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    List all available tags with document counts.
    
    Useful for discovering what categories/tags exist in the system.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    # Set user context for centralized logging
    current_user_id.set(current_user.user_id)
    
    try:
        retrieval_tools = get_retrieval_tools_service()
        tags = await retrieval_tools.get_all_tags(current_user.user_id)
        
        return TagsListResponse(
            tags=[TagInfo(tag=t["tag"], count=t["count"]) for t in tags],
            total=len(tags)
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list tags: {str(e)}")


@router.get("/tags/match", response_model=TagMatchResponse)
@log_activity(
    action="fuzzy_match_tag",
    resource_type="tag",
    extract_metadata=lambda args, r: {
        "query_tag": args.get("query_tag"),
        "matched_tag": r.matched_tag if hasattr(r, 'matched_tag') else None,
        "similarity": r.similarity if hasattr(r, 'similarity') else 0
    }
)
async def fuzzy_match_tag(
    query_tag: str = Query(..., min_length=1, description="Tag to search for"),
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Find the best matching tag using fuzzy string matching.
    
    Useful when user mentions a tag that might not exactly match
    an existing tag name.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    # Set user context for centralized logging
    current_user_id.set(current_user.user_id)
    
    try:
        retrieval_tools = get_retrieval_tools_service()
        result = await retrieval_tools.fuzzy_match_tag(query_tag, current_user.user_id)
        
        return TagMatchResponse(
            original_query=result.original_query,
            matched_tag=result.matched_tag,
            similarity=result.similarity,
            is_exact=result.is_exact,
            candidates=result.all_candidates
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to match tag: {str(e)}")


@router.get("/analyze")
@log_activity(
    action="analyze_query",
    resource_type="query",
    extract_metadata=lambda args, r: {
        "query_length": len(args.get("query", "")),
        "intent": r.get("intent") if isinstance(r, dict) else None,
        "complexity": r.get("complexity") if isinstance(r, dict) else None
    }
)
async def analyze_query(
    query: str = Query(..., min_length=1, description="Query to analyze"),
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Analyze a query without executing search.
    
    Returns intent, complexity, and recommended search strategy.
    Useful for debugging or understanding how the system interprets queries.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    # Set user context for centralized logging
    current_user_id.set(current_user.user_id)
    
    try:
        query_analyzer = get_query_analyzer_service()
        retrieval_tools = get_retrieval_tools_service()
        
        # Get available tags for detection
        tags_result = await retrieval_tools.get_all_tags(current_user.user_id)
        available_tags = [t["tag"] for t in tags_result]
        
        analysis = await query_analyzer.analyze_query(query, available_tags)
        
        return {
            "original_query": analysis.original_query,
            "cleaned_query": analysis.cleaned_query,
            "intent": analysis.intent.value,
            "complexity": analysis.complexity.value,
            "max_iterations": analysis.max_iterations,
            "should_expand": analysis.should_expand,
            "detected_tags": analysis.detected_tags,
            "detected_file_types": analysis.detected_file_types,
            "keywords": analysis.keywords,
            "needs_synthesis": analysis.needs_synthesis,
            "confidence": analysis.confidence
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to analyze query: {str(e)}")


# =============================================================================
# Instant Search (for Chrome Extension)
# =============================================================================

class InstantSearchResult(BaseModel):
    """Single result for instant search"""
    id: str
    title: Optional[str]
    snippet: str
    relevance: float
    url: str
    source: str  # 'keyword' or 'semantic'


class InstantSearchResponse(BaseModel):
    """Response from instant search endpoint"""
    query: str
    results: List[InstantSearchResult]
    search_url: str
    duration_ms: int


# NOTE: LLM filter removed - trusting reranker (Jina rerank-v2 with MIN_RERANK_SCORE=0.5)
# The LLM filter was problematic because:
# 1. It only saw 200 chars - insufficient for relevance judgment
# 2. Reranker already uses cross-encoder with FULL document content
# 3. Added 400-800ms latency for questionable value
# Keeping the code commented for reference if needed later.
#
# async def filter_results_with_llm(
#     query: str, 
#     candidates: List[Dict[str, Any]], 
#     max_results: int = 3
# ) -> List[Dict[str, Any]]:
#     """Use Groq LLM to verify relevance and filter search results."""
#     ... (see git history for full implementation)


async def _store_instant_search_trace(
    correlation_id: str,
    user_id: str,
    query: str,
    timing: Dict[str, Any],
    final_results: List[Dict[str, Any]],
    source: str = "instant_search"
) -> None:
    """
    Update search trace with instant search backend data (fire-and-forget).
    The initial trace is created by the Worker /hybrid endpoint.
    This PATCH adds the backend timing and final results.
    """
    import httpx
    
    try:
        base_url = "https://notesapp-search.fly.dev"
        
        # PATCH to update the existing trace created by Worker
        payload = {
            "correlation_id": correlation_id,
            "backend_metadata": {
                "source": source,
                "final_results_count": len(final_results),
            },
            "timing_fly_ms": timing.get("total_ms", 0),
        }
        
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.patch(
                f"{base_url}/api/v1/logs/search-trace/{correlation_id}",
                json=payload
            )
            if response.status_code != 200:
                logger.warning(f"Failed to update instant search trace: {response.status_code}")
            else:
                logger.debug(f"Instant search trace updated for correlation_id={correlation_id}")
    except Exception as e:
        logger.warning(f"Failed to update instant search trace (fire-and-forget): {e}")


@router.get("/instant", response_model=InstantSearchResponse)
@log_activity(
    action="instant_search",
    resource_type="search",
    extract_metadata=lambda args, r: {
        "query": args.get("q"),
        "results_count": len(r.results) if hasattr(r, 'results') else 0,
        "duration_ms": r.duration_ms if hasattr(r, 'duration_ms') else 0
    }
)
async def instant_search(
    q: str = Query(..., min_length=1, max_length=500, description="Search query"),
    max_results: int = Query(3, ge=1, le=10, description="Maximum results to return"),
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Fast instant search for Chrome Extension integration.
    
    Performs hybrid search (keyword + semantic) and uses LLM to filter
    the most relevant results. Optimized for low latency.
    
    Use this endpoint when monitoring user's Google searches to suggest
    relevant existing notes.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    current_user_id.set(current_user.user_id)
    start_time = time.time()
    timing = {}  # Detailed timing breakdown
    
    try:
        settings = get_settings()
        
        # Track service initialization
        init_start = time.time()
        retrieval_tools = get_retrieval_tools_service()
        from app.services.blob_storage import get_blob_service
        blob_service = get_blob_service()
        timing["init_services_ms"] = int((time.time() - init_start) * 1000)
        
        # Use hybrid search with RERANKING for accurate results
        # Reranker uses cross-encoder (Jina rerank-v2) to compare query vs full document content
        # MIN_RERANK_SCORE = 0.5 threshold filters out irrelevant documents
        # No LLM filter needed - reranker already validated relevance with full content
        hybrid_start = time.time()
        search_results = await retrieval_tools.hybrid_search(
            query=q,
            user_id=current_user.user_id,
            limit=max_results,  # Reranker already filtered, just get what we need
            rerank=True  # Enable cross-encoder reranking for accuracy
        )
        timing["hybrid_search_ms"] = int((time.time() - hybrid_start) * 1000)
        
        logger.info(f"instant_search: hybrid_search took {timing['hybrid_search_ms']}ms, returned {len(search_results)} results")
        
        # Build response - generate direct Azure SAS URLs (10 years expiry)
        url_start = time.time()
        results = []
        for result in search_results:
            # Generate snippet from content
            content = result.content_preview or ""
            snippet = content[:300] + "..." if len(content) > 300 else content
            
            # Generate direct Azure SAS URL
            view_url = None
            if result.blob_url and blob_service.container_name in result.blob_url:
                try:
                    blob_name = result.blob_url.split(f"{blob_service.container_name}/")[-1].split("?")[0]
                    view_url = blob_service.generate_sas_url(blob_name, expiry_years=10)
                except Exception:
                    view_url = result.blob_url  # Fallback to original URL
            else:
                view_url = result.blob_url
            
            results.append(InstantSearchResult(
                id=result.note_id,
                title=result.title,
                snippet=snippet,
                relevance=result.metadata.get("rerank_score", result.similarity_score),
                url=view_url,
                source="hybrid_reranked"
            ))
        timing["generate_urls_ms"] = int((time.time() - url_start) * 1000)
        
        duration_ms = int((time.time() - start_time) * 1000)
        timing["total_ms"] = duration_ms
        
        # Log detailed timing for debugging
        logger.info(f"instant_search timing: {timing}")
        
        # Store search trace (fire-and-forget)
        corr_id = current_correlation_id.get()
        if corr_id:
            trace_results = [
                {
                    "note_id": r.id,
                    "title": r.title,
                    "rerank_score": r.relevance,
                    "source": r.source,
                }
                for r in results
            ]
            asyncio.create_task(_store_instant_search_trace(
                correlation_id=corr_id,
                user_id=current_user.user_id,
                query=q,
                timing=timing,
                final_results=trace_results,
            ))
        
        api_base_url = settings.api_base_url or "http://localhost:8000"
        return InstantSearchResponse(
            query=q,
            results=results,
            search_url=f"{api_base_url}/docs#/Notes",
            duration_ms=duration_ms
        )
        
    except Exception as e:
        logger.error(f"Instant search failed: {e}")
        raise HTTPException(status_code=500, detail=f"Search failed: {str(e)}")


# =============================================================================
# Smart Search (Edge RAG via Worker /rag-search)
# =============================================================================

class SmartSearchResult(BaseModel):
    """Single result from smart search"""
    note_id: str
    title: Optional[str]
    content: str
    tag: Optional[str]
    similarity_score: float
    rerank_score: float
    blob_url: Optional[str]
    view_url: Optional[str]
    url: Optional[str]  # Alias for view_url (Chrome extension compatibility)


class SmartSearchResponse(BaseModel):
    """Response from smart search endpoint"""
    query: str
    query_corrected: Optional[str] = None
    results: List[SmartSearchResult]
    answer: Optional[str] = None
    timing: Dict[str, Any]
    metadata: Dict[str, Any]
    duration_ms: int


class SmartSearchRequest(BaseModel):
    """Request for smart search"""
    query: str = Field(..., min_length=1, max_length=1000, description="Search query")
    max_results: int = Field(5, ge=1, le=20, description="Maximum results")
    spell_check: bool = Field(True, description="Enable spell checking")
    synthesize: bool = Field(False, description="Generate AI answer from results")


@router.get("/smart", response_model=SmartSearchResponse)
@log_activity(
    action="smart_search",
    resource_type="search",
    extract_metadata=lambda args, r: {
        "query": args.get("q"),
        "results_count": len(r.results) if hasattr(r, 'results') else 0,
        "duration_ms": r.duration_ms if hasattr(r, 'duration_ms') else 0,
        "spell_corrected": r.query_corrected is not None if hasattr(r, 'query_corrected') else False,
        "worker_request_id": r.metadata.get("worker_request_id") if hasattr(r, 'metadata') else None
    }
)
async def smart_search_get(
    background_tasks: BackgroundTasks,
    q: str = Query(..., min_length=1, max_length=1000, description="Search query"),
    limit: int = Query(5, ge=1, le=20, alias="max_results", description="Maximum results"),
    spell_check: bool = Query(True, description="Enable spell checking"),
    synthesize: bool = Query(False, description="Generate AI answer from results"),
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Smart Search (GET) - Full RAG pipeline via Cloudflare Worker edge.
    
    Supports GET requests for Chrome Extension compatibility.
    Query parameters: `q`, `limit` (or `max_results`), `spell_check`, `synthesize`
    """
    # Convert to SmartSearchRequest and delegate to POST handler
    request = SmartSearchRequest(
        query=q,
        max_results=limit,
        spell_check=spell_check,
        synthesize=synthesize
    )
    return await _smart_search_impl(request, background_tasks, current_user)


@router.post("/smart", response_model=SmartSearchResponse)
@log_activity(
    action="smart_search",
    resource_type="search",
    extract_metadata=lambda args, r: {
        "query": args.get("request", {}).query if hasattr(args.get("request", {}), "query") else "",
        "results_count": len(r.results) if hasattr(r, 'results') else 0,
        "duration_ms": r.duration_ms if hasattr(r, 'duration_ms') else 0,
        "spell_corrected": r.query_corrected is not None if hasattr(r, 'query_corrected') else False,
        "worker_request_id": r.metadata.get("worker_request_id") if hasattr(r, 'metadata') else None
    }
)
async def smart_search_post(
    request: SmartSearchRequest,
    background_tasks: BackgroundTasks,
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Smart Search (POST) - Full RAG pipeline via Cloudflare Worker edge.
    
    This endpoint proxies to the Worker `/rag-search` which runs entirely
    on Cloudflare's edge network for low latency. It includes:
    
    - **Spell checking**: Corrects typos in your query
    - **Tag detection**: Identifies relevant document tags
    - **Query analysis**: Determines search intent and complexity
    - **Hybrid search**: Combines vector + keyword search
    - **Reranking**: Cross-encoder relevance scoring
    - **LLM verification**: Filters false positives
    - **Synthesis** (optional): AI-generated answer from documents
    
    Ideal for Chrome Extension or any client needing intelligent search.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    return await _smart_search_impl(request, background_tasks, current_user)


async def _smart_search_impl(
    request: SmartSearchRequest,
    background_tasks: BackgroundTasks,
    current_user: AuthenticatedUser
) -> SmartSearchResponse:
    """Internal implementation for smart search (shared by GET and POST handlers)"""
    import httpx
    
    current_user_id.set(current_user.user_id)
    start_time = time.time()
    
    try:
        settings = get_settings()
        
        # Get Worker URL and API key
        worker_url = settings.vectorize_worker_url
        worker_api_key = settings.vectorize_worker_api_key
        
        if not worker_url or not worker_api_key:
            raise HTTPException(
                status_code=503,
                detail="Smart search service not configured"
            )
        
        # Call Worker /rag-search
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{worker_url}/rag-search",
                headers={
                    "Content-Type": "application/json",
                    "X-API-Key": worker_api_key
                },
                json={
                    "query": request.query,
                    "user_id": current_user.user_id,
                    "limit": request.max_results,
                    "spell_check": request.spell_check,
                    "synthesize": request.synthesize
                }
            )
            
            if response.status_code != 200:
                error_detail = response.text[:200] if response.text else "Unknown error"
                logger.error(f"Worker /rag-search failed: {response.status_code} - {error_detail}")
                raise HTTPException(
                    status_code=502,
                    detail=f"Smart search failed: {error_detail}"
                )
            
            worker_response = response.json()
        
        # Transform Worker response to our schema
        results = []
        api_base_url = settings.api_base_url or "https://notesapp-search.fly.dev"
        for r in worker_response.get("results", []):
            # Generate view URL with token (full URL for Chrome extension)
            note_id = r.get("note_id")
            view_url = None
            if note_id:
                view_token = generate_view_token(note_id, current_user.user_id, expiry_minutes=30)
                view_url = f"{api_base_url}/api/v1/notes/{note_id}/view?token={view_token}"
            
            results.append(SmartSearchResult(
                note_id=note_id or "",
                title=r.get("title"),
                content=r.get("content", "")[:500],  # Truncate for response
                tag=r.get("tag"),
                similarity_score=r.get("similarity_score", 0),
                rerank_score=r.get("rerank_score", 0),
                blob_url=r.get("blob_url"),
                view_url=view_url,
                url=view_url  # Chrome extension compatibility
            ))
        
        duration_ms = int((time.time() - start_time) * 1000)
        
        # Store search trace (fire-and-forget) using Worker's request_id
        worker_request_id = worker_response.get("request_id")
        if worker_request_id:
            corr_id = current_correlation_id.get()
            if corr_id:
                background_tasks.add_task(
                    _store_smart_search_trace,
                    correlation_id=corr_id,
                    worker_request_id=worker_request_id,
                    user_id=current_user.user_id,
                    query=request.query,
                    fly_duration_ms=duration_ms,
                    results_count=len(results)
                )
        
        # Extract spell check info from worker metadata
        worker_metadata = worker_response.get("metadata", {})
        spell_check_info = worker_metadata.get("spell_check", {})
        query_corrected = spell_check_info.get("corrected") if spell_check_info.get("was_corrected") else None
        worker_timing = worker_metadata.get("timing", {})
        
        return SmartSearchResponse(
            query=request.query,
            query_corrected=query_corrected,
            results=results,
            answer=worker_response.get("answer"),
            timing=worker_timing,
            metadata={
                "worker_request_id": worker_response.get("request_id"),
                "spell_check_enabled": request.spell_check,
                "spell_check_explanation": spell_check_info.get("explanation"),
                "synthesis_enabled": request.synthesize,
                "analysis": worker_metadata.get("analysis", {}),
                "detected_tags": worker_metadata.get("tags", {}).get("detected", []),
                "source": "worker_rag_search"
            },
            duration_ms=duration_ms
        )
        
    except httpx.TimeoutException:
        logger.error("Smart search timed out")
        raise HTTPException(status_code=504, detail="Smart search timed out")
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Smart search failed: {e}")
        raise HTTPException(status_code=500, detail=f"Smart search failed: {str(e)}")


async def _store_smart_search_trace(
    correlation_id: str,
    worker_request_id: str,
    user_id: str,
    query: str,
    fly_duration_ms: int,
    results_count: int
) -> None:
    """
    Update search trace with smart search backend data (fire-and-forget).
    Links the Fly.io correlation_id to the Worker's trace.
    """
    import httpx
    
    try:
        base_url = "https://notesapp-search.fly.dev"
        
        # PATCH to update the existing trace created by Worker
        payload = {
            "correlation_id": correlation_id,
            "backend_metadata": {
                "source": "smart_search",
                "worker_request_id": worker_request_id,
                "final_results_count": results_count,
            },
            "timing_fly_ms": fly_duration_ms,
        }
        
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.patch(
                f"{base_url}/api/v1/logs/search-trace/{worker_request_id}",
                json=payload
            )
            if response.status_code != 200:
                logger.warning(f"Failed to update smart search trace: {response.status_code}")
            else:
                logger.debug(f"Smart search trace updated for worker_request_id={worker_request_id}")
    except Exception as e:
        logger.warning(f"Failed to update smart search trace (fire-and-forget): {e}")


# =============================================================================
# Keywords Endpoint (for Chrome Extension Cache Sync)
# =============================================================================

class KeywordEntry(BaseModel):
    """Single keyword with associated note IDs"""
    keyword: str
    notes: List[Dict[str, str]]  # [{id, title}]


class KeywordsResponse(BaseModel):
    """Response for keywords sync"""
    keywords: Dict[str, List[Dict[str, str]]]  # keyword -> [{id, title}]
    total_notes: int
    last_updated: datetime


@router.get("/keywords", response_model=KeywordsResponse)
@log_activity(
    action="get_keywords",
    resource_type="search",
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
    current_user_id.set(current_user.user_id)
    
    try:
        from app.services.notes_db import get_notes_db_service
        from app.services.blob_storage import get_blob_service
        notes_db = get_notes_db_service()
        blob_service = get_blob_service()
        
        # Get all notes for user (including blob_url for direct SAS generation)
        result = notes_db.client.table("notes").select(
            "id", "title", "tag", "blob_url"
        ).eq("user_id", current_user.user_id).execute()
        
        notes = result.data or []
        
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
# EXPERIMENTAL: Chunk-Based Vector Search
# =============================================================================

class ExperimentalSearchResult(BaseModel):
    """Single result from experimental chunk-based search"""
    note_id: str
    title: Optional[str]
    content_preview: str
    tag: Optional[str]
    file_type: str
    similarity_score: float
    source: str
    url: Optional[str] = None
    metadata: Dict[str, Any] = {}


class ExperimentalSearchResponse(BaseModel):
    """Response from experimental chunk-based search"""
    query: str
    results: List[ExperimentalSearchResult]
    duration_ms: int
    experiment_info: Dict[str, Any]


@router.get("/experimental/v2-chunks", response_model=ExperimentalSearchResponse)
@log_activity(
    action="experimental_v2_chunks_search",
    resource_type="search",
    extract_metadata=lambda args, r: {
        "query": args.get("q"),
        "results_count": len(r.results) if hasattr(r, 'results') else 0,
        "duration_ms": r.duration_ms if hasattr(r, 'duration_ms') else 0
    }
)
async def experimental_v2_chunks_search(
    q: str = Query(..., min_length=1, max_length=500, description="Search query"),
    max_results: int = Query(5, ge=1, le=20, description="Maximum results to return"),
    rerank: bool = Query(True, description="Whether to use cross-encoder reranking"),
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    **EXPERIMENTAL**: Chunk-based vector search.
    
    This endpoint uses chunk embeddings from Cloudflare Vectorize.
    
    **How it works:**
    1. Searches ALL chunks in Vectorize index
    2. Groups results by note_id (parent document)
    3. Uses the MAX chunk similarity as the document score
    4. Optionally reranks using cross-encoder
    
    **Why this is better:**
    - Regular vector search only embeds first ~400 words
    - This approach searches ALL chunks (500 words each)
    - Can find content buried deep in long documents
    
    **Use this to compare against regular /instant search**
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    current_user_id.set(current_user.user_id)
    start_time = time.time()
    
    try:
        settings = get_settings()
        retrieval_tools = get_retrieval_tools_service()
        from app.services.blob_storage import get_blob_service
        blob_service = get_blob_service()
        
        # Use the experimental chunk-based vector search
        search_results = await retrieval_tools.vector_search_v2_chunks(
            query=q,
            user_id=current_user.user_id,
            limit=max_results,
            rerank=rerank
        )
        
        logger.info(f"[EXPERIMENTAL] v2_chunks_search: returned {len(search_results)} results")
        
        # Build response with direct Azure SAS URLs
        results = []
        for result in search_results:
            # Generate direct Azure SAS URL
            blob_url = result.blob_url
            view_url = None
            if blob_url and blob_service.container_name in blob_url:
                try:
                    blob_name = blob_url.split(f"{blob_service.container_name}/")[-1].split("?")[0]
                    view_url = blob_service.generate_sas_url(blob_name, expiry_years=10)
                except Exception:
                    view_url = blob_url
            else:
                view_url = blob_url
            
            results.append(ExperimentalSearchResult(
                note_id=result.note_id,
                title=result.title,
                content_preview=result.content_preview,
                tag=result.tag,
                file_type=result.file_type,
                similarity_score=result.similarity_score,
                source=result.source,
                url=view_url,
                metadata=result.metadata
            ))
        
        duration_ms = int((time.time() - start_time) * 1000)
        
        return ExperimentalSearchResponse(
            query=q,
            results=results,
            duration_ms=duration_ms,
            experiment_info={
                "method": "chunk-based vector search",
                "description": "Uses chunk embeddings instead of document embedding",
                "rerank_enabled": rerank,
                "chunks_per_doc": "~500 words each with 50 word overlap",
                "comparison": "Compare with /instant endpoint which uses document-level embeddings"
            }
        )
        
    except Exception as e:
        logger.error(f"Experimental v2 chunks search failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Search failed: {str(e)}")


# Temporary debug endpoint for testing (no auth required)
@router.get("/debug/v2-chunks")
async def debug_v2_chunks_search(
    q: str = Query(..., min_length=1, max_length=200, description="Search query"),
    max_results: int = Query(default=5, ge=1, le=20),
    rerank: bool = Query(default=False)
):
    """
    DEBUG ONLY - No auth required.
    Test the chunk-based vector search.
    """
    import time
    start_time = time.time()
    
    try:
        retrieval_tools = get_retrieval_tools_service()
        
        # Use the correct user ID
        TEST_USER_ID = "2649b4d0-c40d-4ab1-ac04-928fe1cf5969"
        current_user_id.set(TEST_USER_ID)
        
        logger.info(f"[DEBUG] v2_chunks_search: query='{q}', rerank={rerank}")
        
        search_results = await retrieval_tools.vector_search_v2_chunks(
            query=q,
            user_id=TEST_USER_ID,
            limit=max_results,
            rerank=rerank
        )
        
        duration_ms = int((time.time() - start_time) * 1000)
        
        # Return simplified results
        return {
            "query": q,
            "duration_ms": duration_ms,
            "result_count": len(search_results),
            "results": [
                {
                    "title": r.title[:60],
                    "score": round(r.similarity_score, 3),
                    "source": r.source,
                    "tag": r.tag
                }
                for r in search_results
            ]
        }
        
    except Exception as e:
        logger.error(f"Debug v2 chunks search failed: {e}", exc_info=True)
        return {"error": str(e)}


# Debug endpoint removed - note_chunks table dropped in favor of Vectorize
# Use /health on Worker to check vector count instead


# =============================================================================
# DETAILED DEBUG SEARCH - Full Flow Trace
# =============================================================================

class SearchStepDetail(BaseModel):
    """Detailed info about one step in the search flow"""
    step_name: str
    duration_ms: int
    input_data: Optional[Dict[str, Any]] = None
    output_data: Optional[Dict[str, Any]] = None
    candidates_count: Optional[int] = None
    error: Optional[str] = None


class VectorSearchCandidate(BaseModel):
    """Single candidate from vector search"""
    note_id: str
    title: str
    tag: Optional[str]
    vector_score: float
    content_preview: str


class KeywordSearchCandidate(BaseModel):
    """Single candidate from keyword search"""
    note_id: str
    title: str
    tag: Optional[str]
    keyword_score: float
    text_rank: float
    content_preview: str


class CombinedCandidate(BaseModel):
    """Candidate after combining vector + keyword scores"""
    note_id: str
    title: str
    tag: Optional[str]
    vector_score: float
    keyword_score: float
    combined_score: float
    content_preview: str
    passed_threshold: bool


class RerankedCandidate(BaseModel):
    """Candidate after reranking"""
    note_id: str
    title: str
    tag: Optional[str]
    original_combined_score: float
    rerank_score: float
    final_rank: int
    passed_threshold: bool
    content_preview: str


class DebugSearchResponse(BaseModel):
    """Complete debug response showing full search flow"""
    query: str
    user_id: str
    correlation_id: str
    total_duration_ms: int
    
    # Step-by-step flow
    steps: List[SearchStepDetail]
    
    # Timing breakdown
    timing: Dict[str, int]
    
    # Intermediate results at each stage
    vector_candidates: List[VectorSearchCandidate]
    keyword_candidates: List[KeywordSearchCandidate]
    combined_candidates: List[CombinedCandidate]
    reranked_candidates: List[RerankedCandidate]
    
    # Final results
    final_results: List[Dict[str, Any]]
    final_count: int
    
    # Thresholds used
    thresholds: Dict[str, float]
    
    # Worker response (raw)
    worker_raw_response: Optional[Dict[str, Any]] = None


@router.get("/debug/trace-search")
async def debug_trace_search(
    q: str = Query(..., min_length=1, max_length=500, description="Search query"),
    max_results: int = Query(5, ge=1, le=20, description="Maximum results"),
    user_id: str = Query("2649b4d0-c40d-4ab1-ac04-928fe1cf5969", description="User ID to search for")
):
    """
    **DEBUG ENDPOINT**: Execute a search and return COMPLETE flow details.
    
    Shows exactly what happens under the hood:
    1. Query analysis & spell check
    2. Embedding generation (timing, cached or not)
    3. Vector search results with scores
    4. Keyword search results with scores
    5. Score combination (vector + keyword)
    6. Threshold filtering
    7. Reranking results with scores
    8. Final filtering
    
    Use this to understand why a query returns (or doesn't return) certain documents.
    
    **PUBLIC ENDPOINT** - No authentication required (for debugging only)
    """
    import uuid
    from app.core.middleware import get_correlation_id
    
    current_user_id.set(user_id)
    correlation_id = str(get_correlation_id() or uuid.uuid4())
    
    start_time = time.time()
    steps = []
    timing = {}
    
    # Initialize containers for intermediate data
    vector_candidates = []
    keyword_candidates = []
    combined_candidates = []
    reranked_candidates = []
    worker_raw = None
    
    try:
        # Step 1: Service initialization
        step_start = time.time()
        from app.services.vectorize_worker_service import get_vectorize_worker_service
        worker_service = get_vectorize_worker_service()
        timing["init_services_ms"] = int((time.time() - step_start) * 1000)
        steps.append(SearchStepDetail(
            step_name="1_init_services",
            duration_ms=timing["init_services_ms"],
            output_data={"services": ["vectorize_worker"]}
        ))
        
        # Step 2: Call Worker /hybrid endpoint with debug=true
        step_start = time.time()
        try:
            worker_result = await worker_service.hybrid_search_debug(
                query=q,
                user_id=user_id,
                tag=None,
                limit=max_results,
                rerank=True,
                rerank_top_k=20
            )
            timing["worker_total_ms"] = int((time.time() - step_start) * 1000)
            worker_raw = worker_result
            
            # Extract timing from worker
            worker_timing = worker_result.get("timing", {})
            timing["worker_embed_ms"] = worker_timing.get("embedding_ms", 0)
            timing["worker_vector_ms"] = worker_timing.get("vectorize_search_ms", worker_timing.get("parallel_search_ms", 0))
            timing["worker_keyword_ms"] = worker_timing.get("keyword_ms", 0)
            timing["worker_combine_ms"] = worker_timing.get("combine_ms", 0)
            timing["worker_rerank_ms"] = worker_timing.get("rerank_ms", 0)
            timing["embedding_cached"] = worker_timing.get("embedding_cached", False)
            
            steps.append(SearchStepDetail(
                step_name="2_worker_hybrid_search",
                duration_ms=timing["worker_total_ms"],
                input_data={"query": q, "user_id": user_id[:8] + "...", "limit": max_results},
                output_data={
                    "embed_ms": timing["worker_embed_ms"],
                    "vector_ms": timing["worker_vector_ms"],
                    "keyword_ms": timing["worker_keyword_ms"],
                    "rerank_ms": timing["worker_rerank_ms"],
                    "embedding_cached": timing["embedding_cached"]
                }
            ))
            
            # Extract intermediate data from worker debug response
            debug_data = worker_result.get("debug", {})
            
            # Vector search candidates
            for v in debug_data.get("vector_candidates", []):
                vector_candidates.append(VectorSearchCandidate(
                    note_id=str(v.get("note_id", "")),
                    title=v.get("title", "")[:60],
                    tag=v.get("tag"),
                    vector_score=round(v.get("similarity", v.get("vector_score", 0)), 4),
                    content_preview=v.get("content", "")[:200]
                ))
            
            # Keyword search candidates
            for k in debug_data.get("keyword_candidates", []):
                keyword_candidates.append(KeywordSearchCandidate(
                    note_id=str(k.get("note_id", "")),
                    title=k.get("title", "")[:60],
                    tag=k.get("tag"),
                    keyword_score=round(k.get("keyword_score", 0), 4),
                    text_rank=round(k.get("text_rank", k.get("keyword_score", 0)), 4),
                    content_preview=k.get("content", "")[:200]
                ))
            
            # Combined candidates (before rerank threshold)
            for c in debug_data.get("combined_candidates", []):
                combined_candidates.append(CombinedCandidate(
                    note_id=str(c.get("note_id", "")),
                    title=c.get("title", "")[:60],
                    tag=c.get("tag"),
                    vector_score=round(c.get("vector_score", c.get("similarity", 0)), 4),
                    keyword_score=round(c.get("keyword_score", 0), 4),
                    combined_score=round(c.get("combined_score", 0), 4),
                    content_preview=c.get("content", "")[:200],
                    passed_threshold=c.get("passed_threshold", True)
                ))
            
            # Reranked candidates
            for i, r in enumerate(debug_data.get("reranked_candidates", [])):
                reranked_candidates.append(RerankedCandidate(
                    note_id=str(r.get("note_id", "")),
                    title=r.get("title", "")[:60],
                    tag=r.get("tag"),
                    original_combined_score=round(r.get("combined_score", 0), 4),
                    rerank_score=round(r.get("rerank_score", 0), 4),
                    final_rank=i + 1,
                    passed_threshold=r.get("passed_rerank_threshold", True),
                    content_preview=r.get("content", "")[:200]
                ))
            
            steps.append(SearchStepDetail(
                step_name="3_extract_debug_data",
                duration_ms=0,
                output_data={
                    "vector_count": len(vector_candidates),
                    "keyword_count": len(keyword_candidates),
                    "combined_count": len(combined_candidates),
                    "reranked_count": len(reranked_candidates)
                }
            ))
            
        except Exception as worker_error:
            timing["worker_total_ms"] = int((time.time() - step_start) * 1000)
            steps.append(SearchStepDetail(
                step_name="2_worker_hybrid_search",
                duration_ms=timing["worker_total_ms"],
                error=str(worker_error)
            ))
            logger.error(f"debug_trace_search: Worker error: {worker_error}")
        
        # Build final results
        final_results = []
        matches = worker_raw.get("matches", []) if worker_raw else []
        for m in matches:
            final_results.append({
                "note_id": str(m.get("note_id", "")),
                "title": m.get("title", ""),
                "tag": m.get("tag"),
                "similarity": round(m.get("similarity", 0), 4),
                "rerank_score": round(m.get("rerank_score", 0), 4),
                "combined_score": round(m.get("combined_score", 0), 4),
                "keyword_score": round(m.get("keyword_score", 0), 4)
            })
        
        total_duration_ms = int((time.time() - start_time) * 1000)
        timing["total_ms"] = total_duration_ms
        
        # Get thresholds from worker response or use defaults
        thresholds = worker_raw.get("thresholds", {}) if worker_raw else {}
        if not thresholds:
            thresholds = {
                "min_combined_score": 0.3,
                "min_rerank_score": 0.5,
                "vector_weight": 0.7,
                "keyword_weight": 0.3
            }
        
        return DebugSearchResponse(
            query=q,
            user_id=user_id,
            correlation_id=correlation_id,
            total_duration_ms=total_duration_ms,
            steps=steps,
            timing=timing,
            vector_candidates=vector_candidates[:20],  # Limit for response size
            keyword_candidates=keyword_candidates[:20],
            combined_candidates=combined_candidates[:20],
            reranked_candidates=reranked_candidates[:20],
            final_results=final_results,
            final_count=len(final_results),
            thresholds=thresholds,
            worker_raw_response=worker_raw
        )
        
    except Exception as e:
        logger.error(f"debug_trace_search failed: {e}", exc_info=True)
        return {
            "error": str(e),
            "query": q,
            "correlation_id": correlation_id,
            "partial_timing": timing,
            "partial_steps": [s.model_dump() for s in steps]
        }
