import sys
sys.path.insert(0, 'C:\\Users\\ameet\\Documents\\NotesApp')

from langchain_core.embeddings import Embeddings
from app.services.local_embeddings import get_local_embeddings_service

class LocalEmbeddingsWrapper(Embeddings):
    """Wrapper to make local embeddings compatible with Langchain."""
    
    def __init__(self):
        self._local_embeddings = get_local_embeddings_service()
    
    def _generate_embedding_sync(self, text: str, is_query: bool = True) -> list[float]:
        """Generate embedding synchronously (bypasses async wrapper)."""
        if not text or not text.strip():
            return [0.0] * self._local_embeddings.DIMENSIONS
        
        # Add prefix for queries (BGE best practice)
        if is_query:
            text = self._local_embeddings.QUERY_PREFIX + text
        
        # Truncate if too long
        words = text.split()
        if len(words) > 400:
            text = " ".join(words[:400])
        
        # Generate embedding directly (model.encode is sync)
        embedding = self._local_embeddings._model.encode(text, normalize_embeddings=True)
        return embedding.tolist()
    
    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        """Embed a list of documents."""
        embeddings = []
        for text in texts:
            emb = self._generate_embedding_sync(text, is_query=False)
            embeddings.append(emb)
        return embeddings
    
    def embed_query(self, text: str) -> list[float]:
        """Embed a single query."""
        return self._generate_embedding_sync(text, is_query=True)

# Test
import numpy as np
from dotenv import load_dotenv
load_dotenv()

print("Testing LocalEmbeddingsWrapper...")
wrapper = LocalEmbeddingsWrapper()

# Test embed_query
print("\nTesting embed_query...")
result = wrapper.embed_query("test query")
print(f"Type: {type(result)}")
print(f"Is coroutine: {hasattr(result, '__await__')}")
print(f"Length: {len(result) if isinstance(result, list) else 'N/A'}")

# Test numpy conversion
print("\nTesting np.asarray...")
arr = np.asarray(result)
print(f"Array shape: {arr.shape}")
print(f"Array dtype: {arr.dtype}")

# Test embed_documents
print("\nTesting embed_documents...")
docs_result = wrapper.embed_documents(["doc 1", "doc 2"])
print(f"Type: {type(docs_result)}")
print(f"Length: {len(docs_result)}")

# Test numpy conversion
print("\nTesting np.asarray on documents...")
arr2 = np.asarray(docs_result)
print(f"Array shape: {arr2.shape}")

print("\n✅ All tests passed!")
