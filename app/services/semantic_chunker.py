"""
Semantic Chunking Service using Docling
Provides document-aware chunking that preserves semantic meaning and document structure.

Key Features:
- Uses Docling's HybridChunker for tokenization-aware semantic chunking
- Preserves document hierarchy (headers, sections, captions)
- Merges undersized peer chunks for better context
- Contextualizes chunks with metadata (section headers, titles)
- Aligns tokenization with BGE embedding model for optimal retrieval
"""
import io
import logging
import time
from typing import List, Optional, Dict, Any, Iterator
from pathlib import Path
import tempfile
import os

logger = logging.getLogger(__name__)

# Try to import docling - will be None if not installed
try:
    from docling.document_converter import DocumentConverter
    from docling.chunking import HybridChunker
    from docling_core.transforms.chunker.tokenizer.huggingface import HuggingFaceTokenizer
    from transformers import AutoTokenizer
    DOCLING_AVAILABLE = True
    logger.info("Docling imported successfully")
except ImportError as e:
    DOCLING_AVAILABLE = False
    logger.warning(f"Docling not available: {e}. Using fallback chunking.")


class SemanticChunker:
    """
    Semantic chunking service using Docling's HybridChunker.
    
    Best Practices (from Docling documentation):
    1. Use HybridChunker for RAG - combines hierarchical structure with tokenization awareness
    2. Align tokenizer with embedding model (BGE-base uses 512 max tokens)
    3. Use contextualize() to get metadata-enriched text for embedding
    4. merge_peers=True (default) merges undersized adjacent chunks with same context
    """
    
    # Configuration aligned with BGE embedding model
    EMBED_MODEL_ID = "BAAI/bge-base-en-v1.5"
    MAX_TOKENS = 512  # BGE supports 512 max - larger chunks = fewer fragments, better context
    MIN_CHUNK_TOKENS = 64  # Minimum tokens to avoid very small chunks
    
    _instance = None
    _chunker = None
    _converter = None
    _tokenizer = None
    
    def __new__(cls):
        """Singleton pattern"""
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance
    
    def __init__(self):
        if not DOCLING_AVAILABLE:
            logger.warning("Docling not available - semantic chunking disabled")
            return
            
        if self._chunker is None:
            self._initialize()
    
    def _initialize(self):
        """Initialize Docling components lazily"""
        if not DOCLING_AVAILABLE:
            return
            
        logger.info(f"Initializing semantic chunker with model: {self.EMBED_MODEL_ID}")
        start = time.time()
        
        try:
            # Initialize HuggingFace tokenizer aligned with BGE
            hf_tokenizer = AutoTokenizer.from_pretrained(self.EMBED_MODEL_ID)
            self._tokenizer = HuggingFaceTokenizer(
                tokenizer=hf_tokenizer,
                max_tokens=self.MAX_TOKENS
            )
            
            # Initialize HybridChunker with tokenizer
            self._chunker = HybridChunker(
                tokenizer=self._tokenizer,
                merge_peers=True,  # Merge undersized adjacent chunks with same context
            )
            
            # Initialize document converter
            self._converter = DocumentConverter()
            
            logger.info(f"Semantic chunker initialized in {time.time() - start:.2f}s")
            
        except Exception as e:
            logger.error(f"Failed to initialize semantic chunker: {e}")
            self._chunker = None
            self._tokenizer = None
            self._converter = None
    
    @property
    def is_available(self) -> bool:
        """Check if semantic chunking is available"""
        return DOCLING_AVAILABLE and self._chunker is not None
    
    def get_supported_extensions(self) -> set:
        """Get file extensions supported by Docling"""
        return {
            '.pdf', '.docx', '.xlsx', '.pptx',  # Office formats
            '.md', '.markdown',  # Markdown
            '.html', '.htm', '.xhtml',  # Web formats
            '.csv',  # Data formats
            '.txt',  # Plain text
            '.png', '.jpg', '.jpeg', '.tiff', '.bmp', '.webp'  # Images (OCR)
        }
    
    def is_format_supported(self, filename: str) -> bool:
        """Check if file format is supported by Docling"""
        if not filename:
            return False
        ext = Path(filename).suffix.lower()
        return ext in self.get_supported_extensions()
    
    async def chunk_from_bytes(
        self,
        file_content: bytes,
        filename: str,
        title: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Convert document from bytes and chunk semantically.
        
        Args:
            file_content: Raw file bytes
            filename: Original filename (used to detect format)
            title: Optional title to include in context
            
        Returns:
            Dict with:
                - chunks: List of chunk dicts with content, context, and metadata
                - document_text: Full document text
                - metadata: Document metadata
        """
        if not self.is_available:
            logger.warning("Semantic chunker not available, using fallback")
            return await self._fallback_chunk_bytes(file_content, filename, title)
        
        start = time.time()
        logger.debug(f"semantic_chunker.chunk_from_bytes: {filename}, {len(file_content)} bytes")
        
        try:
            # Write to temp file (Docling works with file paths)
            ext = Path(filename).suffix.lower() if filename else '.txt'
            with tempfile.NamedTemporaryFile(delete=False, suffix=ext) as tmp:
                tmp.write(file_content)
                tmp_path = tmp.name
            
            try:
                # Convert document using Docling
                conv_start = time.time()
                result = self._converter.convert(source=tmp_path)
                docling_doc = result.document
                logger.debug(f"Document converted in {time.time() - conv_start:.2f}s")
                
                # Apply semantic chunking
                chunk_start = time.time()
                chunks = self._process_chunks(docling_doc, title)
                logger.debug(f"Chunking completed in {time.time() - chunk_start:.2f}s")
                
                # Get full document text
                document_text = docling_doc.export_to_markdown()
                
                total_time = time.time() - start
                logger.info(
                    f"⏱️ Semantic chunking completed: {len(chunks)} chunks, "
                    f"{len(document_text)} chars, {total_time:.2f}s total"
                )
                
                return {
                    "chunks": chunks,
                    "document_text": document_text,
                    "metadata": {
                        "chunking_method": "docling_hybrid",
                        "chunk_count": len(chunks),
                        "max_tokens": self.MAX_TOKENS,
                        "processing_time_ms": int(total_time * 1000)
                    }
                }
                
            finally:
                # Clean up temp file
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass
                    
        except Exception as e:
            logger.error(f"Semantic chunking failed: {e}, falling back to simple chunking")
            return await self._fallback_chunk_bytes(file_content, filename, title)
    
    async def chunk_from_markdown(
        self,
        markdown_content: str,
        title: Optional[str] = None,
        source_filename: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Chunk markdown content semantically.
        
        This is useful when content has already been converted to markdown
        (e.g., by TensorLake) but we want semantic chunking.
        
        Args:
            markdown_content: Markdown text
            title: Optional title for context
            source_filename: Original source filename for metadata
            
        Returns:
            Dict with chunks, document_text, and metadata
        """
        if not self.is_available:
            return await self._fallback_chunk_text(markdown_content, title)
        
        if not markdown_content or not markdown_content.strip():
            return {
                "chunks": [],
                "document_text": "",
                "metadata": {"chunking_method": "empty"}
            }
        
        start = time.time()
        logger.debug(f"semantic_chunker.chunk_from_markdown: {len(markdown_content)} chars")
        
        try:
            # Write markdown to temp file
            with tempfile.NamedTemporaryFile(
                delete=False, 
                suffix='.md',
                mode='w',
                encoding='utf-8'
            ) as tmp:
                # Optionally prepend title as heading
                content = markdown_content
                if title:
                    content = f"# {title}\n\n{markdown_content}"
                tmp.write(content)
                tmp_path = tmp.name
            
            try:
                # Convert markdown using Docling
                result = self._converter.convert(source=tmp_path)
                docling_doc = result.document
                
                # Apply semantic chunking
                chunks = self._process_chunks(docling_doc, None)  # Title already in content
                
                total_time = time.time() - start
                logger.info(
                    f"⏱️ Markdown semantic chunking: {len(chunks)} chunks, {total_time:.2f}s"
                )
                
                return {
                    "chunks": chunks,
                    "document_text": markdown_content,
                    "metadata": {
                        "chunking_method": "docling_hybrid",
                        "chunk_count": len(chunks),
                        "source_filename": source_filename,
                        "max_tokens": self.MAX_TOKENS,
                        "processing_time_ms": int(total_time * 1000)
                    }
                }
                
            finally:
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass
                    
        except Exception as e:
            logger.error(f"Markdown semantic chunking failed: {e}")
            return await self._fallback_chunk_text(markdown_content, title)
    
    def _process_chunks(
        self, 
        docling_doc, 
        title: Optional[str] = None
    ) -> List[Dict[str, Any]]:
        """
        Process Docling document into chunks with metadata.
        
        Args:
            docling_doc: Docling Document object
            title: Optional title to prepend to context
            
        Returns:
            List of chunk dicts with content, contextualized_content, and metadata
        """
        chunks = []
        
        for i, chunk in enumerate(self._chunker.chunk(dl_doc=docling_doc)):
            # Get raw chunk text
            chunk_text = chunk.text
            
            # Get contextualized text (includes headers, captions)
            contextualized = self._chunker.contextualize(chunk=chunk)
            
            # Optionally prepend document title
            if title and not contextualized.startswith(title):
                contextualized = f"{title}\n{contextualized}"
            
            # Count tokens
            token_count = self._tokenizer.count_tokens(contextualized)
            
            # Extract metadata from chunk
            chunk_meta = self._extract_chunk_metadata(chunk, i)
            
            chunks.append({
                "chunk_index": i,
                "content": chunk_text,
                "contextualized_content": contextualized,  # This is what we embed
                "token_count": token_count,
                "metadata": chunk_meta
            })
        
        return chunks
    
    def _extract_chunk_metadata(self, chunk, index: int) -> Dict[str, Any]:
        """Extract metadata from a Docling chunk"""
        meta = {
            "index": index,
        }
        
        # Try to extract heading/section info if available
        try:
            if hasattr(chunk, 'meta') and chunk.meta:
                if hasattr(chunk.meta, 'headings') and chunk.meta.headings:
                    meta["headings"] = chunk.meta.headings
                if hasattr(chunk.meta, 'captions') and chunk.meta.captions:
                    meta["captions"] = chunk.meta.captions
        except Exception:
            pass
        
        return meta
    
    async def _fallback_chunk_bytes(
        self, 
        file_content: bytes, 
        filename: str,
        title: Optional[str] = None
    ) -> Dict[str, Any]:
        """Fallback chunking when Docling is not available"""
        try:
            # Try to decode as text
            try:
                text = file_content.decode('utf-8')
            except UnicodeDecodeError:
                text = file_content.decode('latin-1', errors='replace')
            
            return await self._fallback_chunk_text(text, title)
        except Exception as e:
            logger.error(f"Fallback chunking failed: {e}")
            return {
                "chunks": [],
                "document_text": "",
                "metadata": {"chunking_method": "failed", "error": str(e)}
            }
    
    async def _fallback_chunk_text(
        self, 
        text: str, 
        title: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Simple word-based chunking fallback.
        Uses same parameters as current implementation for consistency.
        """
        CHUNK_SIZE = 500  # words
        CHUNK_OVERLAP = 50
        
        if not text or not text.strip():
            return {
                "chunks": [],
                "document_text": "",
                "metadata": {"chunking_method": "empty"}
            }
        
        words = text.split()
        chunks = []
        
        if len(words) <= CHUNK_SIZE:
            # Single chunk
            content = text
            contextualized = f"{title}\n\n{content}" if title else content
            chunks.append({
                "chunk_index": 0,
                "content": content,
                "contextualized_content": contextualized,
                "token_count": int(len(words) * 1.3),
                "metadata": {"index": 0}
            })
        else:
            # Multiple chunks
            start = 0
            chunk_idx = 0
            
            while start < len(words):
                end = start + CHUNK_SIZE
                chunk_words = words[start:end]
                content = " ".join(chunk_words)
                contextualized = f"{title}\n\n{content}" if title else content
                
                chunks.append({
                    "chunk_index": chunk_idx,
                    "content": content,
                    "contextualized_content": contextualized,
                    "token_count": int(len(chunk_words) * 1.3),
                    "metadata": {"index": chunk_idx}
                })
                
                chunk_idx += 1
                start = end - CHUNK_OVERLAP
                
                if start >= len(words) - CHUNK_OVERLAP:
                    break
        
        return {
            "chunks": chunks,
            "document_text": text,
            "metadata": {
                "chunking_method": "fallback_word",
                "chunk_count": len(chunks),
                "chunk_size": CHUNK_SIZE,
                "chunk_overlap": CHUNK_OVERLAP
            }
        }


# Singleton instance
_semantic_chunker = None


def get_semantic_chunker() -> SemanticChunker:
    """Get or create the semantic chunker singleton"""
    global _semantic_chunker
    if _semantic_chunker is None:
        _semantic_chunker = SemanticChunker()
    return _semantic_chunker


async def warmup_semantic_chunker():
    """
    Warmup function to pre-load Docling models.
    Call during server startup to avoid cold start latency.
    """
    logger.info("Warming up semantic chunker...")
    start = time.time()
    
    chunker = get_semantic_chunker()
    
    if chunker.is_available:
        # Do a small test chunk to ensure everything is loaded
        test_result = await chunker.chunk_from_markdown(
            "This is a test document for warmup.",
            title="Test"
        )
        logger.info(
            f"Semantic chunker warmup complete in {time.time() - start:.2f}s, "
            f"available={chunker.is_available}"
        )
    else:
        logger.warning(
            f"Semantic chunker warmup skipped (not available), took {time.time() - start:.2f}s"
        )
    
    return chunker.is_available
