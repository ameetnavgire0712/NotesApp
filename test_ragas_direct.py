"""Test RAGAS evaluation directly to trace the error."""
import sys
sys.path.insert(0, 'C:\\Users\\ameet\\Documents\\NotesApp')

import os
import asyncio
import numpy as np
from dotenv import load_dotenv
load_dotenv()

from langchain_core.embeddings import Embeddings
from langchain_groq import ChatGroq
from langchain_core.language_models.chat_models import BaseChatModel

from app.services.local_embeddings import get_local_embeddings_service

# Create wrapper classes
class GroqN1Wrapper(BaseChatModel):
    """Wrapper that forces n=1 for Groq API compatibility."""
    
    def __init__(self, wrapped_llm: ChatGroq):
        super().__init__()
        self._wrapped = wrapped_llm
    
    @property
    def _llm_type(self) -> str:
        return "groq-n1-wrapper"
    
    def _generate(self, messages, stop=None, run_manager=None, **kwargs):
        kwargs['n'] = 1
        return self._wrapped._generate(messages, stop=stop, run_manager=run_manager, **kwargs)
    
    async def _agenerate(self, messages, stop=None, run_manager=None, **kwargs):
        kwargs['n'] = 1
        return await self._wrapped._agenerate(messages, stop=stop, run_manager=run_manager, **kwargs)
    
    def bind(self, **kwargs):
        kwargs['n'] = 1
        return GroqN1Wrapper(self._wrapped.bind(**kwargs))
    
    @property
    def _identifying_params(self):
        return self._wrapped._identifying_params


class LocalEmbeddingsWrapper(Embeddings):
    """Wrapper to make local embeddings compatible with Langchain."""
    
    def __init__(self):
        self._local_embeddings = get_local_embeddings_service()
        print(f"[DEBUG] LocalEmbeddingsWrapper initialized with model: {type(self._local_embeddings._model)}")
    
    def _generate_embedding_sync(self, text: str, is_query: bool = True) -> list[float]:
        """Generate embedding synchronously."""
        print(f"[DEBUG] _generate_embedding_sync called, is_query={is_query}, text_len={len(text)}")
        if not text or not text.strip():
            return [0.0] * self._local_embeddings.DIMENSIONS
        
        if is_query:
            text = self._local_embeddings.QUERY_PREFIX + text
        
        words = text.split()
        if len(words) > 400:
            text = " ".join(words[:400])
        
        embedding = self._local_embeddings._model.encode(text, normalize_embeddings=True)
        result = embedding.tolist()
        print(f"[DEBUG] _generate_embedding_sync returning list of length {len(result)}")
        return result
    
    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        """Embed a list of documents."""
        print(f"[DEBUG] embed_documents called with {len(texts)} texts")
        embeddings = []
        for text in texts:
            emb = self._generate_embedding_sync(text, is_query=False)
            embeddings.append(emb)
        print(f"[DEBUG] embed_documents returning list of {len(embeddings)} embeddings")
        return embeddings
    
    def embed_query(self, text: str) -> list[float]:
        """Embed a single query."""
        print(f"[DEBUG] embed_query called with text: {text[:50]}...")
        result = self._generate_embedding_sync(text, is_query=True)
        print(f"[DEBUG] embed_query returning type: {type(result)}, len: {len(result)}")
        return result


# Test answer_relevancy metric directly
print("=" * 80)
print("Testing answer_relevancy metric directly...")
print("=" * 80)

from ragas import evaluate
from ragas.metrics import answer_relevancy
from ragas.llms import LangchainLLMWrapper
from datasets import Dataset

# Create LLM
groq_llm = ChatGroq(
    model="llama-3.3-70b-versatile",
    api_key=os.getenv('GROQ_API_KEY'),
    temperature=0
)
wrapped_llm = GroqN1Wrapper(groq_llm)
ragas_llm = LangchainLLMWrapper(wrapped_llm)

# Create embeddings
local_embeddings = LocalEmbeddingsWrapper()

# Configure metric
answer_relevancy.llm = ragas_llm
answer_relevancy.embeddings = local_embeddings

print("\n[DEBUG] Testing embeddings directly...")
test_emb = local_embeddings.embed_query("What is your name?")
print(f"[DEBUG] Direct embed_query returned: type={type(test_emb)}, len={len(test_emb)}")

# Test the calculate_similarity function directly
print("\n[DEBUG] Testing calculate_similarity directly...")
question = "What is your name?"
generated_questions = ["What is your name?", "Who are you?"]

print(f"[DEBUG] Calling answer_relevancy.calculate_similarity...")
try:
    sim_result = answer_relevancy.calculate_similarity(question, generated_questions)
    print(f"[DEBUG] Similarity result: {sim_result}")
except Exception as e:
    print(f"[DEBUG] ERROR in calculate_similarity: {type(e).__name__}: {e}")
    import traceback
    traceback.print_exc()

print("\n" + "=" * 80)
print("Now testing full RAGAS evaluation...")
print("=" * 80)

# Create a simple test dataset
test_data = {
    "user_input": ["whats my pan card number"],
    "response": ["Your PAN card number is AGTPN1235H."],
    "retrieved_contexts": [["Income Tax Department PAN Card. Permanent Account Number: AGTPN1235H. Name: Amit Suryakant Navgire."]],
    "reference": ["AGTPN1235H"]
}

dataset = Dataset.from_dict(test_data)
print(f"[DEBUG] Created test dataset with {len(dataset)} samples")

# Run evaluation with just answer_relevancy
print("\n[DEBUG] Running RAGAS evaluation...")
try:
    result = evaluate(
        dataset=dataset,
        metrics=[answer_relevancy],
        raise_exceptions=True  # Raise to see full traceback
    )
    print(f"[DEBUG] Evaluation result: {result}")
except Exception as e:
    print(f"[DEBUG] ERROR in evaluation: {type(e).__name__}: {e}")
    import traceback
    traceback.print_exc()

print("\n" + "=" * 80)
print("Full test complete!")
