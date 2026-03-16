"""
Chat API endpoints
Handles chat interactions with the LangGraph-based agent
Uses Vercel AI SDK compatible streaming format
"""
import logging
import json
import time
from fastapi import APIRouter, HTTPException, Depends, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from typing import Optional, List

from app.services.chat_agent import get_chat_agent
from app.core.dependencies import get_current_user, require_read_scope
from app.services.auth_service import AuthenticatedUser
from app.api.v1.notes import generate_view_token
from app.core.middleware import get_client_source

logger = logging.getLogger(__name__)


def _get_logging_service():
    """Lazy load logging service to avoid circular imports."""
    try:
        from app.services.logging_service import get_logging_service
        return get_logging_service()
    except Exception as e:
        logger.warning(f"Failed to get logging service: {e}")
        return None

router = APIRouter(prefix="/chat", tags=["Chat"])


# =============================================================================
# Vercel AI SDK Stream Protocol Helpers
# =============================================================================

def stream_text(text: str) -> str:
    """Format text chunk for AI SDK text stream protocol"""
    # Format: 0:"text"\n
    return f'0:{json.dumps(text)}\n'


def stream_data(data: list) -> str:
    """Format data chunk for AI SDK data stream protocol"""
    # Format: 2:[data]\n
    return f'2:{json.dumps(data)}\n'


def stream_error(error: str) -> str:
    """Format error for AI SDK stream protocol"""
    # Format: 3:"error"\n
    return f'3:{json.dumps(error)}\n'


def stream_finish(reason: str = "stop") -> str:
    """Format finish message for AI SDK stream protocol"""
    # Format: d:{"finishReason":"stop"}\n
    return f'd:{json.dumps({"finishReason": reason})}\n'


# =============================================================================
# Request/Response Schemas
# =============================================================================

class ChatMessage(BaseModel):
    """A single chat message"""
    role: str = Field(..., description="Message role: 'user' or 'assistant'")
    content: str = Field(..., description="Message content")


class ChatRequest(BaseModel):
    """Request for chat endpoint"""
    message: str = Field(..., description="The user's message")
    history: Optional[List[ChatMessage]] = Field(default=None, description="Conversation history")
    stream: bool = Field(default=True, description="Whether to stream the response")


class ChatResponse(BaseModel):
    """Response for non-streaming chat"""
    response: str
    sources: Optional[List[dict]] = None


# =============================================================================
# Endpoints
# =============================================================================

