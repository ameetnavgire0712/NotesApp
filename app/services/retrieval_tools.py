"""
Retrieval Tools Service
Provides tools for the RAG agent to search and retrieve documents
"""
import logging
import time
from typing import List, Dict, Any, Optional, Tuple
from dataclasses import dataclass
from difflib import SequenceMatcher
import numpy as np

from app.core.config import get_settings
from app.core.log_decorators import log_operation
from app.services.embeddings import get_embeddings_service
from app.services.notes_db import get_notes_db_service
from app.services.blob_storage import get_blob_service

logger = logging.getLogger(__name__)

# Tags cache per user (user_id -> (tags_list, expiry_time))
_tags_cache: Dict[str, Tuple[List[Dict[str, Any]], float]] = {}
TAGS_CACHE_TTL = 600  # 10 minutes - tags rarely change


@dataclass
class SearchResult:
    """Unified search result format"""
    note_id: str
    title: str
    content_preview: str
    tag: Optional[str]
    file_type: str
    blob_url: str
    similarity_score: float
    source: str  # 'vector', 'hybrid', 'chunk', 'tag'
    metadata: Dict[str, Any]


@dataclass
class TagMatch:
    """Result of fuzzy tag matching"""
    original_query: str
    matched_tag: Optional[str]
    similarity: float
    is_exact: bool
    all_candidates: List[Dict[str, Any]]


