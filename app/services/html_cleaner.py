"""
HTML Cleaner Service
Detects HTML tables and converts them to clean markdown using Groq LLM (fast inference)
Falls back to OpenAI if Groq is not configured
"""
import re
import logging
import time
from typing import Optional
from openai import OpenAI
from app.core.config import get_settings
from app.core.log_decorators import log_operation

logger = logging.getLogger(__name__)


class HTMLCleanerService:
    """Service for cleaning HTML content using LLM (Groq for speed)"""
    
    # Regex patterns to detect HTML
    TABLE_PATTERN = re.compile(r'<table[^>]*>.*?</table>', re.DOTALL | re.IGNORECASE)
    HTML_TAG_PATTERN = re.compile(r'<[^>]+>')
    
    def __init__(self):
        settings = get_settings()
        # Use Groq for fast inference if available, fallback to OpenAI
        if settings.groq_api_key:
            self.client = OpenAI(
                base_url="https://api.groq.com/openai/v1",
                api_key=settings.groq_api_key
            )
            self.model = "llama-3.3-70b-versatile"  # Fast & capable
            self.provider = "Groq"
            logger.info("HTML Cleaner initialized with Groq (fast inference)")
        else:
            self.client = OpenAI(api_key=settings.openai_api_key)
            self.model = "gpt-4o-mini"
            self.provider = "OpenAI"
            logger.info("HTML Cleaner initialized with OpenAI")
    
    def has_html_content(self, content: str) -> bool:
        """Check if content contains HTML tables or significant HTML tags"""
        if not content:
            return False
        if self.TABLE_PATTERN.search(content):
            logger.debug(f"html_cleaner.has_html_content: HTML table detected")
            return True
        tag_count = len(self.HTML_TAG_PATTERN.findall(content))
        if tag_count > 10:
            logger.debug(f"html_cleaner.has_html_content: {tag_count} HTML tags detected")
            return True
        return False
    
    def convert_to_clean_markdown(self, content: str) -> str:
        """Use LLM to convert HTML content to clean markdown (Groq or OpenAI)"""
        try:
            max_chars = 30000
            truncated = content[:max_chars] if len(content) > max_chars else content
            
            logger.debug(f"=== HTML CLEANUP START === content_length={len(content)}, truncated_to={len(truncated)}")
            logger.debug(f"Using {self.provider} ({self.model}) for HTML to markdown conversion")
            start_time = time.time()
            
            response = self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {
                        "role": "system",
                        "content": """Convert HTML to clean markdown for semantic search.

Rules:
1. Convert HTML tables to markdown tables or readable list format
2. Preserve ALL information - do NOT summarize
3. Remove all HTML tags - output pure markdown/text
4. Remove empty paragraphs and excessive whitespace
5. Keep headings, lists, contact info, skills, dates, names

Output ONLY the converted markdown."""
                    },
                    {
                        "role": "user",
                        "content": f"Convert to clean markdown:\n\n{truncated}"
                    }
                ],
                temperature=0,
                max_tokens=8000
            )
            
            result = response.choices[0].message.content
            elapsed = time.time() - start_time
            logger.debug(f"=== HTML CLEANUP COMPLETE === input_len={len(content)}, output_len={len(result)}, duration={elapsed:.2f}s")
            return result
            
        except Exception as e:
            logger.error(f"LLM conversion failed: {str(e)}")
            logger.debug("Falling back to basic HTML stripping")
            return self._basic_html_strip(content)
    
    def _basic_html_strip(self, content: str) -> str:
        """Fallback: basic HTML tag removal if LLM fails"""
        content = re.sub(r'<script[^>]*>.*?</script>', '', content, flags=re.DOTALL | re.IGNORECASE)
        content = re.sub(r'<style[^>]*>.*?</style>', '', content, flags=re.DOTALL | re.IGNORECASE)
        content = re.sub(r'</?(p|div|tr|table|br)[^>]*>', '\n', content, flags=re.IGNORECASE)
        content = re.sub(r'</?(td|th)[^>]*>', ' ', content, flags=re.IGNORECASE)
        content = re.sub(r'<[^>]+>', '', content)
        content = re.sub(r'\n\s*\n+', '\n\n', content)
        return content.strip()
    
    @log_operation(
        service="html_cleaner",
        operation="clean_content",
        extract_input=lambda args, kwargs: {"content_length": len(kwargs.get("content", "") or (args[1] if len(args) > 1 else "")), "has_html": args[0].has_html_content(kwargs.get("content", "") or (args[1] if len(args) > 1 else "")) if args else False},
        extract_output=lambda r: {"output_length": len(r) if r else 0}
    )
    def clean_content(self, content: str) -> str:
        """Main entry: Clean content if it contains HTML"""
        if not content:
            logger.debug("html_cleaner.clean_content: empty content, returning as-is")
            return content
        if self.has_html_content(content):
            logger.debug(f"html_cleaner.clean_content: HTML detected in {len(content)} chars, starting LLM conversion")
            return self.convert_to_clean_markdown(content)
        logger.debug(f"html_cleaner.clean_content: no HTML detected in {len(content)} chars, returning as-is")
        return content


_html_cleaner: Optional[HTMLCleanerService] = None

def get_html_cleaner() -> HTMLCleanerService:
    global _html_cleaner
    if _html_cleaner is None:
        _html_cleaner = HTMLCleanerService()
    return _html_cleaner
