"""Quick test for spell check functionality"""
import asyncio
import sys
sys.path.insert(0, '.')

from app.services.rag_agent import RAGAgentService
from app.core.config import get_settings

async def test_spell_check():
    service = RAGAgentService()
    
    test_queries = [
        "show me my aadhar",  # Should correct to "aadhaar"
        "show me my adhar",   # Should correct to "aadhaar" 
        "show my aadhaar",    # Already correct
        "shwo my latset pan crad",  # Multiple typos
    ]
    
    for query in test_queries:
        corrected, was_corrected, explanation = await service._spell_check_query(query)
        print(f"\nOriginal: {query}")
        print(f"Corrected: {corrected}")
        print(f"Was Corrected: {was_corrected}")
        print(f"Explanation: {explanation}")
        print("-" * 50)

if __name__ == "__main__":
    asyncio.run(test_spell_check())
