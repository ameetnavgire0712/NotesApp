"""
Cloudflare Worker Client

HTTP client for interacting with the Cloudflare Worker that handles:
- Vector search via Cloudflare Vectorize
- Embedding generation via Workers AI
- Reranking via Jina API

This client is used by the Search Service to delegate embedding,
search, and reranking operations to the edge.
"""

import os
import logging
from dataclasses import dataclass
from typing import Optional

import httpx
from tenacity import retry, stop_after_attempt, wait_exponential


logger = logging.getLogger(__name__)


@dataclass
class SearchResult:
    """Single search result from Vectorize."""
    chunk_id: str
    similarity: float
    rerank_score: Optional[float] = None
    note_id: Optional[str] = None
    user_id: Optional[str] = None
    content_preview: Optional[str] = None
    chunk_index: Optional[int] = None
    
    @classmethod
    def from_dict(cls, data: dict) -> "SearchResult":
        return cls(
            chunk_id=data.get("chunk_id", ""),
            similarity=data.get("similarity", 0.0),
            rerank_score=data.get("rerank_score"),
            note_id=data.get("note_id"),
            user_id=data.get("user_id"),
            content_preview=data.get("content_preview"),
            chunk_index=data.get("chunk_index"),
        )


@dataclass
class SearchResponse:
    """Response from search or search-rerank endpoint."""
    success: bool
    matches: list[SearchResult]
    raw_results_count: int
    timing: dict
    
    @classmethod
    def from_dict(cls, data: dict) -> "SearchResponse":
        matches = [SearchResult.from_dict(m) for m in data.get("matches", [])]
        return cls(
            success=data.get("success", False),
            matches=matches,
            raw_results_count=data.get("raw_results_count", len(matches)),
            timing=data.get("timing", {}),
        )


class WorkerClient:
    """
    Async HTTP client for Cloudflare Worker.
    
    Features:
    - Search with/without reranking
    - Embedding generation
    - Vector upsert/delete
    - Retry logic with exponential backoff
    """
    
    def __init__(
        self,
        worker_url: Optional[str] = None,
        worker_secret: Optional[str] = None,
        timeout: float = 60.0,
    ):
        self.worker_url = worker_url or os.environ.get("WORKER_URL", "")
        self.worker_secret = worker_secret or os.environ.get("WORKER_API_KEY", "")
        self.timeout = timeout
        
        if not self.worker_url:
            raise ValueError("WORKER_URL environment variable is required")
        if not self.worker_secret:
            raise ValueError("WORKER_API_KEY environment variable is required")
            
    def _get_headers(self) -> dict:
        """Get headers for Worker requests."""
        return {
            "Authorization": f"Bearer {self.worker_secret}",
            "Content-Type": "application/json",
        }
        
    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=1, max=10),
    )
    async def search_and_rerank(
        self,
        query: str,
        user_id: str,
        tag: Optional[str] = None,
        limit: int = 50,
        top_k: int = 10,
        rerank_model: str = "rerank-2.5",
    ) -> SearchResponse:
        """
        Search with embedding + Vectorize + Voyage AI reranking in one call.
        
        This is the primary method for search - it combines:
        1. Embedding generation (Workers AI)
        2. Vector search (Vectorize)
        3. Reranking (Voyage AI API)
        
        Args:
            query: Search query text
            user_id: User ID for filtering results
            tag: Optional tag filter
            limit: Initial search limit before reranking (default 50)
            top_k: Final results after reranking (default 10)
            rerank_model: Voyage AI model to use
            
        Returns:
            SearchResponse with reranked results and timing info
        """
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.post(
                f"{self.worker_url}/search-rerank",
                headers=self._get_headers(),
                json={
                    "query": query,
                    "user_id": user_id,
                    "tag": tag,
                    "limit": limit,
                    "top_k": top_k,
                    "rerank_model": rerank_model,
                },
            )
            
            response.raise_for_status()
            data = response.json()
            
            # Log timing
            timing = data.get("timing", {})
            logger.info(
                f"Search+Rerank: embedding={timing.get('embedding_ms', 0)}ms, "
                f"vectorize={timing.get('vectorize_ms', 0)}ms, "
                f"rerank={timing.get('rerank_ms', 0)}ms, "
                f"total={timing.get('total_ms', 0)}ms"
            )
            
            return SearchResponse.from_dict(data)
            
    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=1, max=10),
    )
    async def search_only(
        self,
        query: str,
        user_id: Optional[str] = None,
        tag: Optional[str] = None,
        limit: int = 50,
    ) -> SearchResponse:
        """
        Search without reranking (faster, but less accurate).
        
        Use this for quick searches where reranking latency isn't acceptable.
        """
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.post(
                f"{self.worker_url}/search",
                headers=self._get_headers(),
                json={
                    "query": query,
                    "user_id": user_id,
                    "tag": tag,
                    "limit": limit,
                },
            )
            
            response.raise_for_status()
            return SearchResponse.from_dict(response.json())
            
    async def generate_embedding(self, text: str) -> list[float]:
        """Generate embedding for a single text."""
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{self.worker_url}/embed",
                headers=self._get_headers(),
                json={"text": text},
            )
            
            response.raise_for_status()
            return response.json()["embedding"]
            
    async def generate_embeddings(self, texts: list[str]) -> list[list[float]]:
        """Generate embeddings for multiple texts."""
        async with httpx.AsyncClient(timeout=60.0) as client:
            response = await client.post(
                f"{self.worker_url}/embed-batch",
                headers=self._get_headers(),
                json={"texts": texts},
            )
            
            response.raise_for_status()
            return response.json()["embeddings"]
            
    async def upsert_vectors(
        self,
        vectors: list[dict],
        namespace: Optional[str] = None,
    ) -> dict:
        """
        Upsert vectors to Vectorize.
        
        Args:
            vectors: List of {id, values, metadata} dicts
            namespace: Optional namespace for organization
            
        Returns:
            Upsert result with count and timing
        """
        async with httpx.AsyncClient(timeout=120.0) as client:
            response = await client.post(
                f"{self.worker_url}/upsert",
                headers=self._get_headers(),
                json={
                    "vectors": vectors,
                    "namespace": namespace,
                },
            )
            
            response.raise_for_status()
            return response.json()
            
    async def delete_vectors(self, ids: list[str]) -> dict:
        """Delete vectors by ID."""
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{self.worker_url}/delete",
                headers=self._get_headers(),
                json={"ids": ids},
            )
            
            response.raise_for_status()
            return response.json()
            
    async def health_check(self) -> dict:
        """Check Worker health."""
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(f"{self.worker_url}/health")
            return response.json()


# Singleton instance
_worker_client: Optional[WorkerClient] = None


def get_worker_client() -> WorkerClient:
    """Get the singleton WorkerClient instance."""
    global _worker_client
    
    if _worker_client is None:
        _worker_client = WorkerClient()
        
    return _worker_client
