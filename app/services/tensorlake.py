"""
Tensorlake Service
Converts uploaded files (images, PDFs, docs) to markdown format using Tensorlake v2 API
"""
import httpx
import asyncio
import logging
from typing import Optional
from app.core.config import get_settings
from app.services.html_cleaner import get_html_cleaner
from app.core.log_decorators import log_operation

# Set up logging
logger = logging.getLogger(__name__)


class TensorlakeService:
    """Service for converting documents to markdown using Tensorlake API v2"""
    
    BASE_URL = "https://api.tensorlake.ai/documents/v2"
    
    def __init__(self):
        settings = get_settings()
        self.api_key = settings.tensorlake_api_key
        self.headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        # Reusable HTTP client for connection pooling
        self._client: Optional[httpx.AsyncClient] = None
    
    async def _get_client(self) -> httpx.AsyncClient:
        """Get or create reusable HTTP client with optimized settings"""
        if self._client is None or self._client.is_closed:
            # Use HTTP/2 if available, keep connections alive
            self._client = httpx.AsyncClient(
                timeout=httpx.Timeout(120.0, connect=10.0),
                http2=True,  # Enable HTTP/2 for multiplexing
                limits=httpx.Limits(max_keepalive_connections=5, keepalive_expiry=30.0)
            )
        return self._client
    
    async def _upload_file(self, file_content: bytes, filename: str, content_type: str) -> Optional[str]:
        """Upload file to Tensorlake and get file_id"""
        logger.debug(f"tensorlake._upload_file: filename={filename}, content_type={content_type}, size={len(file_content)} bytes")
        client = await self._get_client()
        response = await client.put(
            f"{self.BASE_URL}/files",
            headers={"Authorization": f"Bearer {self.api_key}"},
            files={"file_bytes": (filename, file_content, content_type)}
        )
        response.raise_for_status()
        result = response.json()
        logger.debug(f"tensorlake._upload_file: response={result}")
        return result.get("file_id")
    
    async def _start_parse(self, file_id: str, mime_type: Optional[str] = None) -> Optional[str]:
        """Start a parse job and get parse_id"""
        logger.debug(f"tensorlake._start_parse: file_id={file_id}, mime_type={mime_type}")
        client = await self._get_client()
        payload = {"file_id": file_id}
        if mime_type:
            payload["mime_type"] = mime_type
        
        response = await client.post(
            f"{self.BASE_URL}/read",
            headers=self.headers,
            json=payload
        )
        response.raise_for_status()
        result = response.json()
        logger.debug(f"tensorlake._start_parse: parse_id={result.get('parse_id')}")
        return result.get("parse_id")
    
    async def _get_parse_result(self, parse_id: str, max_attempts: int = 60) -> dict:
        """Poll for parse results with aggressive initial delays for faster response"""
        client = await self._get_client()
        for attempt in range(max_attempts):
            response = await client.get(
                f"{self.BASE_URL}/parse/{parse_id}",
                headers={"Authorization": f"Bearer {self.api_key}"}
            )
            response.raise_for_status()
            result = response.json()
            
            status = result.get("status", "").lower()
            
            # Only log every few attempts to reduce noise
            if attempt < 3 or attempt % 5 == 0:
                logger.info(f"Tensorlake poll attempt {attempt + 1}: status={status}")
            
            # Check for completion - status is "successful" per docs
            if status == "successful":
                logger.info("Tensorlake API returned successful - extracting content from response")
                
                # Extract markdown from chunks
                chunks = result.get("chunks", [])
                if chunks:
                    markdown_parts = [chunk.get("content", chunk.get("text", "")) for chunk in chunks]
                    markdown = "\n\n".join(filter(None, markdown_parts))
                else:
                    # Try pages if no chunks
                    pages = result.get("pages", [])
                    if pages:
                        markdown_parts = []
                        for page in pages:
                            fragments = page.get("page_fragments", [])
                            for frag in fragments:
                                content = frag.get("content", "")
                                if content:
                                    markdown_parts.append(content)
                        markdown = "\n\n".join(markdown_parts)
                    else:
                        markdown = result.get("markdown", result.get("content", ""))
                
                logger.info(f"Tensorlake content extracted, raw length: {len(markdown)}")
                
                # Clean HTML content using LLM if needed
                html_cleaner = get_html_cleaner()
                logger.info("Starting HTML cleaning (LLM if HTML detected)...")
                markdown = html_cleaner.clean_content(markdown)
                
                logger.info(f"Content processing complete, final markdown length: {len(markdown)}")
                
                return {
                    "success": True,
                    "markdown": markdown or "[No content extracted]",
                    "metadata": result.get("metadata", {}),
                    "page_count": result.get("total_pages", result.get("parsed_pages_count", 1))
                }
            elif status == "failure":
                error_msg = result.get("error", result.get("message", "Parse job failed"))
                logger.error(f"Tensorlake parse failed: {error_msg}")
                return {
                    "success": False,
                    "markdown": "",
                    "error": error_msg,
                    "metadata": {}
                }
            
            # Still processing - use aggressive adaptive delay
            # Small files often complete in < 2 seconds
            if attempt < 3:
                delay = 0.1  # First 3 attempts: 100ms (catch fast responses)
            elif attempt < 8:
                delay = 0.3  # Next 5 attempts: 300ms
            elif attempt < 15:
                delay = 0.5  # Next 7 attempts: 500ms
            elif attempt < 30:
                delay = 1.0  # Next 15 attempts: 1s  
            else:
                delay = 2.0  # Remaining: 2s for large files
            await asyncio.sleep(delay)
        
        logger.error(f"Tensorlake parse timed out after {max_attempts} attempts")
        return {
            "success": False,
            "markdown": "",
            "error": "Parse job timed out",
            "metadata": {}
        }
    
    @log_operation(
        service="tensorlake",
        operation="convert_to_markdown",
        extract_input=lambda args, kwargs: {"filename": kwargs.get("filename") or (args[2] if len(args) > 2 else None), "content_type": kwargs.get("content_type"), "size_bytes": len(args[1]) if len(args) > 1 and isinstance(args[1], bytes) else 0},
        extract_output=lambda r: {"success": r.get("success"), "page_count": r.get("page_count", 1), "markdown_length": len(r.get("markdown", "")), "error": r.get("error") if not r.get("success") else None}
    )
    async def convert_to_markdown(
        self,
        file_content: bytes,
        filename: str,
        content_type: Optional[str] = None
    ) -> dict:
        """
        Convert a document to markdown using Tensorlake API v2
        
        Args:
            file_content: Raw bytes of the file
            filename: Name of the file (used to determine type)
            content_type: MIME type of the file
        
        Returns:
            dict with markdown content and metadata
        """
        try:
            logger.debug(f"=== TENSORLAKE CONVERSION START === filename={filename}, content_type={content_type}, size={len(file_content)} bytes")
            
            # Step 1: Upload file
            file_id = await self._upload_file(
                file_content, 
                filename, 
                content_type or "application/octet-stream"
            )
            
            if not file_id:
                logger.error("Failed to get file_id from Tensorlake upload")
                return {
                    "success": False,
                    "markdown": "",
                    "error": "Failed to upload file to Tensorlake",
                    "metadata": {}
                }
            
            logger.debug(f"Step 1 complete: file_id={file_id}")
            
            # Step 2: Start parse job
            parse_id = await self._start_parse(file_id, content_type)
            
            if not parse_id:
                logger.error("Failed to get parse_id from Tensorlake")
                return {
                    "success": False,
                    "markdown": "",
                    "error": "Failed to start parse job",
                    "metadata": {}
                }
            
            logger.debug(f"Step 2 complete: parse_id={parse_id}, starting polling...")
            
            # Step 3: Poll for results
            result = await self._get_parse_result(parse_id)
            logger.debug(f"=== TENSORLAKE CONVERSION COMPLETE === success={result.get('success')}, markdown_len={len(result.get('markdown', ''))}")
            return result
            
        except httpx.HTTPStatusError as e:
            error_detail = ""
            try:
                error_detail = e.response.json()
            except Exception:
                error_detail = e.response.text
            
            return {
                "success": False,
                "markdown": "",
                "error": f"Tensorlake API error: {e.response.status_code} - {error_detail}",
                "metadata": {}
            }
        except Exception as e:
            return {
                "success": False,
                "markdown": "",
                "error": f"Tensorlake conversion failed: {str(e)}",
                "metadata": {}
            }
    
    @log_operation(
        service="tensorlake",
        operation="process_image",
        extract_input=lambda args, kwargs: {"filename": kwargs.get("filename") or (args[2] if len(args) > 2 else "screenshot.png"), "size_bytes": len(args[1]) if len(args) > 1 and isinstance(args[1], bytes) else 0},
        extract_output=lambda r: {"success": r.get("success"), "markdown_length": len(r.get("markdown", ""))}
    )
    async def process_image(self, image_content: bytes, filename: str = "screenshot.png") -> dict:
        """
        Process an image (screenshot) and extract text/description
        
        Args:
            image_content: Raw bytes of the image
            filename: Name of the image file
        
        Returns:
            dict with markdown content
        """
        extension = filename.lower().split(".")[-1] if "." in filename else "png"
        content_type_map = {
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "gif": "image/gif",
            "webp": "image/webp",
            "bmp": "image/bmp",
            "tiff": "image/tiff"
        }
        content_type = content_type_map.get(extension, "image/png")
        
        return await self.convert_to_markdown(image_content, filename, content_type)
    
    def process_quick_note(self, text_content: str, title: Optional[str] = None) -> dict:
        """
        Process a quick text note (no API call needed, just format as markdown)
        
        Args:
            text_content: The text content of the note
            title: Optional title for the note
        
        Returns:
            dict with markdown content
        """
        if title:
            markdown = f"# {title}\n\n{text_content}"
        else:
            markdown = text_content
        
        return {
            "success": True,
            "markdown": markdown,
            "metadata": {"type": "quick_note"},
            "page_count": 1
        }


# Singleton instance
_tensorlake_service = None

def get_tensorlake_service() -> TensorlakeService:
    global _tensorlake_service
    if _tensorlake_service is None:
        _tensorlake_service = TensorlakeService()
    return _tensorlake_service
