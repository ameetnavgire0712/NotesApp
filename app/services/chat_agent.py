"""
LangGraph-based Chat Agent for SecondBrain
Uses Groq for fast LLM inference and searches notes via RAG agent service
"""
import logging
import json
from typing import TypedDict, Annotated, Sequence, Optional, AsyncGenerator
from datetime import datetime

from langchain_groq import ChatGroq
from langchain_core.messages import BaseMessage, HumanMessage, AIMessage, SystemMessage, ToolMessage
from langchain_core.tools import tool
from langgraph.graph import StateGraph, END
from langgraph.prebuilt import ToolNode
from langgraph.graph.message import add_messages

from app.core.config import get_settings

logger = logging.getLogger(__name__)


# =============================================================================
# Agent State
# =============================================================================

class AgentState(TypedDict):
    """State maintained across the agent graph"""
    messages: Annotated[Sequence[BaseMessage], add_messages]
    user_id: str
    search_results: Optional[list]


# =============================================================================
# Tools for the Agent
# =============================================================================

async def search_notes_tool_impl(query: str, user_id: str, limit: int = 5) -> dict:
    """
    Internal implementation of note search.
    Uses the RAG agent service which includes reranking, spell check, and agentic retrieval.
    """
    try:
        from app.services.rag_agent import get_rag_agent_service
        
        logger.info(f"🔍 Chat RAG search: query='{query[:50]}...' user={user_id[:8]}... limit={limit}")
        
        rag_agent = get_rag_agent_service()
        
        # Use the full RAG search which includes:
        # - Spell checking
        # - Query analysis
        # - Vector search with FAISS
        # - Reranking
        # - LLM-generated answer
        search_response = await rag_agent.search(
            query=query,
            user_id=user_id,
            max_results=limit
        )
        
        logger.info(f"📄 RAG search returned {len(search_response.documents)} documents")
        logger.info(f"   ⏱️ Total duration: {search_response.total_duration_ms}ms")
        
        # Extract documents with their scores (documents are already dicts)
        # RAG search returns: note_id, title, content_preview, tag, file_type, similarity_score, rerank_score, etc.
        documents = []
        for doc in search_response.documents:
            # Get content - try content_preview first (from SearchResult), then content
            content = doc.get("content_preview") or doc.get("content") or ""
            doc_info = {
                "id": doc.get("note_id") or doc.get("id", ""),
                "title": doc.get("title", "Untitled"),
                "content": content[:600],  # Truncate for context
                "tag": doc.get("tag", ""),
                "file_type": doc.get("file_type", ""),
                "similarity": doc.get("similarity_score") or doc.get("similarity", 0),
                "rerank_score": doc.get("rerank_score", 0),
                "source_url": doc.get("blob_url") or doc.get("source_url", "")
            }
            documents.append(doc_info)
            
            # Log top results for debugging
            title = (doc.get("title") or "Untitled")[:40]
            score = doc.get("rerank_score") or doc.get("similarity_score") or 0
            logger.info(f"   📄 {title}... (score: {score:.3f}, content_len: {len(content)})")
        
        # Get corrected query from metadata if available
        metadata = search_response.metadata or {}
        corrected_query = metadata.get("corrected_query", query)
        
        # Extract search internals for logging
        search_metadata = {
            "search_type": metadata.get("search_type", "hybrid_search"),
            "fast_path": metadata.get("fast_path", False),
            "query_type": metadata.get("query_type", "normal"),
            "spell_corrected": metadata.get("spell_corrected", False),
            "detected_tags": metadata.get("detected_tags", []),
            "reranker_used": any(doc.get("rerank_score", 0) > 0 for doc in search_response.documents),
            "total_candidates": metadata.get("total_candidates", len(documents)),
            "search_duration_ms": search_response.total_duration_ms,
            "threshold": metadata.get("threshold", 0),
        }
        
        return {
            "documents": documents,
            "query": query,
            "corrected_query": corrected_query,
            "rag_answer": search_response.answer,  # The RAG-generated answer
            "total_duration_ms": search_response.total_duration_ms,
            "search_metadata": search_metadata,  # Include search internals
        }
    except Exception as e:
        logger.error(f"RAG search error: {e}", exc_info=True)
        return {"error": str(e), "documents": [], "query": query, "search_metadata": {}}


# =============================================================================
# Chat Agent Class
# =============================================================================

