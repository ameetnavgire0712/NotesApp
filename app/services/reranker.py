"""
Reranker Service
Uses Voyage AI API via Cloudflare Worker for high-quality reranking of search results
"""
import logging
import time
from typing import List, Tuple, Any
import httpx
from app.core.config import get_settings
from app.core.log_decorators import log_operation

logger = logging.getLogger(__name__)


class RerankerService:
    """
    Service for reranking search results using Voyage AI Reranker API via Cloudflare Worker.
    Voyage AI reranker provides high-quality multilingual reranking without local model loading.
    """
    
    MODEL_NAME = "rerank-2.5"
    
    _instance = None
    
    def __new__(cls):
        """Singleton pattern"""
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance
    
    def __init__(self):
        if not hasattr(self, '_initialized'):
            settings = get_settings()
            self.worker_url = settings.vectorize_worker_url
            self.worker_api_key = settings.vectorize_worker_api_key
            self._client = None  # Shared httpx client
            
            if not self.worker_url:
                raise ValueError("VECTORIZE_WORKER_URL is required for reranking")
            
            logger.info(f"Reranker initialized with Voyage AI API via Worker: {self.worker_url}")
            self._initialized = True
    
    async def _get_client(self) -> httpx.AsyncClient:
        """Get or create shared HTTP client."""
        if self._client is None or self._client.is_closed:
            limits = httpx.Limits(
                max_keepalive_connections=20,
                max_connections=100,
                keepalive_expiry=60.0
            )
            self._client = httpx.AsyncClient(
                timeout=60.0,
                limits=limits,
                http2=True
            )
        return self._client
    
    def _get_headers(self) -> dict:
        """Get headers for Worker requests."""
        return {
            "Authorization": f"Bearer {self.worker_api_key}",
            "Content-Type": "application/json",
        }
    
    @log_operation(
        service="reranker",
        operation="rerank",
        extract_input=lambda args, kwargs: {
            "query_length": len(kwargs.get("query", "") or (args[1] if len(args) > 1 else "")),
            "candidates_count": len(kwargs.get("candidates", []) or (args[2] if len(args) > 2 else []))
        },
        extract_output=lambda r: {"reranked_count": len(r) if r else 0}
    )
    async def rerank(
        self,
        query: str,
        candidates: List[dict],
        text_field: str = "content_preview",
        top_k: int = 10,
        include_title: bool = True,
        score_threshold: float = 0.3,  # Raised from 0.1 - only return truly relevant results
        max_gap_from_top: float = 0.5
    ) -> List[dict]:
        """
        Rerank candidates using Voyage AI API via Cloudflare Worker.
        
        Args:
            query: The search query
            candidates: List of candidate documents (dicts with text content)
            text_field: Which field contains the text to compare
            top_k: How many top results to return
            include_title: If True, prepend title to text for better matching
            score_threshold: Minimum rerank score (Voyage AI scores are 0-1)
            max_gap_from_top: Max score difference from top result
        
        Returns:
            Reranked list of candidates with added 'rerank_score', filtered by relevance
        """
        if not candidates or not query:
            return candidates[:top_k] if candidates else []
        
        logger.debug(f"rerank: query='{query[:50]}...', candidates={len(candidates)}, top_k={top_k}")
        start = time.time()
        
        # Build documents for Voyage AI
        documents = []
        valid_indices = []
        
        for i, candidate in enumerate(candidates):
            text = candidate.get(text_field, "")
            
            # Include title for better semantic matching
            if include_title and candidate.get("title"):
                title = candidate.get("title", "")
                text = f"Document: {title}\n\n{text}"
            
            if text:
                # Truncate for Voyage AI (keep it reasonable)
                words = text.split()
                if len(words) > 500:
                    # Keep first 350 + last 150 words
                    first_part = " ".join(words[:350])
                    last_part = " ".join(words[-150:])
                    text = f"{first_part}\n...\n{last_part}"
                documents.append(text)
                valid_indices.append(i)
        
        if not documents:
            return candidates[:top_k]
        
        logger.debug(f"rerank: calling Voyage AI API with {len(documents)} documents")
        
        try:
            from app.core.middleware import get_user_id
            client = await self._get_client()
            
            # Include user_id from context for logging/tracing
            payload = {
                "query": query,
                "documents": documents,
                "top_k": min(top_k * 2, len(documents)),  # Get extra for filtering
                "model": self.MODEL_NAME,
            }
            user_id = get_user_id()
            if user_id:
                payload["user_id"] = user_id
            
            response = await client.post(
                f"{self.worker_url}/rerank",
                headers=self._get_headers(),
                json=payload,
            )
            response.raise_for_status()
            data = response.json()
        except Exception as e:
            logger.error(f"Voyage AI rerank failed: {e}, returning unranked candidates")
            return candidates[:top_k]
        
        # Process results from Voyage AI
        rerank_results = data.get("results", [])
        
        logger.debug(f"rerank: Voyage AI returned {len(rerank_results)} results")
        
        scored_candidates = []
        for result in rerank_results:
            idx = result.get("index", 0)
            score = result.get("relevance_score", 0.0)
            
            if idx < len(valid_indices):
                original_idx = valid_indices[idx]
                candidate = candidates[original_idx].copy()
                candidate["rerank_score"] = float(score)
                scored_candidates.append((float(score), candidate))
        
        # Sort by score descending
        scored_candidates.sort(key=lambda x: x[0], reverse=True)
        
        # Log all reranker scores at INFO level for visibility
        logger.info(f"rerank: scores for query='{query[:30]}...' (threshold={score_threshold}, max_gap={max_gap_from_top}):")
        for i, (score, candidate) in enumerate(scored_candidates):
            title = candidate.get('title', 'Untitled')[:50]
            logger.info(f"  [{i+1}] score={score:.4f} | '{title}'")
        
        # Apply relevance filtering
        if scored_candidates:
            top_score = scored_candidates[0][0]
            filtered_candidates = []
            
            for score, candidate in scored_candidates:
                # Filter by absolute threshold
                if score < score_threshold:
                    logger.info(f"  ❌ Filtered out '{candidate.get('title', '')[:40]}' - score {score:.3f} < threshold {score_threshold}")
                    continue
                
                # Filter by gap from top result
                gap = top_score - score
                if gap > max_gap_from_top:
                    logger.info(f"  ❌ Filtered out '{candidate.get('title', '')[:40]}' - gap {gap:.3f} > max {max_gap_from_top}")
                    continue
                
                filtered_candidates.append(candidate)
            
            results = filtered_candidates[:top_k]
            
            if not results:
                logger.info(
                    f"Reranked {len(documents)} candidates via Voyage AI in {time.time() - start:.3f}s, "
                    f"ALL filtered out (top_score={top_score:.3f} below threshold={score_threshold})"
                )
            else:
                logger.info(
                    f"Reranked {len(documents)} candidates via Voyage AI in {time.time() - start:.3f}s, "
                    f"filtered to {len(results)} relevant (top_score={top_score:.3f})"
                )
        else:
            results = []
            logger.info(f"Reranked {len(documents)} candidates via Voyage AI in {time.time() - start:.3f}s, no results")
        
        return results
    
    async def rerank_with_scores(
        self,
        query: str,
        texts: List[str],
        top_k: int = 10
    ) -> List[Tuple[int, float]]:
        """
        Rerank texts and return indices with scores.
        
        Args:
            query: The search query
            texts: List of text strings to rerank
            top_k: How many top results to return
        
        Returns:
            List of (original_index, score) tuples, sorted by score descending
        """
        if not texts or not query:
            return []
        
        # Truncate long texts
        processed_texts = []
        for text in texts:
            if text:
                words = text.split()
                if len(words) > 500:
                    text = " ".join(words[:500])
                processed_texts.append(text)
        
        if not processed_texts:
            return []
        
        try:
            client = await self._get_client()
            response = await client.post(
                f"{self.worker_url}/rerank",
                headers=self._get_headers(),
                json={
                    "query": query,
                    "documents": processed_texts,
                    "top_k": top_k,
                    "model": self.MODEL_NAME,
                },
            )
            response.raise_for_status()
            data = response.json()
        except Exception as e:
            logger.error(f"Voyage AI rerank_with_scores failed: {e}")
            return []
        
        results = [
            (r.get("index", 0), r.get("relevance_score", 0.0))
            for r in data.get("results", [])
        ]
        
        return results[:top_k]


# Singleton instance
_reranker_service = None

def get_reranker_service() -> RerankerService:
    """Get the singleton RerankerService instance"""
    global _reranker_service
    if _reranker_service is None:
        _reranker_service = RerankerService()
    return _reranker_service
