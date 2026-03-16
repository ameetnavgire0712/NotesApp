"""
Test script for semantic chunking with Docling
"""
import asyncio
import sys
sys.path.insert(0, 'c:\\Users\\ameet\\Documents\\NotesApp')

from app.services.semantic_chunker import get_semantic_chunker, warmup_semantic_chunker


TEST_MARKDOWN = """
# Introduction to Machine Learning

Machine learning is a subset of artificial intelligence (AI) that provides systems the ability 
to automatically learn and improve from experience without being explicitly programmed.

## Types of Machine Learning

### Supervised Learning

Supervised learning is where you have input variables (x) and an output variable (Y) and you 
use an algorithm to learn the mapping function from the input to the output.

The goal is to approximate the mapping function so well that when you have new input data (x) 
that you can predict the output variables (Y) for that data.

Examples include:
- Classification: Predicting discrete class labels
- Regression: Predicting continuous quantities

### Unsupervised Learning

Unsupervised learning is where you only have input data (X) and no corresponding output variables.
The goal for unsupervised learning is to model the underlying structure or distribution in the 
data in order to learn more about the data.

Examples include:
- Clustering: Discovering the inherent groupings in the data
- Association: Discovering rules that describe large portions of data

### Reinforcement Learning

Reinforcement learning is an area of machine learning concerned with how intelligent agents 
ought to take actions in an environment in order to maximize the notion of cumulative reward.

The agent learns from the consequences of its actions, rather than from being explicitly taught.

## Applications

Machine learning has many practical applications:
- Email filtering
- Image recognition
- Speech recognition
- Medical diagnosis
- Financial predictions

## Conclusion

Machine learning continues to grow and evolve, enabling computers to tackle increasingly 
complex problems that were once thought to require human intelligence.
"""


async def test_semantic_chunking():
    print("=" * 60)
    print("Testing Semantic Chunking with Docling")
    print("=" * 60)
    
    # Warmup
    print("\n1. Warming up semantic chunker...")
    is_available = await warmup_semantic_chunker()
    print(f"   Semantic chunker available: {is_available}")
    
    if not is_available:
        print("\n❌ Docling not available. Install with:")
        print("   pip install docling docling-core[chunking]")
        return
    
    # Get chunker
    chunker = get_semantic_chunker()
    
    # Test markdown chunking
    print("\n2. Testing markdown chunking...")
    print(f"   Input: {len(TEST_MARKDOWN)} chars")
    
    result = await chunker.chunk_from_markdown(
        markdown_content=TEST_MARKDOWN,
        title="ML Tutorial"
    )
    
    chunks = result.get("chunks", [])
    metadata = result.get("metadata", {})
    
    print(f"\n3. Results:")
    print(f"   Chunking method: {metadata.get('chunking_method', 'unknown')}")
    print(f"   Number of chunks: {len(chunks)}")
    print(f"   Max tokens setting: {metadata.get('max_tokens', 'N/A')}")
    print(f"   Processing time: {metadata.get('processing_time_ms', 'N/A')}ms")
    
    print("\n4. Chunk details:")
    for i, chunk in enumerate(chunks):
        content = chunk.get("content", "")[:80].replace("\n", " ")
        context = chunk.get("contextualized_content", "")[:100].replace("\n", " ")
        tokens = chunk.get("token_count", 0)
        print(f"\n   Chunk {i}:")
        print(f"      Tokens: {tokens}")
        print(f"      Content preview: {content}...")
        print(f"      Context preview: {context}...")
    
    print("\n" + "=" * 60)
    print("✅ Semantic chunking test complete!")
    print("=" * 60)


if __name__ == "__main__":
    asyncio.run(test_semantic_chunking())
