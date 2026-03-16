"""
Local Embeddings Service
Uses BGE (BAAI General Embedding) for fast, high-quality local embeddings
"""
import asyncio
import logging
import time
import os
from typing import List, Optional
from concurrent.futures import ThreadPoolExecutor
from sentence_transformers import SentenceTransformer
from app.core.log_decorators import log_operation

logger = logging.getLogger(__name__)

# Shared thread pool for CPU-bound embedding operations
# Use a larger pool to handle concurrent requests better
# Note: Python GIL may still serialize, but it helps with I/O overlap
_embedding_executor = ThreadPoolExecutor(
    max_workers=int(os.environ.get("EMBEDDING_WORKERS", "10")), 
    thread_name_prefix="embedding"
)


class LocalEmbeddingsService:
    """
    Service for generating text embeddings using local BGE model.
    Much faster than OpenAI API (~50-100ms vs 2-3 seconds).
    """
    
    # BGE model configuration
    MODEL_NAME = "BAAI/bge-base-en-v1.5"
    DIMENSIONS = 768
    
    # Chunking parameters (same as OpenAI service for consistency)
    CHUNK_SIZE = 500  # tokens (approximate - using words as proxy)
    CHUNK_OVERLAP = 50  # tokens overlap between chunks
    
    # BGE uses instruction prefix for better retrieval
    QUERY_PREFIX = "Represent this sentence for searching relevant passages: "
    DOCUMENT_PREFIX = ""  # Documents don't need prefix for BGE
    
    _instance = None
    _model = None
    
    def __new__(cls):
        """Singleton pattern to avoid loading model multiple times"""
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance
    
    def __init__(self):
        if self._model is None:
            self._load_model()
    
    def _load_model(self):
        """Load the BGE model (lazy loading on first use)"""
        logger.info(f"Loading local embedding model: {self.MODEL_NAME}")
        start = time.time()
        
        self._model = SentenceTransformer(self.MODEL_NAME)
        
        # Use GPU if available
        device = self._model.device
        logger.info(f"Model loaded in {time.time() - start:.2f}s on device: {device}")
    
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
        service="local_embeddings",
        operation="generate_embedding",
        extract_input=lambda args, kwargs: {
            "text_length": len(kwargs.get("text", "") or (args[1] if len(args) > 1 else "")),
            "is_query": kwargs.get("is_query", True)
        },
        extract_output=lambda r: {"dimensions": len(r) if r else 0}
    )
    async def generate_embedding(self, text: str, is_query: bool = True) -> List[float]:
        """
        Generate embedding for a single text.
        
        Args:
            text: Text to embed
            is_query: If True, adds query prefix for better retrieval
        
        Returns:
            List of floats (768 dimensions for BGE-base)
        """
        if not text or not text.strip():
            logger.debug("local_embeddings.generate_embedding: empty text, returning zero vector")
            return [0.0] * self.DIMENSIONS
        
        # Add prefix for queries (BGE best practice)
        if is_query:
            text = self.QUERY_PREFIX + text
        
        # Truncate if too long (BGE supports up to 512 tokens)
        words = text.split()
        original_len = len(words)
        if len(words) > 400:
            text = " ".join(words[:400])
            logger.debug(f"local_embeddings.generate_embedding: truncated from {original_len} to 400 words")
        
        logger.debug(f"local_embeddings.generate_embedding: generating for {len(words)} words, is_query={is_query}")
        
        # Run model.encode in thread pool to avoid blocking the event loop
        # This is critical for concurrent request handling
        loop = asyncio.get_event_loop()
        embedding = await loop.run_in_executor(
            _embedding_executor,
            lambda: self._model.encode(text, normalize_embeddings=True)
        )
        
        logger.debug(f"local_embeddings.generate_embedding: completed, dim={len(embedding)}")
        return embedding.tolist()
    
    async def generate_embeddings_batch(
        self, 
        texts: List[str], 
        is_query: bool = False
    ) -> List[List[float]]:
        """
        Generate embeddings for multiple texts efficiently.
        
        Args:
            texts: List of texts to embed
            is_query: If True, adds query prefix to all texts
        
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
                if len(words) > 400:
                    text = " ".join(words[:400])
                
                # Add prefix for queries
                if is_query:
                    text = self.QUERY_PREFIX + text
                
                valid_texts.append(text)
                valid_indices.append(i)
        
        if not valid_texts:
            return [[0.0] * self.DIMENSIONS for _ in texts]
        
        # Run batch encode in thread pool to avoid blocking the event loop
        loop = asyncio.get_event_loop()
        embeddings = await loop.run_in_executor(
            _embedding_executor,
            lambda: self._model.encode(
                valid_texts, 
                normalize_embeddings=True,
                show_progress_bar=False
            )
        )
        
        # Map results back to original indices
        results = [[0.0] * self.DIMENSIONS for _ in texts]
        for i, embedding in enumerate(embeddings):
            original_index = valid_indices[i]
            results[original_index] = embedding.tolist()
        
        return results
    
    @log_operation(
        service="local_embeddings",
        operation="process_document",
        extract_input=lambda args, kwargs: {
            "content_length": len(kwargs.get("markdown_content", "") or (args[1] if len(args) > 1 else "")),
            "has_title": bool(kwargs.get("title")),
            "use_semantic": kwargs.get("use_semantic_chunking", None)
        },
        extract_output=lambda r: {"chunks_count": len(r.get("chunks", [])) if r else 0}
    )
    async def process_document(
        self,
        markdown_content: str,
        title: Optional[str] = None,
        use_semantic_chunking: Optional[bool] = None
    ) -> dict:
        """
        Process a document: chunk it and generate embeddings.
        
        Args:
            markdown_content: The document text
            title: Optional title to prepend
            use_semantic_chunking: If True, use Docling semantic chunking. 
                                   If None, use settings.use_semantic_chunking
        
        Returns:
            dict with document_embedding, chunks, and chunk_embeddings
        """
        # Use config setting if not explicitly specified
        if use_semantic_chunking is None:
            from app.core.config import get_settings
            use_semantic_chunking = get_settings().use_semantic_chunking
        
        logger.debug(f"local_embeddings.process_document: content_length={len(markdown_content)}, has_title={bool(title)}, use_semantic={use_semantic_chunking}")
        
        # Combine title and content for full document embedding
        full_text = f"{title}\n\n{markdown_content}" if title else markdown_content
        
        # Generate document-level embedding (for document-level search)
        # Documents don't use query prefix
        doc_embedding = await self.generate_embedding(full_text, is_query=False)
        logger.debug(f"Document embedding generated, dim={len(doc_embedding)}")
        
        # Chunk the content - use semantic chunking if available and enabled
        if use_semantic_chunking:
            try:
                from app.services.semantic_chunker import get_semantic_chunker
                semantic_chunker = get_semantic_chunker()
                
                if semantic_chunker.is_available:
                    # Use Docling semantic chunking
                    chunk_result = await semantic_chunker.chunk_from_markdown(
                        markdown_content=markdown_content,
                        title=title
                    )
                    
                    # Extract chunks from semantic chunker result
                    raw_chunks = chunk_result.get("chunks", [])
                    
                    if raw_chunks:
                        # Use contextualized content for embeddings (includes headers/metadata)
                        chunk_texts = [c.get("contextualized_content", c.get("content", "")) for c in raw_chunks]
                        logger.debug(f"Semantic chunking produced {len(chunk_texts)} chunks")
                        
                        # Generate embeddings for contextualized chunks
                        chunk_embeddings = await self.generate_embeddings_batch(chunk_texts, is_query=False)
                        
                        # Build chunk data with both raw content and contextualized version
                        chunk_data = [
                            {
                                "chunk_index": i,
                                "content": c.get("content", ""),
                                "contextualized_content": c.get("contextualized_content", ""),
                                "embedding": embedding,
                                "metadata": c.get("metadata", {})
                            }
                            for i, (c, embedding) in enumerate(zip(raw_chunks, chunk_embeddings))
                        ]
                        
                        logger.info(f"Semantic chunking complete: {len(chunk_data)} chunks, method={chunk_result.get('metadata', {}).get('chunking_method', 'unknown')}")
                        
                        return {
                            "document_embedding": doc_embedding,
                            "chunks": chunk_data,
                            "chunking_metadata": chunk_result.get("metadata", {})
                        }
                else:
                    logger.debug("Semantic chunker not available, falling back to simple chunking")
            except Exception as e:
                logger.warning(f"Semantic chunking failed, falling back to simple chunking: {e}")
        
        # Fallback: simple word-based chunking
        chunks = self._chunk_text(markdown_content)
        logger.debug(f"Simple chunking produced {len(chunks)} chunks")
        
        # Generate chunk embeddings (also without query prefix)
        chunk_embeddings = await self.generate_embeddings_batch(chunks, is_query=False)
        logger.debug(f"Chunk embeddings generated: {len(chunk_embeddings)} embeddings")
        
        # Combine chunks with their embeddings (same format as OpenAI embeddings service)
        chunk_data = [
            {
                "chunk_index": i,
                "content": chunk,
                "embedding": embedding
            }
            for i, (chunk, embedding) in enumerate(zip(chunks, chunk_embeddings))
        ]
        
        return {
            "document_embedding": doc_embedding,
            "chunks": chunk_data,
            "chunking_metadata": {
                "chunking_method": "simple_word",
                "chunk_count": len(chunks)
            }
        }


# Singleton instance
_local_embeddings_service = None

def get_local_embeddings_service() -> LocalEmbeddingsService:
    """Get the singleton LocalEmbeddingsService instance"""
    global _local_embeddings_service
    if _local_embeddings_service is None:
        _local_embeddings_service = LocalEmbeddingsService()
    return _local_embeddings_service