@router.post("/")
async def chat(
    request: ChatRequest,
    current_user: AuthenticatedUser = Depends(require_read_scope)
):
    """
    Chat with your notes using AI.
    
    The agent will search your notes for relevant context and provide
    answers based on your saved documents.
    
    Uses Vercel AI SDK compatible streaming format.
    
    Set `stream=true` (default) for streaming response (AI SDK format).
    Set `stream=false` for a complete JSON response.
    
    **Requires authentication** (Bearer token or API key with 'read' scope)
    """
    start_time = time.time()
    client_source = get_client_source() or "unknown"
    
    # Log chat request with search internals
    async def log_chat_activity(
        status: str, 
        source_count: int = 0, 
        error_msg: str = None,
        search_metadata: dict = None
    ):
        """Helper to log chat activity with search internals."""
        try:
            logging_service = _get_logging_service()
            if logging_service:
                duration_ms = int((time.time() - start_time) * 1000)
                metadata = {
                    "query": request.message[:200],  # Capture the query
                    "query_length": len(request.message),
                    "history_length": len(request.history) if request.history else 0,
                    "streaming": request.stream,
                    "source_count": source_count,
                    "client_source": client_source,
                }
                
                # Add search internals if available
                if search_metadata:
                    metadata["search_type"] = search_metadata.get("search_type", "unknown")
                    metadata["fast_path"] = search_metadata.get("fast_path", False)
                    metadata["query_type"] = search_metadata.get("query_type", "normal")
                    metadata["spell_corrected"] = search_metadata.get("spell_corrected", False)
                    metadata["detected_tags"] = search_metadata.get("detected_tags", [])
                    metadata["reranker_used"] = search_metadata.get("reranker_used", False)
                    metadata["total_candidates"] = search_metadata.get("total_candidates", 0)
                    metadata["search_duration_ms"] = search_metadata.get("search_duration_ms", 0)
                
                if error_msg:
                    metadata["error"] = error_msg
                
                await logging_service.log_activity(
                    user_id=current_user.user_id,
                    action="chat_query",
                    resource_type="chat",
                    status=status,
                    duration_ms=duration_ms,
                    metadata=metadata
                )
        except Exception as e:
            logger.warning(f"Failed to log chat activity: {e}")
    
    try:
        agent = get_chat_agent(user_id=current_user.user_id)
        
        # Convert history to dict format
        history = None
        if request.history:
            history = [{"role": msg.role, "content": msg.content} for msg in request.history]
        
        if request.stream:
            # Stream using Vercel AI SDK text stream protocol
            async def generate():
                sources = []
                source_count = 0
                try:
                    async for chunk in agent.chat_stream(request.message, history):
                        # Check if this is the sources marker (may have \n prefix)
                        if "__SOURCES__:" in chunk:
                            # Extract just the JSON part
                            idx = chunk.find("__SOURCES__:")
                            sources_json = chunk[idx + len("__SOURCES__:"):]
                            logger.info(f"📎 Found sources marker, parsing: {sources_json[:100]}...")
                            sources = json.loads(sources_json)
                            source_count = len(sources)
                            
                            # Add view URLs with tokens for each source
                            for source in sources:
                                note_id = source.get("note_id")
                                if note_id:
                                    view_token = generate_view_token(note_id, current_user.user_id, expiry_minutes=30)
                                    source["view_url"] = f"/api/v1/notes/{note_id}/view?token={view_token}"
                                    logger.info(f"📎 Generated view_url for {note_id[:8]}...")
                            
                            logger.info(f"📎 Sending {len(sources)} sources with view_urls")
                            # Send sources as data stream
                            yield stream_data([{"sources": sources}])
                        else:
                            # Send text chunk
                            yield stream_text(chunk)
                    
                    # Send finish message
                    yield stream_finish("stop")
                    
                    # Log successful chat with search metadata
                    search_metadata = getattr(agent, '_last_search_metadata', {})
                    await log_chat_activity("success", source_count, search_metadata=search_metadata)
                    
                except Exception as e:
                    logger.error(f"Streaming error: {e}")
                    await log_chat_activity("error", 0, str(e))
                    yield stream_error(str(e))
            
            return StreamingResponse(
                generate(),
                media_type="text/plain; charset=utf-8",
                headers={
                    "Cache-Control": "no-cache",
                    "Connection": "keep-alive",
                    "X-Vercel-AI-Data-Stream": "v1",
                    "X-Accel-Buffering": "no"
                }
            )
        else:
            # Non-streaming response
            response = await agent.chat(request.message, history)
            
            # Check if response contains sources
            sources = None
            source_count = 0
            if "__SOURCES__:" in response:
                parts = response.split("__SOURCES__:")
                response = parts[0].strip()
                if len(parts) > 1:
                    try:
                        sources = json.loads(parts[1])
                        source_count = len(sources)
                        # Add view URLs with tokens for each source
                        for source in sources:
                            note_id = source.get("note_id")
                            if note_id:
                                view_token = generate_view_token(note_id, current_user.user_id, expiry_minutes=30)
                                source["view_url"] = f"/api/v1/notes/{note_id}/view?token={view_token}"
                    except:
                        pass
            
            # Log successful non-streaming chat
            search_metadata = getattr(agent, '_last_search_metadata', {})
            await log_chat_activity("success", source_count, search_metadata=search_metadata)
            
            return ChatResponse(response=response, sources=sources)
        
    except Exception as e:
        logger.error(f"Chat error: {e}")
        await log_chat_activity("error", 0, str(e))
        raise HTTPException(status_code=500, detail=f"Chat failed: {str(e)}")


@router.get("/health")
async def chat_health():
    """
    Health check for chat service.
    Verifies Groq API connectivity.
    """
    from app.core.config import get_settings
    settings = get_settings()
    
    return {
        "status": "ok",
        "groq_configured": bool(settings.groq_api_key),
        "model": "llama-3.3-70b-versatile"
    }