class RetrievalToolsService:
    """
    Service providing retrieval tools for the RAG agent.
    Each method is a "tool" that can be called by the agent.
    """
    
    FUZZY_MATCH_THRESHOLD = 0.8  # User confirmed threshold
    DEFAULT_LIMIT = 10
    
    def __init__(self):
        from app.core.config import get_settings
        self.settings = get_settings()
        self.embeddings_service = get_embeddings_service()
        self.notes_db = get_notes_db_service()
        self.blob_service = get_blob_service()
        
        # Lazy load reranker only if enabled
        self._reranker = None
        
        # Lazy load worker service for embeddings
        self._worker_service = None
    
    def _get_worker_service(self):
        """Lazy load worker service for embeddings."""
        if self._worker_service is None and self.settings.use_worker_embeddings:
            from app.services.vectorize_worker_service import get_vectorize_worker_service
            self._worker_service = get_vectorize_worker_service()
        return self._worker_service
    
    async def _generate_query_embedding(self, query: str) -> List[float]:
        """
        Generate embedding for a query, using Worker or local model based on config.
        Worker embeddings scale better for high concurrency.
        """
        worker = self._get_worker_service()
        if worker:
            # Use Cloudflare Workers AI - scales horizontally at edge
            # Add query prefix for better retrieval (BGE best practice)
            query_text = f"Represent this sentence for searching relevant passages: {query}"
            return await worker.embed(query_text)
        else:
            # Use local model - faster for single requests but serializes under GIL
            return await self.embeddings_service.generate_embedding(query, is_query=True)
    
    def _get_reranker(self):
        """Lazy load reranker service"""
        if self._reranker is None and self.settings.use_reranker:
            from app.services.reranker import get_reranker_service
            self._reranker = get_reranker_service()
        return self._reranker
    
    # =========================================================================
    # TAG OPERATIONS
    # =========================================================================
    
    @log_operation(
        service="retrieval_tools",
        operation="get_all_tags",
        extract_input=lambda args, kwargs: {"user_id": kwargs.get("user_id", "default_user")},
        extract_output=lambda r: {"tags_count": len(r) if r else 0}
    )
    async def get_all_tags(self, user_id: str = "default_user") -> List[Dict[str, Any]]:
        """
        Get all unique tags with their document counts.
        Uses in-memory caching to avoid repeated Supabase calls.
        
        Returns:
            List of dicts with 'tag' and 'count' keys
        """
        # Check cache first
        cached = _tags_cache.get(user_id)
        if cached:
            tags, expiry = cached
            if time.time() < expiry:
                logger.debug(f"📦 Tags CACHE HIT for user {user_id[:8]}... ({len(tags)} tags)")
                return tags
            else:
                logger.debug(f"⏰ Tags cache EXPIRED for user {user_id[:8]}...")
                del _tags_cache[user_id]
        
        logger.debug(f"📭 Tags CACHE MISS for user {user_id[:8]}... fetching from Supabase")
        
        try:
            # Try the optimized RPC function first
            result = self.notes_db.client.rpc(
                "get_tags_with_counts",
                {"filter_user_id": user_id}
            ).execute()
            tags = result.data or []
        except Exception as e:
            # Fallback: Use direct SQL query if RPC not available
            logger.warning(f"RPC get_tags_with_counts not available, using fallback: {e}")
            result = self.notes_db.client.table("notes").select("tag").eq("user_id", user_id).not_.is_("tag", "null").execute()
            
            # Count tags manually
            tag_counts = {}
            for row in result.data or []:
                tag = row.get("tag")
                if tag:
                    tag_counts[tag] = tag_counts.get(tag, 0) + 1
            
            tags = [{"tag": tag, "count": count} for tag, count in sorted(tag_counts.items(), key=lambda x: -x[1])]
        
        # Cache the result
        _tags_cache[user_id] = (tags, time.time() + TAGS_CACHE_TTL)
        logger.debug(f"📥 Cached {len(tags)} tags for user {user_id[:8]}...")
        
        return tags
    
    @log_operation(
        service="retrieval_tools",
        operation="fuzzy_match_tag",
        extract_input=lambda args, kwargs: {"query_tag": kwargs.get("query_tag") or (args[1] if len(args) > 1 else None)},
        extract_output=lambda r: {"matched_tag": r.matched_tag if r else None, "similarity": r.similarity if r else 0}
    )
    async def fuzzy_match_tag(
        self,
        query_tag: str,
        user_id: str = "default_user"
    ) -> TagMatch:
        """
        Find the best matching tag using fuzzy string matching.
        
        Args:
            query_tag: The tag query from user
            user_id: User identifier
        
        Returns:
            TagMatch with matched tag and confidence
        """
        all_tags = await self.get_all_tags(user_id)
        
        if not all_tags:
            return TagMatch(
                original_query=query_tag,
                matched_tag=None,
                similarity=0.0,
                is_exact=False,
                all_candidates=[]
            )
        
        query_lower = query_tag.lower().strip()
        candidates = []
        
        for tag_info in all_tags:
            tag = tag_info["tag"]
            tag_lower = tag.lower()
            
            # Exact match
            if tag_lower == query_lower:
                return TagMatch(
                    original_query=query_tag,
                    matched_tag=tag,
                    similarity=1.0,
                    is_exact=True,
                    all_candidates=[{"tag": tag, "similarity": 1.0, "count": tag_info["count"]}]
                )
            
            # Fuzzy similarity
            similarity = SequenceMatcher(None, query_lower, tag_lower).ratio()
            candidates.append({
                "tag": tag,
                "similarity": similarity,
                "count": tag_info["count"]
            })
        
        # Sort by similarity descending
        candidates.sort(key=lambda x: x["similarity"], reverse=True)
        
        # Get best match if above threshold
        best = candidates[0] if candidates else None
        matched_tag = None
        if best and best["similarity"] >= self.FUZZY_MATCH_THRESHOLD:
            matched_tag = best["tag"]
        
        return TagMatch(
            original_query=query_tag,
            matched_tag=matched_tag,
            similarity=best["similarity"] if best else 0.0,
            is_exact=False,
            all_candidates=candidates[:5]  # Top 5 candidates
        )
    
    # =========================================================================
    # VECTOR SEARCH
    # =========================================================================
    
    @log_operation(
        service="retrieval_tools",
        operation="vector_search",
        extract_input=lambda args, kwargs: {"query_length": len(kwargs.get("query", "") or (args[1] if len(args) > 1 else "")), "limit": kwargs.get("limit", 10)},
        extract_output=lambda r: {"results_count": len(r) if r else 0}
    )
    async def vector_search(
        self,
        query: str,
        user_id: str = "default_user",
        tag: Optional[str] = None,
        limit: int = 10,
        rerank: bool = True
    ) -> List[SearchResult]:
        """
        Semantic search using document-level embeddings.
        Optionally reranks results using cross-encoder for better quality.
        
        Args:
            query: Natural language search query
            user_id: User identifier
            tag: Optional tag filter
            limit: Maximum results
            rerank: If True, uses cross-encoder to rerank results
        
        Returns:
            List of SearchResult objects
        """
        logger.debug(f"vector_search: query='{query[:50]}...', tag={tag}, limit={limit}, rerank={rerank}")
        
        # Generate embedding for query - uses Worker or local based on config
        query_embedding = await self._generate_query_embedding(query)
        logger.debug(f"vector_search: embedding generated, dim={len(query_embedding)}")
        
        # Fetch more candidates if reranking (reranker will select best)
        fetch_limit = limit * 3 if rerank and self._get_reranker() else limit
        
        # Search using existing match_notes RPC
        results = await self.notes_db.search_notes(
            query_embedding=query_embedding,
            user_id=user_id,
            tag=tag,
            limit=fetch_limit
        )
        logger.debug(f"vector_search: database returned {len(results)} results")
        
        # Convert to SearchResult objects
        # Keep full content_markdown temporarily for reranking, then truncate for response
        full_contents = {}  # note_id -> full content for reranking
        search_results = []
        for r in results:
            note_id = str(r["id"])
            full_content = r.get("content_markdown", "")
            full_contents[note_id] = full_content  # Store for reranking
            search_results.append(SearchResult(
                note_id=note_id,
                title=r.get("title", "Untitled"),
                content_preview=full_content[:500],
                tag=r.get("tag"),
                file_type=r.get("file_type", "unknown"),
                blob_url=r.get("blob_url", ""),
                similarity_score=r.get("similarity", 0.0),
                source="vector",
                metadata={
                    "original_filename": r.get("original_filename"),
                    "created_at": str(r.get("created_at")) if r.get("created_at") else None
                }
            ))
        
        # Apply reranking if enabled
        reranker = self._get_reranker()
        if rerank and reranker and search_results:
            # Convert to dicts for reranker - use FULL content for better accuracy
            candidates = [
                {
                    "note_id": r.note_id,
                    "title": r.title,
                    "content_preview": r.content_preview,
                    "content_full": full_contents.get(r.note_id, r.content_preview),  # Full content for reranking
                    "tag": r.tag,
                    "file_type": r.file_type,
                    "blob_url": r.blob_url,
                    "similarity_score": r.similarity_score,
                    "source": r.source,
                    "metadata": r.metadata
                }
                for r in search_results
            ]
            
            # Rerank using cross-encoder with FULL content
            reranked = await reranker.rerank(
                query=query,
                candidates=candidates,
                text_field="content_full",  # Use full content for better accuracy
                top_k=limit
            )
            logger.debug(f"vector_search: reranked {len(candidates)} -> {len(reranked)} results")
            
            # Convert back to SearchResult - keep original similarity, add rerank_score to metadata
            search_results = [
                SearchResult(
                    note_id=r["note_id"],
                    title=r["title"],
                    content_preview=r["content_preview"],
                    tag=r["tag"],
                    file_type=r["file_type"],
                    blob_url=r["blob_url"],
                    similarity_score=r["similarity_score"],  # Keep original cosine similarity
                    source="vector_reranked",
                    metadata={
                        **r["metadata"],
                        "rerank_score": r.get("rerank_score", 0.0)  # Store rerank score in metadata
                    }
                )
                for r in reranked
            ]
        
        return search_results[:limit]
    
    @log_operation(
        service="retrieval_tools",
        operation="hybrid_search",
        extract_input=lambda args, kwargs: {"query_length": len(kwargs.get("query", "") or (args[1] if len(args) > 1 else "")), "limit": kwargs.get("limit", 10)},
        extract_output=lambda r: {"results_count": len(r) if r else 0}
    )
    async def hybrid_search(
        self,
        query: str,
        user_id: str = "default_user",
        tag: Optional[str] = None,
        limit: int = 10,
        vector_weight: float = 0.7,
        text_weight: float = 0.3,
        rerank: bool = True
    ) -> List[SearchResult]:
        """
        Hybrid search using Cloudflare Worker /hybrid endpoint.
        
        Worker now handles the complete flow:
        1. Generate embedding (cached)
        2. Vector search (Cloudflare Vectorize)
        3. Keyword search (Supabase FTS - parallel with vector)
        4. Combine scores (vector + keyword with weights)
        5. Apply combined score threshold
        6. Rerank filtered candidates (Voyage AI)
        7. Apply rerank score threshold
        
        Fly.io just receives the final reranked results.
        LLM relevance verification happens at the API layer (rag_agent/instant_search).
        
        Args:
            query: Natural language search query
            user_id: User identifier
            tag: Optional tag filter
            limit: Maximum results
            vector_weight: (Legacy, ignored - Worker uses its own weights)
            text_weight: (Legacy, ignored - Worker uses its own weights)
            rerank: If True, uses cross-encoder to rerank results
        
        Returns:
            List of SearchResult objects
        """
        import asyncio
        start_time = time.time()
        timing = {}
        
        logger.info(f"hybrid_search: query='{query[:50]}...', tag={tag}, limit={limit}, rerank={rerank}")
        
        # Get correlation_id from logging context for trace linking
        from app.core.log_context import current_correlation_id
        current_corr_id = current_correlation_id.get()
        
        # Get worker service for /hybrid endpoint
        from app.services.vectorize_worker_service import get_vectorize_worker_service
        worker_service = get_vectorize_worker_service()
        
        # Call Worker /hybrid - it handles everything now
        try:
            worker_start = time.time()
            worker_result = await worker_service.hybrid_search(
                query=query,
                user_id=user_id,
                tag=tag,
                limit=limit,
                rerank=rerank,
                rerank_top_k=20,  # Rerank top 20 to get best results
                correlation_id=current_corr_id  # Link trace to backend request
            )
            timing["worker_ms"] = int((time.time() - worker_start) * 1000)
            
            # Extract Worker timing info
            worker_timing = worker_result.get("timing", {})
            timing["worker_embed_ms"] = worker_timing.get("embedding_ms", 0)
            timing["worker_parallel_ms"] = worker_timing.get("parallel_search_ms", 0)
            timing["worker_keyword_ms"] = worker_timing.get("keyword_ms", 0)
            timing["worker_combine_ms"] = worker_timing.get("combine_ms", 0)
            timing["worker_rerank_ms"] = worker_timing.get("rerank_ms", 0)
            timing["embedding_cached"] = worker_timing.get("embedding_cached", False)
            
            matches = worker_result.get("matches", [])
            logger.info(f"hybrid_search: Worker returned {len(matches)} results "
                       f"(embed={timing['worker_embed_ms']}ms, parallel={timing['worker_parallel_ms']}ms, "
                       f"keyword={timing['worker_keyword_ms']}ms, rerank={timing['worker_rerank_ms']}ms, "
                       f"cached={timing['embedding_cached']})")
            
        except Exception as e:
            logger.error(f"hybrid_search: Worker /hybrid failed: {e}")
            # Fall back to legacy chunk_search
            logger.info("hybrid_search: falling back to legacy chunk_search")
            return await self.chunk_search(
                query=query,
                user_id=user_id,
                tag=tag,
                limit=limit,
                rerank=rerank,
                similarity_threshold=0.4
            )
        
        # Convert Worker results to SearchResult objects
        results = []
        for m in matches:
            results.append(SearchResult(
                note_id=str(m.get("note_id", "")),
                title=m.get("title", "Untitled"),
                content_preview=m.get("content", "")[:500],
                tag=m.get("tag"),
                file_type=m.get("file_type", "unknown"),
                blob_url=m.get("blob_url", ""),
                similarity_score=m.get("similarity", 0.0),
                source="hybrid_reranked" if rerank else "hybrid_combined",
                metadata={
                    "rerank_score": m.get("rerank_score", 0.0),
                    "combined_score": m.get("combined_score", 0.0),
                    "vector_score": m.get("original_similarity", 0.0),  # Worker returns original_similarity
                    "keyword_score": m.get("keyword_score", 0.0),
                    "chunk_index": m.get("chunk_index", 0)
                }
            ))
        
        # Log top results for debugging
        for i, r in enumerate(results[:5]):
            meta = r.metadata or {}
            logger.info(f"  [{i+1}] rerank={meta.get('rerank_score', 0):.4f} combined={meta.get('combined_score', 0):.4f} "
                       f"vec={meta.get('vector_score', 0):.4f} kw={meta.get('keyword_score', 0):.4f} | '{r.title[:50]}'")
        
        timing["total_ms"] = int((time.time() - start_time) * 1000)
        logger.info(f"hybrid_search complete: {len(results)} results in {timing['total_ms']}ms")
        
        return results[:limit]
    
    # Minimum similarity threshold for chunk search results
    CHUNK_SIMILARITY_THRESHOLD = 0.40
    
    async def _vectorize_chunk_search(
        self,
        query: str,
        user_id: str,
        tag: Optional[str],
        limit: int,
        similarity_threshold: float
    ) -> Tuple[List[Dict[str, Any]], Dict[str, str]]:
        """
        Perform chunk search using Cloudflare Vectorize via Worker.
        Embedding is generated via Worker (scales for high concurrency) or locally.
        Returns (sorted_notes, full_contents) tuple for downstream processing.
        """
        import time
        timing = {}
        
        from app.services.vectorize_worker_service import get_vectorize_worker_service
        
        worker_service = get_vectorize_worker_service()
        
        # Generate embedding - uses Worker or local based on config
        embed_start = time.time()
        query_embedding = await self._generate_query_embedding(query)
        timing["embedding_ms"] = int((time.time() - embed_start) * 1000)
        embed_source = "worker" if self._get_worker_service() else "local"
        logger.info(f"_vectorize_chunk_search: {embed_source} embedding took {timing['embedding_ms']}ms, dim={len(query_embedding)}")
        
        # Search via Worker with pre-computed embedding (skips Workers AI)
        fetch_limit = limit * 5
        
        worker_start = time.time()
        chunks = await worker_service.search(
            embedding=query_embedding,
            user_id=user_id,
            tag=tag,
            limit=fetch_limit * 3
        )
        timing["worker_search_ms"] = int((time.time() - worker_start) * 1000)
        logger.info(f"_vectorize_chunk_search: worker search took {timing['worker_search_ms']}ms, returned {len(chunks)} chunks")
        
        # Group by note_id and keep best chunk per document
        note_best_chunks: Dict[str, Dict[str, Any]] = {}
        
        for chunk in chunks:
            note_id = str(chunk.get("note_id", ""))
            if not note_id:
                continue
            chunk_similarity = chunk.get("similarity", 0.0)
            
            if note_id not in note_best_chunks:
                note_best_chunks[note_id] = {
                    "note_id": note_id,
                    "title": chunk.get("title", "Untitled"),
                    "tag": chunk.get("tag"),
                    "file_type": chunk.get("file_type", "unknown"),
                    "blob_url": chunk.get("blob_url", ""),
                    "best_chunk_content": chunk.get("content", ""),
                    "best_chunk_similarity": chunk_similarity,
                    "best_chunk_index": chunk.get("chunk_index", 0),
                    "all_chunk_scores": [chunk_similarity]
                }
            else:
                existing = note_best_chunks[note_id]
                existing["all_chunk_scores"].append(chunk_similarity)
                if chunk_similarity > existing["best_chunk_similarity"]:
                    existing["best_chunk_similarity"] = chunk_similarity
                    existing["best_chunk_content"] = chunk.get("content", "")
                    existing["best_chunk_index"] = chunk.get("chunk_index", 0)
        
        logger.info(f"_vectorize_chunk_search: grouped into {len(note_best_chunks)} unique documents")
        
        # Apply threshold filter
        filtered_notes = [
            note for note in note_best_chunks.values()
            if note["best_chunk_similarity"] >= similarity_threshold
        ]
        
        logger.debug(f"_vectorize_chunk_search: {len(filtered_notes)}/{len(note_best_chunks)} docs passed threshold ({similarity_threshold})")
        
        # Sort by similarity
        sorted_notes = sorted(
            filtered_notes,
            key=lambda x: x["best_chunk_similarity"],
            reverse=True
        )[:fetch_limit]
        
        # Log top results
        for i, note in enumerate(sorted_notes[:5]):
            logger.debug(f"  [{i+1}] score={note['best_chunk_similarity']:.3f} | {note['title'][:50]}")
        
        # Build full_contents dict for reranking
        full_contents = {
            note["note_id"]: note.get("best_chunk_content", "")
            for note in sorted_notes
        }
        
        return sorted_notes, full_contents
    
    async def _process_chunk_results(
        self,
        sorted_notes: List[Dict[str, Any]],
        full_contents: Dict[str, str],
        query: str,
        limit: int,
        rerank: bool
    ) -> List[SearchResult]:
        """
        Process chunk search results: convert to SearchResult and optionally rerank.
        """
        # Convert to SearchResult format
        search_results = []
        
        for note in sorted_notes:
            note_id = note["note_id"]
            content_preview = note.get("best_chunk_content", "")[:500]
            
            search_results.append(SearchResult(
                note_id=note_id,
                title=note["title"],
                content_preview=content_preview,
                tag=note["tag"],
                file_type=note["file_type"],
                blob_url=note["blob_url"],
                similarity_score=note["best_chunk_similarity"],
                source="chunk",
                metadata={
                    "best_chunk_index": note["best_chunk_index"],
                    "chunk_count": len(note["all_chunk_scores"]),
                    "avg_chunk_score": sum(note["all_chunk_scores"]) / len(note["all_chunk_scores"])
                }
            ))
        
        # Apply reranking if enabled
        reranker = self._get_reranker()
        if rerank and reranker and search_results:
            candidates = [
                {
                    "note_id": r.note_id,
                    "title": r.title,
                    "content_preview": r.content_preview,
                    "content_full": full_contents.get(r.note_id, r.content_preview),
                    "tag": r.tag,
                    "file_type": r.file_type,
                    "blob_url": r.blob_url,
                    "similarity_score": r.similarity_score,
                    "source": r.source,
                    "metadata": r.metadata
                }
                for r in search_results
            ]
            
            reranked = await reranker.rerank(
                query=query,
                candidates=candidates,
                text_field="content_full",
                top_k=limit
            )
            logger.info(f"_process_chunk_results: reranked {len(candidates)} -> {len(reranked)} results")
            
            search_results = [
                SearchResult(
                    note_id=r["note_id"],
                    title=r["title"],
                    content_preview=r["content_preview"],
                    tag=r["tag"],
                    file_type=r["file_type"],
                    blob_url=r["blob_url"],
                    similarity_score=r["similarity_score"],
                    source="chunk_reranked",
                    metadata={
                        **r.get("metadata", {}),
                        "rerank_score": r.get("rerank_score", 0.0)
                    }
                )
                for r in reranked
            ]
        
        return search_results[:limit]
    
    @log_operation(
        service="retrieval_tools",
        operation="chunk_search",
        extract_input=lambda args, kwargs: {"query_length": len(kwargs.get("query", "") or (args[1] if len(args) > 1 else "")), "limit": kwargs.get("limit", 10)},
        extract_output=lambda r: {"results_count": len(r) if r else 0}
    )
    async def chunk_search(
        self,
        query: str,
        user_id: str = "default_user",
        tag: Optional[str] = None,
        limit: int = 10,
        rerank: bool = True,
        similarity_threshold: Optional[float] = None
    ) -> List[SearchResult]:
        """
        Search using chunk-level embeddings for better accuracy on long documents.
        
        This approach uses Cloudflare Vectorize:
        1. Searches ALL chunks in Vectorize index
        2. Groups results by note_id (parent document)
        3. Takes the MAX chunk similarity as the document score
        4. Applies similarity threshold to filter irrelevant results
        5. Optionally reranks using cross-encoder
        
        Args:
            query: Natural language search query
            user_id: User identifier
            tag: Optional tag filter
            limit: Maximum results
            rerank: If True, uses cross-encoder to rerank results
            similarity_threshold: Minimum similarity to include (default: CHUNK_SIMILARITY_THRESHOLD)
        
        Returns:
            List of SearchResult with document-level results based on best chunk match
        """
        threshold = similarity_threshold if similarity_threshold is not None else self.CHUNK_SIMILARITY_THRESHOLD
        logger.info(f"chunk_search: query='{query[:50]}...', tag={tag}, limit={limit}, rerank={rerank}, threshold={threshold}")
        
        # Use Cloudflare Vectorize via Worker for vector search
        import time
        vectorize_start = time.time()
        logger.info("chunk_search: using Cloudflare Vectorize backend")
        sorted_notes, full_contents = await self._vectorize_chunk_search(
            query, user_id, tag, limit, threshold
        )
        vectorize_time = int((time.time() - vectorize_start) * 1000)
        logger.info(f"chunk_search: _vectorize_chunk_search took {vectorize_time}ms")
        
        return await self._process_chunk_results(
            sorted_notes, full_contents, query, limit, rerank
        )
        
        # NOTE: Dead Supabase pgvector fallback code removed
        # Vectorize is the sole vector store for chunk search
    
    @log_operation(
        service="retrieval_tools",
        operation="search_by_tag",
        extract_input=lambda args, kwargs: {"tag": kwargs.get("tag") or (args[1] if len(args) > 1 else None), "limit": kwargs.get("limit", 10)},
        extract_output=lambda r: {"results_count": len(r) if r else 0}
    )
    async def search_by_tag(
        self,
        tag: str,
        user_id: str = "default_user",
        limit: int = 10
    ) -> List[SearchResult]:
        """
        Search notes by exact tag match.
        
        Args:
            tag: Tag to search for
            user_id: User identifier
            limit: Maximum results
        
        Returns:
            List of SearchResult for notes with matching tag
        """
        try:
            result = self.notes_db.client.rpc(
                "search_notes_by_tag",
                {
                    "search_tag": tag,
                    "match_count": limit,
                    "filter_user_id": user_id
                }
            ).execute()
            results = result.data or []
        except Exception as e:
            # Fallback to direct table query
            logger.warning(f"search_notes_by_tag RPC not available, using direct query: {e}")
            result = self.notes_db.client.table("notes").select("*").eq("user_id", user_id).eq("tag", tag).order("created_at", desc=True).limit(limit).execute()
            results = result.data or []
        
        return [
            SearchResult(
                note_id=str(r["id"]),
                title=r.get("title", "Untitled"),
                content_preview=r.get("content_markdown", "")[:500],
                tag=r.get("tag"),
                file_type=r.get("file_type", "unknown"),
                blob_url=r.get("blob_url", ""),
                similarity_score=1.0,  # Exact tag match
                source="tag",
                metadata={
                    "original_filename": r.get("original_filename"),
                    "created_at": str(r.get("created_at")) if r.get("created_at") else None
                }
            )
            for r in results
        ]
    
    # =========================================================================
    # QUERY EXPANSION
    # =========================================================================
    
    @log_operation(
        service="retrieval_tools",
        operation="expand_query",
        extract_input=lambda args, kwargs: {"query_length": len(kwargs.get("query", "") or (args[1] if len(args) > 1 else ""))},
        extract_output=lambda r: {"expansions_count": len(r) if r else 0}
    )
    async def expand_query(
        self,
        query: str,
        num_expansions: int = 3
    ) -> List[str]:
        """
        Generate query expansions/variations for broader search.
        Uses simple techniques without LLM to keep latency low.
        
        Args:
            query: Original query
            num_expansions: Number of variations to generate
        
        Returns:
            List of query variations
        """
        expansions = []
        words = query.lower().split()
        
        # Variation 1: Key nouns/concepts extraction
        stop_words = {'the', 'a', 'an', 'is', 'are', 'was', 'were', 'what', 'how', 'why', 'when', 'where', 'who', 'which', 'can', 'could', 'should', 'would', 'do', 'does', 'did', 'have', 'has', 'had', 'i', 'me', 'my', 'you', 'your', 'we', 'our', 'they', 'their', 'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from', 'about', 'find', 'get', 'show', 'tell', 'give', 'please', 'help', 'all'}
        key_words = [w for w in words if w not in stop_words and len(w) > 2]
        if key_words:
            expansions.append(' '.join(key_words))
        
        # Variation 2: First half focus (if long enough)
        if len(words) > 4:
            first_half = words[:len(words)//2 + 1]
            first_half_clean = [w for w in first_half if w not in stop_words]
            if first_half_clean:
                expansions.append(' '.join(first_half_clean))
        
        # Variation 3: Second half focus (if long enough)
        if len(words) > 4:
            second_half = words[len(words)//2:]
            second_half_clean = [w for w in second_half if w not in stop_words]
            if second_half_clean:
                expansions.append(' '.join(second_half_clean))
        
        # Ensure uniqueness and limit
        unique_expansions = []
        seen = {query.lower()}
        for exp in expansions:
            if exp.lower() not in seen and exp.strip():
                seen.add(exp.lower())
                unique_expansions.append(exp)
                if len(unique_expansions) >= num_expansions:
                    break
        
        return unique_expansions
    
    # =========================================================================
    # MMR RE-RANKING
    # =========================================================================
    
    @log_operation(
        service="retrieval_tools",
        operation="mmr_rerank",
        extract_input=lambda args, kwargs: {"results_count": len(kwargs.get("results", []) or (args[1] if len(args) > 1 else [])), "top_k": kwargs.get("top_k", 5)},
        extract_output=lambda r: {"reranked_count": len(r) if r else 0}
    )
    async def mmr_rerank(
        self,
        results: List[SearchResult],
        query: str,
        top_k: int = 5,
        lambda_param: float = 0.5
    ) -> List[SearchResult]:
        """
        Re-rank results using Maximal Marginal Relevance (MMR).
        Balances relevance with diversity.
        
        Args:
            results: Initial search results
            query: Original query
            top_k: Number of results to return
            lambda_param: Balance between relevance (1) and diversity (0)
        
        Returns:
            Re-ranked list of SearchResult
        """
        if not results or len(results) <= 1:
            return results
        
        # Get embeddings for query and all results
        query_embedding = await self._generate_query_embedding(query)
        
        # Get embeddings for result contents
        contents = [r.content_preview for r in results]
        result_embeddings = await self.embeddings_service.generate_embeddings_batch(contents)
        
        # Convert to numpy for efficient computation
        query_vec = np.array(query_embedding)
        result_vecs = np.array(result_embeddings)
        
        # Calculate similarity to query
        query_similarities = np.dot(result_vecs, query_vec) / (
            np.linalg.norm(result_vecs, axis=1) * np.linalg.norm(query_vec) + 1e-10
        )
        
        # MMR selection
        selected_indices = []
        remaining_indices = list(range(len(results)))
        
        while len(selected_indices) < min(top_k, len(results)):
            if not remaining_indices:
                break
            
            if not selected_indices:
                # First selection: highest relevance
                best_idx = remaining_indices[np.argmax(query_similarities[remaining_indices])]
            else:
                # MMR: balance relevance and diversity
                mmr_scores = []
                for idx in remaining_indices:
                    relevance = query_similarities[idx]
                    
                    # Max similarity to already selected
                    max_sim_to_selected = 0
                    for sel_idx in selected_indices:
                        sim = np.dot(result_vecs[idx], result_vecs[sel_idx]) / (
                            np.linalg.norm(result_vecs[idx]) * np.linalg.norm(result_vecs[sel_idx]) + 1e-10
                        )
                        max_sim_to_selected = max(max_sim_to_selected, sim)
                    
                    mmr = lambda_param * relevance - (1 - lambda_param) * max_sim_to_selected
                    mmr_scores.append((idx, mmr))
                
                best_idx = max(mmr_scores, key=lambda x: x[1])[0]
            
            selected_indices.append(best_idx)
            remaining_indices.remove(best_idx)
        
        return [results[i] for i in selected_indices]
    
    # =========================================================================
    # BLOB URL GENERATION
    # =========================================================================
    
    @log_operation(
        service="retrieval_tools",
        operation="get_blob_urls",
        extract_input=lambda args, kwargs: {"results_count": len(kwargs.get("results", []) or (args[1] if len(args) > 1 else []))},
        extract_output=lambda r: {"urls_generated": len(r) if r else 0}
    )
    async def get_blob_urls(
        self,
        results: List[SearchResult],
        expiry_hours: int = 1
    ) -> List[Dict[str, str]]:
        """
        Generate SAS URLs for downloading the original documents.
        
        Args:
            results: Search results to get URLs for
            expiry_hours: Hours until URL expires
        
        Returns:
            List of dicts with note_id and download_url
        """
        urls = []
        
        for result in results:
            if result.blob_url:
                # Extract blob name from URL
                # Format: https://account.blob.core.windows.net/container/user/type/file.ext
                try:
                    blob_name = result.blob_url.split(f"{self.blob_service.container_name}/")[-1]
                    sas_url = self.blob_service.generate_sas_url(blob_name, expiry_hours)
                    urls.append({
                        "note_id": result.note_id,
                        "title": result.title,
                        "download_url": sas_url,
                        "file_type": result.file_type
                    })
                except Exception as e:
                    logger.warning(f"Failed to generate SAS URL for {result.note_id}: {e}")
                    urls.append({
                        "note_id": result.note_id,
                        "title": result.title,
                        "download_url": result.blob_url,  # Fallback to original URL
                        "file_type": result.file_type,
                        "error": str(e)
                    })
        
        return urls
    
    # =========================================================================
    # HELPER: Get full document content
    # =========================================================================
    
    @log_operation(
        service="retrieval_tools",
        operation="get_document_content",
        extract_input=lambda args, kwargs: {"note_id": kwargs.get("note_id") or (args[1] if len(args) > 1 else None)},
        extract_output=lambda r: {"content_length": len(r.get("content_markdown", "")) if r else 0}
    )
    async def get_document_content(
        self,
        note_id: str,
        user_id: str = "default_user"
    ) -> Optional[Dict[str, Any]]:
        """
        Get full document content for a specific note.
        
        Args:
            note_id: Note ID to retrieve
            user_id: User identifier
        
        Returns:
            Full note record or None
        """
        note = await self.notes_db.get_note_by_id(note_id, user_id)
        return note


# Singleton instance
_retrieval_tools_service = None

def get_retrieval_tools_service() -> RetrievalToolsService:
    global _retrieval_tools_service
    if _retrieval_tools_service is None:
        _retrieval_tools_service = RetrievalToolsService()
    return _retrieval_tools_service
