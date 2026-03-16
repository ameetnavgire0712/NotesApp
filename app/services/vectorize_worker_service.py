"""
Cloudflare Worker Vector Search Service
Uses a Cloudflare Worker at the edge for low-latency vector operations.
This is the RECOMMENDED production approach (vs direct API which is slow).
"""
import time
import logging
import httpx
from typing import List, Dict, Any, Optional

logger = logging.getLogger(__name__)


class VectorizeWorkerService:
    """
    Vector search service using Cloudflare Worker at the edge.
    
    Architecture:
    - Your App (Mumbai) → Worker (Mumbai Edge) → Vectorize = ~30-50ms
    - vs Direct API: Your App → US API → Vectorize = 600-2000ms
    
    The Worker also handles:
    - Embedding generation via Workers AI (if you send text instead of vectors)
    - Filtering by user_id/tag
    - CORS for browser access
    """
    
    EMBEDDING_DIM = 768  # BGE base model dimension
    
    def __init__(self, worker_url: str, api_key: str):
        """
        Initialize the Worker service.
        
        Args:
            worker_url: Full URL to your deployed Worker 
                       (e.g., https://notesapp-vector-search.your-subdomain.workers.dev)
            api_key: API key for authenticating with the Worker
        """
        self.worker_url = worker_url.rstrip("/")
        self.api_key = api_key
        self.headers = {
            "X-API-Key": api_key,
            "Content-Type": "application/json"
        }
        self._client: Optional[httpx.AsyncClient] = None
        
    async def _get_client(self) -> httpx.AsyncClient:
        """Get or create HTTP client with connection pooling."""
        if self._client is None or self._client.is_closed:
            # Configure connection pool for high concurrent requests
            # HTTP/2 multiplexes many requests over fewer connections
            limits = httpx.Limits(
                max_keepalive_connections=50,
                max_connections=200,
                keepalive_expiry=60.0
            )
            self._client = httpx.AsyncClient(
                timeout=60.0,  # Increased timeout for high load
                limits=limits,
                http2=True  # HTTP/2 multiplexes multiple requests per connection
            )
        return self._client
        
    async def close(self):
        """Close HTTP client."""
        if self._client and not self._client.is_closed:
            await self._client.aclose()
    
    async def hybrid_search(
        self,
        query: str,
        user_id: Optional[str] = None,
        tag: Optional[str] = None,
        limit: int = 10,
        rerank: bool = True,
        rerank_top_k: int = 20,
        correlation_id: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Hybrid search - combines embed + search + rerank in single Worker call.
        This is the FASTEST option as it eliminates 2 HTTP round-trips.
        
        Args:
            query: Text to search for (required)
            user_id: Filter by user
            tag: Filter by tag  
            limit: Final results to return (default 10)
            rerank: Enable reranking via Voyage AI (default True)
            rerank_top_k: How many candidates to rerank (default 20)
            correlation_id: Backend correlation ID for trace logging
            
        Returns dict with:
            - matches: List of reranked results
            - timing: Breakdown of embed/search/rerank times
            - request_id: Worker request ID for tracing
            
        Raises:
            Exception: If Worker call fails (Fly.io should handle error)
        """
        start = time.time()
        client = await self._get_client()
        
        payload: Dict[str, Any] = {
            "query": query,
            "limit": limit,
            "rerank": rerank,
            "rerank_top_k": rerank_top_k
        }
        
        if user_id:
            payload["user_id"] = user_id
        if tag:
            payload["tag"] = tag
        if correlation_id:
            payload["correlation_id"] = correlation_id
        
        response = await client.post(
            f"{self.worker_url}/hybrid",
            headers=self.headers,
            json=payload
        )
        
        if response.status_code != 200:
            error_text = response.text
            logger.error(f"Worker hybrid search failed: {response.status_code} - {error_text}")
            raise Exception(f"Worker hybrid search failed: {error_text}")
        
        result = response.json()
        
        if not result.get("success"):
            error = result.get("error", "Unknown error")
            logger.error(f"Worker hybrid search error: {error}")
            raise Exception(f"Worker hybrid search error: {error}")
        
        matches = result.get("matches", [])
        timing = result.get("timing", {})
        
        duration = time.time() - start
        cached = timing.get("embedding_cached", False)
        logger.info(
            f"Worker hybrid search: {len(matches)} results in {duration*1000:.1f}ms "
            f"(embed={timing.get('embedding_ms', 0)}ms cached={cached}, "
            f"vec={timing.get('vectorize_ms', 0)}ms, rerank={timing.get('rerank_ms', 0)}ms)"
        )
        
        return {
            "matches": matches,
            "timing": timing,
            "request_id": result.get("request_id")
        }
    
    async def hybrid_search_debug(
        self,
        query: str,
        user_id: Optional[str] = None,
        tag: Optional[str] = None,
        limit: int = 10,
        rerank: bool = True,
        rerank_top_k: int = 20
    ) -> Dict[str, Any]:
        """
        Hybrid search with DEBUG mode - returns all intermediate data.
        
        Calls Worker /hybrid endpoint with debug=true flag to get:
        - Vector search candidates (before combining)
        - Keyword search candidates (before combining)
        - Combined candidates (before reranking)
        - Reranked candidates with scores
        - Thresholds used
        
        Args:
            query: Text to search for (required)
            user_id: Filter by user
            tag: Filter by tag  
            limit: Final results to return
            rerank: Enable reranking (default True)
            rerank_top_k: How many candidates to rerank
            
        Returns dict with:
            - matches: Final results
            - timing: Detailed breakdown
            - debug: All intermediate data
            - thresholds: Score thresholds used
        """
        start = time.time()
        client = await self._get_client()
        
        payload: Dict[str, Any] = {
            "query": query,
            "limit": limit,
            "rerank": rerank,
            "rerank_top_k": rerank_top_k,
            "debug": True  # Request debug data from Worker
        }
        
        if user_id:
            payload["user_id"] = user_id
        if tag:
            payload["tag"] = tag
        
        response = await client.post(
            f"{self.worker_url}/hybrid",
            headers=self.headers,
            json=payload
        )
        
        if response.status_code != 200:
            error_text = response.text
            logger.error(f"Worker hybrid_search_debug failed: {response.status_code} - {error_text}")
            raise Exception(f"Worker hybrid_search_debug failed: {error_text}")
        
        result = response.json()
        
        if not result.get("success"):
            error = result.get("error", "Unknown error")
            logger.error(f"Worker hybrid_search_debug error: {error}")
            raise Exception(f"Worker hybrid_search_debug error: {error}")
        
        duration = time.time() - start
        timing = result.get("timing", {})
        logger.info(f"Worker hybrid_search_debug: completed in {duration*1000:.1f}ms")
        
        return {
            "matches": result.get("matches", []),
            "timing": timing,
            "debug": result.get("debug", {}),
            "thresholds": result.get("thresholds", {}),
            "request_id": result.get("request_id")
        }
    
    async def search(
        self,
        query: Optional[str] = None,
        embedding: Optional[List[float]] = None,
        user_id: Optional[str] = None,
        tag: Optional[str] = None,
        limit: int = 50
    ) -> List[Dict[str, Any]]:
        """
        Search for similar vectors.
        
        You can provide either:
        - query: Text query (Worker will generate embedding via Workers AI)
        - embedding: Pre-computed 768-dim embedding
        
        Args:
            query: Text to search for
            embedding: Pre-computed embedding vector
            user_id: Filter by user
            tag: Filter by tag
            limit: Max results (default 50)
            
        Returns list of matches with chunk_id, similarity, and metadata.
        """
        start = time.time()
        client = await self._get_client()
        
        payload: Dict[str, Any] = {"limit": min(limit, 50)}
        
        if embedding:
            payload["embedding"] = embedding
        elif query:
            payload["query"] = query
        else:
            raise ValueError("Must provide either 'query' or 'embedding'")
        
        if user_id:
            payload["user_id"] = user_id
        if tag:
            payload["tag"] = tag
        
        response = await client.post(
            f"{self.worker_url}/search",
            headers=self.headers,
            json=payload
        )
        
        if response.status_code != 200:
            error_text = response.text
            logger.error(f"Worker search failed: {response.status_code} - {error_text}")
            raise Exception(f"Worker search failed: {error_text}")
        
        result = response.json()
        
        if not result.get("success"):
            error = result.get("error", "Unknown error")
            logger.error(f"Worker search error: {error}")
            raise Exception(f"Worker search error: {error}")
        
        matches = result.get("matches", [])
        timing = result.get("timing", {})
        
        duration = time.time() - start
        vectorize_ms = timing.get("vectorize_ms", 0)
        logger.info(f"Worker search: {len(matches)} results in {duration*1000:.1f}ms (vectorize={vectorize_ms}ms)")
        
        return matches
    
    async def upsert(self, vectors: List[Dict[str, Any]]) -> Dict[str, Any]:
        """
        Insert or update vectors.
        
        Each vector should have:
        - id: str (unique identifier)
        - values: List[float] (768-dim embedding) OR text: str (to generate embedding)
        - metadata: Dict (note_id, content, title, tag, etc.)
        
        Returns success status and count.
        """
        if not vectors:
            return {"success": True, "count": 0}
            
        start = time.time()
        client = await self._get_client()
        
        # Format for Worker API
        formatted = []
        for v in vectors:
            item = {
                "id": str(v["id"]),
                "metadata": v.get("metadata", {})
            }
            if "values" in v:
                item["values"] = v["values"]
            elif "text" in v:
                item["text"] = v["text"]
            else:
                raise ValueError(f"Vector {v['id']} must have 'values' or 'text'")
            formatted.append(item)
        
        response = await client.post(
            f"{self.worker_url}/upsert",
            headers=self.headers,
            json={"vectors": formatted}
        )
        
        if response.status_code != 200:
            error_text = response.text
            logger.error(f"Worker upsert failed: {response.status_code} - {error_text}")
            raise Exception(f"Worker upsert failed: {error_text}")
        
        result = response.json()
        
        if not result.get("success"):
            error = result.get("error", "Unknown error")
            logger.error(f"Worker upsert error: {error}")
            raise Exception(f"Worker upsert error: {error}")
        
        duration = time.time() - start
        count = result.get("count", 0)
        logger.info(f"Worker upsert: {count} vectors in {duration:.2f}s")
        
        return {"success": True, "count": count}
    
    async def delete_by_ids(self, ids: List[str]) -> Dict[str, Any]:
        """Delete vectors by their IDs."""
        if not ids:
            return {"success": True, "count": 0}
            
        start = time.time()
        client = await self._get_client()
        
        response = await client.post(
            f"{self.worker_url}/delete",
            headers=self.headers,
            json={"ids": ids}
        )
        
        if response.status_code != 200:
            error_text = response.text
            logger.error(f"Worker delete failed: {response.status_code} - {error_text}")
            raise Exception(f"Worker delete failed: {error_text}")
        
        result = response.json()
        
        if not result.get("success"):
            error = result.get("error", "Unknown error")
            logger.error(f"Worker delete error: {error}")
            raise Exception(f"Worker delete error: {error}")
        
        duration = time.time() - start
        count = result.get("count", 0)
        logger.info(f"Worker delete: {count} vectors in {duration:.2f}s")
        
        return {"success": True, "count": count}
    
    async def health_check(self) -> Dict[str, Any]:
        """Check if the Worker is healthy."""
        client = await self._get_client()
        
        try:
            response = await client.get(f"{self.worker_url}/health")
            return response.json()
        except Exception as e:
            return {"status": "unhealthy", "error": str(e)}
    
    async def embed(self, text: str) -> List[float]:
        """
        Generate embedding for a single text using Cloudflare Workers AI.
        This runs at the edge and scales horizontally.
        
        Args:
            text: Text to embed
            
        Returns:
            768-dimension embedding vector
        """
        from app.core.middleware import get_user_id
        start = time.time()
        client = await self._get_client()
        
        # Include user_id from context for logging/tracing
        payload = {"text": text}
        user_id = get_user_id()
        if user_id:
            payload["user_id"] = user_id
        
        response = await client.post(
            f"{self.worker_url}/embed",
            headers=self.headers,
            json=payload
        )
        
        if response.status_code != 200:
            error_text = response.text
            logger.error(f"Worker embed failed: {response.status_code} - {error_text}")
            raise Exception(f"Worker embed failed: {error_text}")
        
        result = response.json()
        
        if not result.get("success"):
            error = result.get("error", "Unknown error")
            logger.error(f"Worker embed error: {error}")
            raise Exception(f"Worker embed error: {error}")
        
        embedding = result.get("embedding", [])
        timing = result.get("timing", {})
        
        duration = time.time() - start
        logger.debug(f"Worker embed: {len(embedding)} dims in {duration*1000:.1f}ms (worker={timing.get('embedding_ms', 0)}ms)")
        
        return embedding
    
    async def embed_batch(self, texts: List[str]) -> List[List[float]]:
        """
        Generate embeddings for multiple texts using Cloudflare Workers AI.
        More efficient than individual calls for batches.
        
        Args:
            texts: List of texts to embed
            
        Returns:
            List of 768-dimension embedding vectors
        """
        if not texts:
            return []
        
        from app.core.middleware import get_user_id
        start = time.time()
        client = await self._get_client()
        
        # Include user_id from context for logging/tracing
        payload = {"texts": texts}
        user_id = get_user_id()
        if user_id:
            payload["user_id"] = user_id
        
        response = await client.post(
            f"{self.worker_url}/embed-batch",
            headers=self.headers,
            json=payload
        )
        
        if response.status_code != 200:
            error_text = response.text
            logger.error(f"Worker embed-batch failed: {response.status_code} - {error_text}")
            raise Exception(f"Worker embed-batch failed: {error_text}")
        
        result = response.json()
        
        if not result.get("success"):
            error = result.get("error", "Unknown error")
            logger.error(f"Worker embed-batch error: {error}")
            raise Exception(f"Worker embed-batch error: {error}")
        
        embeddings = result.get("embeddings", [])
        timing = result.get("timing", {})
        
        duration = time.time() - start
        logger.info(f"Worker embed-batch: {len(embeddings)} embeddings in {duration*1000:.1f}ms (worker={timing.get('embedding_ms', 0)}ms)")
        
        return embeddings

    async def invalidate_user_cache(
        self,
        user_id: str,
        cache_type: str = "search"
    ) -> Dict[str, Any]:
        """
        Invalidate search results cache for a user.
        
        Call this when:
        - User uploads a new document
        - User deletes a document
        - User updates a document
        
        Args:
            user_id: User ID to invalidate cache for
            cache_type: "search", "embedding", or "all" (default: "search")
            
        Returns dict with invalidation result.
        """
        start = time.time()
        client = await self._get_client()
        
        payload = {
            "user_id": user_id,
            "type": cache_type
        }
        
        try:
            response = await client.post(
                f"{self.worker_url}/cache/invalidate",
                headers=self.headers,
                json=payload
            )
            
            if response.status_code != 200:
                error_text = response.text
                logger.warning(f"Worker cache invalidation failed: {response.status_code} - {error_text}")
                return {"success": False, "error": error_text}
            
            result = response.json()
            duration = time.time() - start
            logger.info(f"Worker cache invalidated for user {user_id[:8]}... in {duration*1000:.1f}ms")
            
            return result
            
        except Exception as e:
            logger.warning(f"Cache invalidation error (non-critical): {e}")
            return {"success": False, "error": str(e)}


# Singleton instance
_worker_service: Optional[VectorizeWorkerService] = None

def get_vectorize_worker_service() -> VectorizeWorkerService:
    """Get or create the Worker service singleton."""
    global _worker_service
    if _worker_service is None:
        from app.core.config import get_settings
        settings = get_settings()
        
        if not settings.vectorize_worker_url or not settings.vectorize_worker_api_key:
            raise ValueError(
                "Cloudflare Worker not configured. "
                "Set VECTORIZE_WORKER_URL and VECTORIZE_WORKER_API_KEY in .env"
            )
        
        _worker_service = VectorizeWorkerService(
            worker_url=settings.vectorize_worker_url,
            api_key=settings.vectorize_worker_api_key
        )
        logger.info(f"Vectorize Worker service initialized: {settings.vectorize_worker_url}")
    return _worker_service