class ChatAgent:
    """
    LangGraph-based chat agent that can search user's notes
    and provide contextual answers using Groq LLM.
    """
    
    def __init__(self, user_id: str):
        self.user_id = user_id
        self.settings = get_settings()
        self._last_search_metadata = {}  # Store last search metadata for logging
        
        # Initialize Groq LLM
        self.llm = ChatGroq(
            model="llama-3.3-70b-versatile",  # Fast and capable
            api_key=self.settings.groq_api_key,
            temperature=0.7,
            streaming=True
        )
        
        # Build the agent graph
        self.graph = self._build_graph()
    
    def _build_graph(self) -> StateGraph:
        """Build the LangGraph agent graph"""
        
        # Define the graph
        workflow = StateGraph(AgentState)
        
        # Add nodes
        workflow.add_node("search", self._search_node)
        workflow.add_node("respond", self._respond_node)
        
        # Define edges - always search first, then respond
        workflow.set_entry_point("search")
        workflow.add_edge("search", "respond")
        workflow.add_edge("respond", END)
        
        return workflow.compile()
    
    async def _search_node(self, state: AgentState) -> dict:
        """
        Search node: Always search user's notes for relevant context
        """
        messages = state["messages"]
        user_id = state["user_id"]
        
        # Get the latest user message as the search query
        latest_message = None
        for msg in reversed(messages):
            if isinstance(msg, HumanMessage):
                latest_message = msg.content
                break
        
        if not latest_message:
            return {"search_results": []}
        
        logger.info(f"Searching notes for: {latest_message[:100]}...")
        
        # Search notes
        results = await search_notes_tool_impl(
            query=latest_message,
            user_id=user_id,
            limit=5
        )
        
        # Store search metadata for external access (e.g., logging)
        self._last_search_metadata = results.get("search_metadata", {})
        
        return {"search_results": results}
    
    async def _respond_node(self, state: AgentState) -> dict:
        """
        Respond node: Generate response using search results as context
        """
        messages = state["messages"]
        search_results = state.get("search_results", {})
        
        # Build context from search results (now uses RAG agent response format)
        context_parts = []
        
        documents = search_results.get("documents", [])
        rag_answer = search_results.get("rag_answer", "")
        corrected_query = search_results.get("corrected_query", "")
        
        # Log search metadata
        if corrected_query and corrected_query != search_results.get("query", ""):
            logger.info(f"Query was corrected to: {corrected_query}")
        
        # Add reranked document results
        for i, doc in enumerate(documents[:5], 1):
            title = doc.get("title", "Untitled")
            content = doc.get("content", "")[:600]
            similarity = doc.get("similarity", 0)
            rerank_score = doc.get("rerank_score", 0)
            tag = doc.get("tag", "")
            
            score_info = f"rerank: {rerank_score:.2f}" if rerank_score else f"similarity: {similarity:.2f}"
            tag_info = f" [{tag}]" if tag else ""
            context_parts.append(f"**Document {i}: {title}**{tag_info} ({score_info})\n{content}")
        
        context = "\n\n---\n\n".join(context_parts) if context_parts else "No relevant notes found."
        
        # Build the system prompt
        system_prompt = f"""You are SecondBrain Assistant, a helpful AI that answers questions based on the user's saved notes and documents.

You have access to the user's knowledge base through search. Here are the relevant results from their notes:

{context}

Instructions:
1. Answer the user's question based primarily on the context from their notes
2. If the notes contain relevant information, cite which note/document it came from
3. If the notes don't contain enough information, say so and provide general knowledge if appropriate
4. Be conversational and helpful
5. Keep responses concise but informative

Current date: {datetime.now().strftime("%B %d, %Y")}"""
        
        # Create messages for LLM
        llm_messages = [SystemMessage(content=system_prompt)]
        
        # Add conversation history (last few messages)
        for msg in messages[-6:]:  # Keep last 6 messages for context
            if isinstance(msg, HumanMessage):
                llm_messages.append(msg)
            elif isinstance(msg, AIMessage):
                llm_messages.append(msg)
        
        # Generate response
        response = await self.llm.ainvoke(llm_messages)
        
        return {"messages": [response]}
    
    async def chat(self, message: str, history: list[dict] = None) -> str:
        """
        Send a message and get a complete response.
        
        Args:
            message: The user's message
            history: Optional conversation history
            
        Returns:
            The agent's response
        """
        # Build messages from history
        messages = []
        if history:
            for msg in history:
                if msg["role"] == "user":
                    messages.append(HumanMessage(content=msg["content"]))
                elif msg["role"] == "assistant":
                    messages.append(AIMessage(content=msg["content"]))
        
        # Add current message
        messages.append(HumanMessage(content=message))
        
        # Run the graph
        initial_state = {
            "messages": messages,
            "user_id": self.user_id,
            "search_results": None
        }
        
        result = await self.graph.ainvoke(initial_state)
        
        # Get the last AI message
        for msg in reversed(result["messages"]):
            if isinstance(msg, AIMessage):
                return msg.content
        
        return "I apologize, but I couldn't generate a response. Please try again."
    
    async def chat_stream(self, message: str, history: list[dict] = None) -> AsyncGenerator[str, None]:
        """
        Send a message and stream the response token by token.
        
        Args:
            message: The user's message
            history: Optional conversation history
            
        Yields:
            Response tokens as they're generated
        """
        # Build messages from history
        messages = []
        if history:
            for msg in history:
                if msg["role"] == "user":
                    messages.append(HumanMessage(content=msg["content"]))
                elif msg["role"] == "assistant":
                    messages.append(AIMessage(content=msg["content"]))
        
        # Add current message
        messages.append(HumanMessage(content=message))
        
        # First, search for relevant notes using RAG agent
        logger.info(f"🔍 Streaming chat - searching notes for: {message[:100]}...")
        search_results = await search_notes_tool_impl(
            query=message,
            user_id=self.user_id,
            limit=5
        )
        
        documents = search_results.get("documents", [])
        rag_answer = search_results.get("rag_answer", "")
        
        # Store search metadata for external access (e.g., logging)
        self._last_search_metadata = search_results.get("search_metadata", {})
        
        sources = []  # Track sources for citation
        
        logger.info(f"📄 Got {len(documents)} documents from RAG search")
        logger.info(f"📄 RAG answer provided: {bool(rag_answer)}")
        
        # Build sources list from documents
        for doc in documents[:5]:
            title = doc.get("title", "Untitled")
            note_id = doc.get("id", "")
            tag = doc.get("tag", "")
            rerank_score = doc.get("rerank_score", 0)
            similarity = doc.get("similarity", 0)
            score = rerank_score if rerank_score else similarity
            sources.append({"title": title, "note_id": note_id, "tag": tag, "score": score})
        
        # ===== MCP-STYLE RESPONSE PATTERN =====
        # If RAG answer is provided: Show answer + document links
        # If NO RAG answer: Just show document links (don't try to regenerate)
        
        if rag_answer:
            # RAG provided a synthesized answer - format it nicely with LLM
            logger.info(f"   💡 Using RAG answer: {rag_answer[:100]}...")
            
            system_prompt = f"""You are SecondBrain Assistant. The RAG system has already analyzed the user's question and found the answer from their documents.

**RAG Answer:**
{rag_answer}

**Source Documents:**
{chr(10).join([f"- {s['title']}" + (f" [{s['tag']}]" if s.get('tag') else "") for s in sources])}

Your task:
1. Present the RAG answer to the user in a conversational, helpful way
2. You may slightly rephrase for clarity but DO NOT add new information
3. Mention which document(s) the information came from
4. Keep it concise and natural

Current date: {datetime.now().strftime("%B %d, %Y")}"""
            
            llm_messages = [SystemMessage(content=system_prompt)]
            for msg in messages[-4:]:
                if isinstance(msg, HumanMessage):
                    llm_messages.append(msg)
            
            async for chunk in self.llm.astream(llm_messages):
                if chunk.content:
                    yield chunk.content
        
        elif documents:
            # No RAG answer - just provide document links like MCP does
            logger.info(f"   📎 No RAG answer - providing document links only")
            
            response = f"I found {len(documents)} relevant document(s) in your notes:\n\n"
            for i, doc in enumerate(documents[:5], 1):
                title = doc.get("title", "Untitled")
                tag = doc.get("tag", "")
                tag_str = f" [{tag}]" if tag else ""
                content_preview = doc.get("content", "")[:200]
                response += f"**{i}. {title}**{tag_str}\n"
                if content_preview:
                    response += f"   _{content_preview}..._\n"
                response += "\n"
            
            response += "\n💡 *Ask a specific question about these documents for a detailed answer, or click on a document to view it.*"
            
            yield response
        
        else:
            # No documents found
            yield "I couldn't find any relevant documents in your notes for that query. Try rephrasing your search or check if you have notes on this topic."
        
        # Yield sources at the end (as JSON) for the UI to render links
        if sources:
            yield f"\n\n__SOURCES__:{json.dumps(sources)}"


# =============================================================================
# Factory Function
# =============================================================================

def get_chat_agent(user_id: str) -> ChatAgent:
    """
    Get a chat agent instance for the given user.
    """
    return ChatAgent(user_id=user_id)
