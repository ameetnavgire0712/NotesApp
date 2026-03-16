"""
Title Generator Service
Uses LLM to generate descriptive titles for documents
"""
import logging
from groq import Groq
from app.core.config import get_settings

logger = logging.getLogger(__name__)


class TitleGeneratorService:
    """
    Generates descriptive titles for documents using Groq LLM.
    """
    
    MODEL = "llama-3.3-70b-versatile"
    MAX_CONTENT_CHARS = 4000  # Limit content to first 4000 chars for title generation
    
    def __init__(self):
        settings = get_settings()
        self.client = Groq(api_key=settings.groq_api_key)
    
    async def generate_title(self, content_markdown: str, filename: str = None) -> str:
        """
        Generate a descriptive title for the document content.
        
        Args:
            content_markdown: The markdown content of the document
            filename: Optional original filename for context
            
        Returns:
            A descriptive title (50-150 characters) summarizing the document
        """
        import time
        
        logger.debug(f"=== TITLE GENERATION START === content_length={len(content_markdown)}, filename={filename}")
        
        try:
            # Truncate content if too long
            content_preview = content_markdown[:self.MAX_CONTENT_CHARS]
            if len(content_markdown) > self.MAX_CONTENT_CHARS:
                content_preview += "\n...[content truncated]..."
                logger.debug(f"Content truncated from {len(content_markdown)} to {self.MAX_CONTENT_CHARS} chars")
            
            # Build the prompt
            filename_hint = f"Original filename: {filename}\n" if filename else ""
            
            prompt = f"""Analyze this document and generate a descriptive title/summary that captures what it contains. This will be used for document retrieval and search.

{filename_hint}
Document content:
---
{content_preview}
---

Requirements for the title:
1. Start with the document type and main subject (e.g., "Resume of Amit Navgire - ...")
2. Include the person's name if identifiable
3. Summarize key topics: roles, skills, companies, expertise areas, or main themes
4. Be specific enough that someone searching could find this document
5. Length: 150-250 characters (detailed but concise)
6. Do NOT include quotes around the title
7. Use natural language, not bullet points

Example format:
"Resume of Amit Navgire - Data Architect & AI COE Lead with 17+ years experience in enterprise data engineering, AI/ML solutions, and cloud architecture. Worked at Centric Consulting, MSC Software, and other companies."

Generate ONLY the title, nothing else:"""

            logger.debug(f"Calling Groq LLM ({self.MODEL}) for title generation")
            start_time = time.time()
            
            response = self.client.chat.completions.create(
                model=self.MODEL,
                messages=[
                    {
                        "role": "system",
                        "content": "You are a document analyst. Generate concise, descriptive titles for documents."
                    },
                    {
                        "role": "user", 
                        "content": prompt
                    }
                ],
                temperature=0.3,
                max_tokens=100
            )
            
            elapsed = time.time() - start_time
            title = response.choices[0].message.content.strip()
            
            # Remove any quotes if present
            title = title.strip('"\'')
            
            # Ensure reasonable length (now allowing up to 300 chars)
            if len(title) > 300:
                title = title[:297] + "..."
            
            logger.debug(f"=== TITLE GENERATION COMPLETE === title='{title[:80]}...', duration={elapsed:.2f}s")
            return title
            
        except Exception as e:
            logger.error(f"Title generation failed: {e}")
            # Fallback to filename or generic title
            if filename:
                logger.debug(f"Using fallback title from filename: {filename}")
                return f"Document: {filename}"
            return "Untitled Document"


# Singleton instance
_title_generator_service = None

def get_title_generator_service() -> TitleGeneratorService:
    global _title_generator_service
    if _title_generator_service is None:
        _title_generator_service = TitleGeneratorService()
    return _title_generator_service
