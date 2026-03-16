"""
Embeddings Service
Generates OpenAI embeddings with chunking for large documents (Option C strategy)
"""
import logging
from typing import List, Optional
from openai import OpenAI
from app.core.config import get_settings
from app.core.log_decorators import log_operation

logger = logging.getLogger(__name__)


class EmbeddingsService:
    """Service for generating text embeddings using OpenAI"""
    
    MODEL = "text-embedding-3-small"
    DIMENSIONS = 1536
    
    # Chunking parameters
    CHUNK_SIZE = 500  # tokens (approximate - using words as proxy)
    CHUNK_OVERLAP = 50  # tokens overlap between chunks
    
    def __init__(self):
        settings = get_settings()
        self.client = OpenAI(api_key=settings.openai_api_key)
    
    def _estimate_tokens(self, text: str) -> int:
        """Rough estimate of token count (words * 1.3)"""
        return int(len(text.split()) * 1.3)
    
    def _chunk_text(self, text: str) -> List[str]:
        """
        Split text into overlapping chunks for better retrieval
        
        Args:
            text: The text to chunk
        
        Returns:
            List of text chunks
        """
        words = text.split()
        
        # If text is small enough, return as single chunk
        if len(words) <= self.CHUNK_SIZE:
            return [text]
        
        chunks = []
        start = 0
        
        while start < len(words):
            end = start + self.CHUNK_SIZE
            chunk_words = words[start:end]
            chunk = " ".join(chunk_words)
            chunks.append(chunk)
            
            # Move start with overlap
            start = end - self.CHUNK_OVERLAP
            
            # Prevent infinite loop for small overlaps
            if start >= len(words) - self.CHUNK_OVERLAP:
                break
        
        return chunks
    
    @log_operation(
        service="embeddings",
        operation="generate_embedding",
        extract_input=lambda args, kwargs: {"text_length": len(kwargs.get("text", "") or (args[1] if len(args) > 1 else ""))},
        extract_output=lambda r: {"dimensions": len(r) if r else 0}
    )
    async def generate_embedding(self, text: str) -> List[float]:
        """
        Generate embedding for a single text
        
        Args:
            text: Text to embed
        
        Returns:
            List of floats (1536 dimensions)
        """
        if not text or not text.strip():
            logger.debug("embeddings.generate_embedding: empty text, returning zero vector")
            return [0.0] * self.DIMENSIONS
        
        # Truncate if too long (OpenAI limit is ~8191 tokens)
        words = text.split()
        original_len = len(words)
        if len(words) > 6000:
            text = " ".join(words[:6000])
            logger.debug(f"embeddings.generate_embedding: truncated from {original_len} to 6000 words")
        
        logger.debug(f"embeddings.generate_embedding: generating for {len(words)} words using {self.MODEL}")
        
        response = self.client.embeddings.create(
            model=self.MODEL,
            input=text,
            dimensions=self.DIMENSIONS
        )
        
        logger.debug(f"embeddings.generate_embedding: completed, dim={len(response.data[0].embedding)}")
        return response.data[0].embedding
    
    async def generate_embeddings_batch(self, texts: List[str]) -> List[List[float]]:
        """
        Generate embeddings for multiple texts in a single API call
        
        Args:
            texts: List of texts to embed
        
        Returns:
            List of embeddings
        """
        if not texts:
            return []
        
        # Filter empty texts and track indices
        valid_texts = []
        valid_indices = []
        for i, text in enumerate(texts):
            if text and text.strip():
                # Truncate if needed
                words = text.split()
                if len(words) > 6000:
                    text = " ".join(words[:6000])
                valid_texts.append(text)
                valid_indices.append(i)
        
        if not valid_texts:
            return [[0.0] * self.DIMENSIONS for _ in texts]
        
        response = self.client.embeddings.create(
            model=self.MODEL,
            input=valid_texts,
            dimensions=self.DIMENSIONS
        )
        
        # Map results back to original indices
        results = [[0.0] * self.DIMENSIONS for _ in texts]
        for i, embedding_data in enumerate(response.data):
            original_index = valid_indices[i]
            results[original_index] = embedding_data.embedding
        
        return results
    
    @log_operation(
        service="embeddings",
        operation="process_document",
        extract_input=lambda args, kwargs: {"content_length": len(kwargs.get("markdown_content", "") or (args[1] if len(args) > 1 else "")), "has_title": bool(kwargs.get("title"))},
        extract_output=lambda r: {"chunks_count": len(r.get("chunks", [])) if r else 0}
    )
    async def process_document(
        self,
        markdown_content: str,
        title: Optional[str] = None
    ) -> dict:
        """
        Process a document with Option C strategy:
        - Generate document-level embedding (for quick search)
        - Generate chunk-level embeddings (for deep search)
        
        Args:
            markdown_content: The markdown content of the document
            title: Optional title to prepend for context
        
        Returns:
            dict with document_embedding and chunks (with their embeddings)
        """
        logger.debug(f"embeddings.process_document: content_length={len(markdown_content)}, has_title={bool(title)}")
        
        if not markdown_content:
            logger.debug("embeddings.process_document: empty content, returning zero vectors")
            return {
                "document_embedding": [0.0] * self.DIMENSIONS,
                "chunks": []
            }
        
        # Prepare full text for document-level embedding
        full_text = f"{title}\n\n{markdown_content}" if title else markdown_content
        
        # Create summary for document embedding (first ~1000 words + title)
        words = full_text.split()
        summary_text = " ".join(words[:1000]) if len(words) > 1000 else full_text
        logger.debug(f"Summary text for doc embedding: {len(summary_text.split())} words")
        
        # Chunk the content for detailed embeddings
        chunks = self._chunk_text(markdown_content)
        logger.debug(f"Content chunked into {len(chunks)} chunks")
        
        # OPTIMIZATION: Generate ALL embeddings in a single batch API call
        # First item is document summary, rest are chunks
        all_texts = [summary_text] + chunks
        logger.debug(f"Generating batch embeddings for {len(all_texts)} texts")
        all_embeddings = await self.generate_embeddings_batch(all_texts)
        
        document_embedding = all_embeddings[0]
        chunk_embeddings = all_embeddings[1:]
        logger.debug(f"Batch embeddings complete: doc_dim={len(document_embedding)}, chunk_count={len(chunk_embeddings)}")
        
        # Combine chunks with their embeddings
        chunk_data = [
            {
                "chunk_index": i,
                "content": chunk,
                "embedding": embedding
            }
            for i, (chunk, embedding) in enumerate(zip(chunks, chunk_embeddings))
        ]
        
        return {
            "document_embedding": document_embedding,
            "chunks": chunk_data
        }


# =============================================================================
# Worker-based Embeddings Service (for production deployment)
# =============================================================================

class WorkerEmbeddingsService:
    """
    Embeddings service using Cloudflare Worker (Workers AI BGE model).
    Same interface as LocalEmbeddingsService for drop-in replacement.
    
    Uses Workers AI @cf/baai/bge-base-en-v1.5 which produces 768-dim vectors.
    """
    
    DIMENSIONS = 768  # BGE-base produces 768-dim vectors
    QUERY_PREFIX = "Represent this sentence for searching relevant passages: "
    CHUNK_SIZE = 500
    CHUNK_OVERLAP = 50
    
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
            
            if not self.worker_url:
                raise ValueError("VECTORIZE_WORKER_URL is required for Worker embeddings")
            
            logger.info(f"WorkerEmbeddingsService initialized: {self.worker_url}")
            self._initialized = True
    
    def _get_headers(self) -> dict:
        """Get headers for Worker requests."""
        return {
            "Authorization": f"Bearer {self.worker_api_key}",
            "Content-Type": "application/json",
        }
    
    def _chunk_text(self, text: str) -> List[str]:
        """Split text into overlapping chunks."""
        words = text.split()
        if len(words) <= self.CHUNK_SIZE:
            return [text]
        
        chunks = []
        start = 0
        while start < len(words):
            end = start + self.CHUNK_SIZE
            chunks.append(" ".join(words[start:end]))
            start = end - self.CHUNK_OVERLAP
            if start >= len(words) - self.CHUNK_OVERLAP:
                break
        return chunks
    
    @log_operation(
        service="worker_embeddings",
        operation="generate_embedding",
        extract_input=lambda args, kwargs: {
            "text_length": len(kwargs.get("text", "") or (args[1] if len(args) > 1 else "")),
            "is_query": kwargs.get("is_query", True)
        },
        extract_output=lambda r: {"dimensions": len(r) if r else 0}
    )
    async def generate_embedding(self, text: str, is_query: bool = True) -> List[float]:
        """Generate embedding via Cloudflare Worker."""
        import httpx
        
        if not text or not text.strip():
            logger.debug("worker_embeddings.generate_embedding: empty text, returning zero vector")
            return [0.0] * self.DIMENSIONS
        
        # Add query prefix for better retrieval (BGE best practice)
        if is_query:
            text = self.QUERY_PREFIX + text
        
        # Truncate if too long
        words = text.split()
        if len(words) > 400:
            text = " ".join(words[:400])
            logger.debug(f"worker_embeddings: truncated to 400 words")
        
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(
                    f"{self.worker_url}/embed",
                    headers=self._get_headers(),
                    json={"text": text},
                )
                response.raise_for_status()
                data = response.json()
                embedding = data.get("embedding", [0.0] * self.DIMENSIONS)
                logger.debug(f"worker_embeddings: got {len(embedding)}-dim embedding")
                return embedding
        except Exception as e:
            logger.error(f"Worker embedding failed: {e}")
            return [0.0] * self.DIMENSIONS
    
    async def generate_embeddings_batch(self, texts: List[str], is_query: bool = False) -> List[List[float]]:
        """Generate embeddings for multiple texts via Worker."""
        import httpx
        
        if not texts:
            return []
        
        # Preprocess texts
        processed = []
        valid_indices = []
        for i, text in enumerate(texts):
            if text and text.strip():
                if is_query:
                    text = self.QUERY_PREFIX + text
                words = text.split()
                if len(words) > 400:
                    text = " ".join(words[:400])
                processed.append(text)
                valid_indices.append(i)
        
        if not processed:
            return [[0.0] * self.DIMENSIONS for _ in texts]
        
        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(
                    f"{self.worker_url}/embed-batch",
                    headers=self._get_headers(),
                    json={"texts": processed},
                )
                response.raise_for_status()
                data = response.json()
                embeddings = data.get("embeddings", [])
                
                # Map back to original indices (include empty texts as zero vectors)
                result = [[0.0] * self.DIMENSIONS for _ in texts]
                for i, emb in enumerate(embeddings):
                    if i < len(valid_indices):
                        result[valid_indices[i]] = emb
                
                logger.debug(f"worker_embeddings: batch generated {len(embeddings)} embeddings")
                return result
        except Exception as e:
            logger.error(f"Worker batch embedding failed: {e}")
            return [[0.0] * self.DIMENSIONS for _ in texts]
    
    async def process_document(self, markdown_content: str, title: Optional[str] = None) -> dict:
        """Process document with chunking, using Worker for embeddings."""
        logger.debug(f"worker_embeddings.process_document: content_length={len(markdown_content)}, has_title={bool(title)}")
        
        if not markdown_content:
            return {"document_embedding": [0.0] * self.DIMENSIONS, "chunks": []}
        
        # Prepare full text for document-level embedding
        full_text = f"{title}\n\n{markdown_content}" if title else markdown_content
        words = full_text.split()
        summary_text = " ".join(words[:1000]) if len(words) > 1000 else full_text
        
        # Chunk the content
        chunks = self._chunk_text(markdown_content)
        logger.debug(f"Content chunked into {len(chunks)} chunks")
        
        # Generate all embeddings in batch
        all_texts = [summary_text] + chunks
        all_embeddings = await self.generate_embeddings_batch(all_texts, is_query=False)
        
        document_embedding = all_embeddings[0]
        chunk_embeddings = all_embeddings[1:]
        
        chunk_data = [
            {"chunk_index": i, "content": chunk, "embedding": emb}
            for i, (chunk, emb) in enumerate(zip(chunks, chunk_embeddings))
        ]
        
        logger.debug(f"worker_embeddings.process_document: completed with {len(chunk_data)} chunks")
        
        return {"document_embedding": document_embedding, "chunks": chunk_data}


# =============================================================================
# Singleton instances
# =============================================================================

_embeddings_service = None
_worker_embeddings_service = None

def get_embeddings_service():
    """
    Get the embeddings service.
    
    Priority:
    1. If VECTORIZE_WORKER_URL is set -> Use Worker (production)
    2. If USE_LOCAL_EMBEDDINGS=true -> Use local BGE (development)
    3. Otherwise -> Use OpenAI
    """
    from app.core.config import get_settings
    settings = get_settings()
    
    # Production: use Worker if URL is configured
    if settings.vectorize_worker_url:
        global _worker_embeddings_service
        if _worker_embeddings_service is None:
            logger.info("Using Worker-based embeddings service")
            _worker_embeddings_service = WorkerEmbeddingsService()
        return _worker_embeddings_service
    
    # Development: use local BGE or OpenAI
    use_local = getattr(settings, 'use_local_embeddings', True)
    
    if use_local:
        from app.services.local_embeddings import get_local_embeddings_service
        return get_local_embeddings_service()
    else:
        global _embeddings_service
        if _embeddings_service is None:
            _embeddings_service = EmbeddingsService()
        return _embeddings_service

