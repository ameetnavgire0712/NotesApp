"""
RAG Agent Service
Agentic RAG with tool-calling, self-reflection, and dynamic iteration
"""
import asyncio
import json
import logging
import re
import time
from typing import List, Dict, Any, Optional, Tuple
from dataclasses import dataclass, asdict
from enum import Enum
from datetime import datetime
from groq import Groq

from app.core.config import get_settings
from app.core.log_decorators import log_operation
from app.services.query_analyzer import (
    get_query_analyzer_service,
    QueryAnalyzerService,
    AnalyzedQuery,
    QueryComplexity,
    QueryIntent,
    TemporalSort
)
from app.services.retrieval_tools import (
    get_retrieval_tools_service,
    RetrievalToolsService,
    SearchResult
)
from app.services.rag_eval_logger import get_rag_eval_logger
import hashlib
from collections import OrderedDict

logger = logging.getLogger(__name__)

# =============================================================================
# SYNTHESIS CACHE (In-Memory with TTL)
# =============================================================================
_synthesis_cache: OrderedDict[str, Tuple[str, float]] = OrderedDict()  # {cache_key: (answer, timestamp)}
SYNTHESIS_CACHE_TTL = 1800  # 30 minutes
MAX_SYNTHESIS_CACHE_ENTRIES = 1000

def _get_synthesis_cache_key(query: str, doc_ids: List[str]) -> str:
    """Generate cache key from query and document IDs"""
    normalized_query = query.lower().strip()
    sorted_ids = sorted(doc_ids)
    key_string = f"{normalized_query}:{','.join(sorted_ids)}"
    return hashlib.md5(key_string.encode()).hexdigest()

def _get_cached_synthesis(cache_key: str) -> Optional[str]:
    """Get cached synthesis result if valid"""
    global _synthesis_cache
    if cache_key in _synthesis_cache:
        answer, timestamp = _synthesis_cache[cache_key]
        if time.time() - timestamp < SYNTHESIS_CACHE_TTL:
            # Move to end (LRU)
            _synthesis_cache.move_to_end(cache_key)
            logger.info(f"📦 Synthesis CACHE HIT - key={cache_key[:16]}...")
            return answer
        else:
            # Expired, remove it
            del _synthesis_cache[cache_key]
            logger.debug(f"Synthesis cache expired - key={cache_key[:16]}...")
    return None

def _set_cached_synthesis(cache_key: str, answer: str) -> None:
    """Cache synthesis result"""
    global _synthesis_cache
    # Evict oldest if at capacity
    while len(_synthesis_cache) >= MAX_SYNTHESIS_CACHE_ENTRIES:
        _synthesis_cache.popitem(last=False)
    _synthesis_cache[cache_key] = (answer, time.time())
    logger.info(f"💾 Synthesis cached - key={cache_key[:16]}..., cache_size={len(_synthesis_cache)}")

def get_synthesis_cache_stats() -> Dict[str, Any]:
    """Get synthesis cache statistics"""
    global _synthesis_cache
    now = time.time()
    valid_count = sum(1 for _, (_, ts) in _synthesis_cache.items() if now - ts < SYNTHESIS_CACHE_TTL)
    return {
        "total_entries": len(_synthesis_cache),
        "valid_entries": valid_count,
        "max_entries": MAX_SYNTHESIS_CACHE_ENTRIES,
        "ttl_seconds": SYNTHESIS_CACHE_TTL
    }

# =============================================================================
# CIRCUIT BREAKER (For Groq Synthesis)
# =============================================================================
_groq_response_times: List[Tuple[float, float]] = []  # [(response_time_ms, timestamp)]
CIRCUIT_BREAKER_THRESHOLD_MS = 3000  # If avg > 3s, open circuit
CIRCUIT_BREAKER_WINDOW_SECONDS = 60  # Look at last 60 seconds
CIRCUIT_BREAKER_MIN_SAMPLES = 3  # Need at least 3 samples to open circuit

def _record_groq_response_time(response_time_ms: float) -> None:
    """Record a Groq response time"""
    global _groq_response_times
    now = time.time()
    _groq_response_times.append((response_time_ms, now))
    # Prune old entries
    cutoff = now - CIRCUIT_BREAKER_WINDOW_SECONDS
    _groq_response_times = [(rt, ts) for rt, ts in _groq_response_times if ts > cutoff]

def _is_circuit_breaker_open() -> bool:
    """Check if circuit breaker should block synthesis"""
    global _groq_response_times
    now = time.time()
    cutoff = now - CIRCUIT_BREAKER_WINDOW_SECONDS
    recent_times = [rt for rt, ts in _groq_response_times if ts > cutoff]
    
    if len(recent_times) < CIRCUIT_BREAKER_MIN_SAMPLES:
        return False  # Not enough data
    
    avg_time = sum(recent_times) / len(recent_times)
    is_open = avg_time > CIRCUIT_BREAKER_THRESHOLD_MS
    
    if is_open:
        logger.warning(f"⚡ Circuit breaker OPEN - avg response time: {avg_time:.0f}ms > {CIRCUIT_BREAKER_THRESHOLD_MS}ms")
    
    return is_open

def get_circuit_breaker_stats() -> Dict[str, Any]:
    """Get circuit breaker statistics"""
    global _groq_response_times
    now = time.time()
    cutoff = now - CIRCUIT_BREAKER_WINDOW_SECONDS
    recent_times = [rt for rt, ts in _groq_response_times if ts > cutoff]
    
    return {
        "sample_count": len(recent_times),
        "avg_response_time_ms": sum(recent_times) / len(recent_times) if recent_times else 0,
        "threshold_ms": CIRCUIT_BREAKER_THRESHOLD_MS,
        "window_seconds": CIRCUIT_BREAKER_WINDOW_SECONDS,
        "is_open": _is_circuit_breaker_open()
    }


async def _store_backend_trace(
    correlation_id: str,
    original_query: str,
    corrected_query: str,
    was_corrected: bool,
    spell_explanation: Optional[str],
    spell_duration_ms: int,
    tags_available: List[str],
    tags_detected: List[str],
    tag_intent: Optional[str],
    tags_cache_hit: bool,
    tags_duration_ms: int,
    query_intent: Optional[str],
    query_complexity: Optional[str],
    query_keywords: List[str],
    needs_synthesis: bool,
    analysis_duration_ms: int,
    circuit_breaker_open: bool,
    circuit_breaker_avg_ms: int,
    synthesis_cache_hit: bool,
    synthesis_cache_key: Optional[str],
    synthesis_duration_ms: int,
    agent_steps: List[Dict[str, Any]],
    backend_metadata: Dict[str, Any],
    total_duration_ms: int
) -> None:
    """
    Store backend trace data by updating the search_traces record.
    Called at the end of search() to add Fly.io backend context to the Worker trace.
    Fire-and-forget - errors are logged but don't affect response.
    """
    import httpx
    from app.core.config import get_settings
    
    try:
        settings = get_settings()
        # Use localhost since we're in the same Fly.io app
        # But for safety, use the actual endpoint
        base_url = "https://notesapp-search.fly.dev"  
        
        payload = {
            "correlation_id": correlation_id,
            "spell_check_original": original_query,
            "spell_check_corrected": corrected_query if was_corrected else None,
            "spell_check_was_corrected": was_corrected,
            "spell_check_explanation": spell_explanation,
            "spell_check_duration_ms": spell_duration_ms,
            "tags_available": tags_available,
            "tags_detected": tags_detected,
            "tag_intent": tag_intent,
            "tags_cache_hit": tags_cache_hit,
            "tags_fetch_duration_ms": tags_duration_ms,
            "query_intent": query_intent,
            "query_complexity": query_complexity,
            "query_keywords": query_keywords,
            "query_needs_synthesis": needs_synthesis,
            "query_analysis_duration_ms": analysis_duration_ms,
            "circuit_breaker_open": circuit_breaker_open,
            "circuit_breaker_avg_latency_ms": circuit_breaker_avg_ms,
            "synthesis_cache_hit": synthesis_cache_hit,
            "synthesis_cache_key": synthesis_cache_key,
            "synthesis_duration_ms": synthesis_duration_ms,
            "agent_steps": agent_steps,
            "backend_metadata": backend_metadata,
            "timing_fly_ms": total_duration_ms
        }
        
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.patch(
                f"{base_url}/api/v1/logs/search-trace/{correlation_id}",
                json=payload
            )
            if response.status_code != 200:
                logger.warning(f"Failed to store backend trace: {response.status_code} - {response.text[:200]}")
            else:
                logger.debug(f"Backend trace stored for correlation_id={correlation_id}")
    except Exception as e:
        logger.warning(f"Failed to store backend trace (fire-and-forget): {e}")


class TagSearchIntent(str, Enum):
    """Intent when a tag is detected in the query"""
    LIST_ALL = "list_all"       # User wants all docs with this tag
    SPECIFIC = "specific"       # User wants specific info within the tag


class AgentState(str, Enum):
    """Agent execution states"""
    ANALYZING = "analyzing"
    SEARCHING = "searching"
    REFINING = "refining"
    SYNTHESIZING = "synthesizing"
    COMPLETE = "complete"
    ERROR = "error"


@dataclass
class AgentStep:
    """Record of a single agent step"""
    step_number: int
    state: AgentState
    action: str
    tool_name: Optional[str]
    tool_input: Optional[Dict[str, Any]]
    tool_output: Optional[Any]
    thought: str
    duration_ms: int


@dataclass
class SearchResponse:
    """Final response from the RAG agent"""
    query: str
    documents: List[Dict[str, Any]]  # Always returned
    answer: Optional[str]            # Only when needed
    download_urls: List[Dict[str, str]]
    metadata: Dict[str, Any]
    agent_steps: List[AgentStep]
    total_duration_ms: int


# Helper to coerce limit to int (LLM sometimes passes string)
def _coerce_limit(value, default: int = 10) -> int:
    """Coerce limit value to integer, handling string inputs from LLM."""
    if value is None:
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return default
    return default


# Tool definitions for Groq
# Note: Using ["integer", "string"] for limit to handle LLM sometimes passing strings
# NOTE: vector_search removed - hybrid_search is superior (uses Cloudflare Vectorize + reranking)
TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "hybrid_search",
            "description": "Combined vector + full-text search. Best for queries with specific keywords AND conceptual meaning.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "The search query"
                    },
                    "tag": {
                        "type": "string",
                        "description": "Optional tag to filter results"
                    },
                    "limit": {
                        "type": ["integer", "string"],
                        "description": "Maximum number of results (default 10)"
                    }
                },
                "required": ["query"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "chunk_search",
            "description": "Deep search at passage/paragraph level. BEST FOR: Questions asking for specific facts, roles, dates, numbers, or details buried inside documents. Use this when user asks 'what was...', 'who was...', 'when did...', 'what role...', 'what experience...' type questions. Returns precise text passages.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "The search query"
                    },
                    "limit": {
                        "type": ["integer", "string"],
                        "description": "Maximum number of chunk results (default 10)"
                    }
                },
                "required": ["query"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "search_by_tag",
            "description": "Get all documents with a specific tag. Use when user asks for documents in a category.",
            "parameters": {
                "type": "object",
                "properties": {
                    "tag": {
                        "type": "string",
                        "description": "The exact tag to search for"
                    },
                    "limit": {
                        "type": ["integer", "string"],
                        "description": "Maximum number of results (default 10)"
                    }
                },
                "required": ["tag"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "get_all_tags",
            "description": "List all available tags with document counts. Use to discover available categories.",
            "parameters": {
                "type": "object",
                "properties": {},
                "required": []
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "fuzzy_match_tag",
            "description": "Find best matching tag using fuzzy matching. Use when user mentions a tag that might not be exact.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query_tag": {
                        "type": "string",
                        "description": "The tag query to match"
                    }
                },
                "required": ["query_tag"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "get_document_content",
            "description": "Get full content of a specific document by ID. Use when you need more context from a search result.",
            "parameters": {
                "type": "object",
                "properties": {
                    "note_id": {
                        "type": "string",
                        "description": "The note ID to retrieve"
                    }
                },
                "required": ["note_id"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "finalize_results",
            "description": "Call this when you have gathered enough documents. Provide the final answer if the query requires synthesis.",
            "parameters": {
                "type": "object",
                "properties": {
                    "selected_note_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "List of note IDs to include in the response"
                    },
                    "answer": {
                        "type": "string",
                        "description": "Synthesized answer if the query requires one. Leave empty for pure retrieval queries."
                    },
                    "reasoning": {
                        "type": "string",
                        "description": "Brief explanation of why these documents were selected"
                    }
                },
                "required": ["selected_note_ids", "reasoning"]
            }
        }
    }
]


class RAGAgentService:
    """
    Agentic RAG with Groq tool-calling.
    Dynamically decides search strategy based on query analysis.
    """
    
    MODEL = "llama-3.3-70b-versatile"  # Best tool-calling support on Groq
    FAST_MODEL = "llama-3.1-8b-instant"  # Fast model for intent classification
    SYNTHESIS_MODEL = "llama-3.3-70b-versatile"  # Model for answer synthesis with full content
    TEMPERATURE = 0.1  # Low temperature for consistent behavior
    MAX_CONTENT_PER_DOC = 8000  # Max chars per document for synthesis (to avoid context overflow)
    
    # Stop words for tag intent classification (extended list)
    TAG_INTENT_STOP_WORDS = {
        'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been',
        'show', 'me', 'my', 'get', 'find', 'fetch', 'display', 'view',
        'see', 'list', 'all', 'documents', 'docs', 'files', 'notes',
        'from', 'in', 'of', 'with', 'for', 'to', 'and', 'or', 'please',
        'can', 'you', 'i', 'want', 'need', 'give', 'provide', 'retrieve'
    }
    
    # Similarity thresholds per source type
    SIMILARITY_THRESHOLDS = {
        "hybrid": 0.15,
        "vector": 0.25,
        "chunk": 0.25,
        "tag": 0.0
    }
    
    # Discovery query patterns - these use hybrid_search fast path (bypasses agent loop)
    DISCOVERY_PATTERNS = [
        r"^do\s+i\s+have",
        r"^show\s+me",
        r"^find\s+(my|all|the)",
        r"^list\s+(my|all|the)",
        r"^are\s+there\s+any",
        r"^get\s+(my|all|the)",
        r"^what\s+(documents?|files?|notes?)\s+(do\s+i|are)",
        r"any\s+documents?\s+(for|about|related)",
    ]
    
    # Temporal keywords that require full query analysis (not fast path)
    TEMPORAL_KEYWORDS = [
        "latest", "newest", "most recent", "recent",
        "oldest", "earliest", "first", "last"
    ]
    
    def _is_discovery_query(self, query: str) -> bool:
        """Check if query is a discovery/listing query that should use hybrid_search fast path.
        
        NOTE: Queries with temporal keywords (latest, oldest, etc.) should NOT use
        the fast path because they need full temporal sorting logic.
        """
        query_lower = query.lower().strip()
        
        # Check for temporal keywords - these need full analysis, not fast path
        for keyword in self.TEMPORAL_KEYWORDS:
            if keyword in query_lower:
                logger.info(f"Temporal keyword '{keyword}' found - skipping fast path")
                return False
        
        for pattern in self.DISCOVERY_PATTERNS:
            if re.search(pattern, query_lower):
                logger.info(f"Discovery pattern matched: {pattern}")
                return True
        return False
    
    def __init__(self):
        settings = get_settings()
        self.client = Groq(api_key=settings.groq_api_key)
        self.query_analyzer = get_query_analyzer_service()
        self.retrieval_tools = get_retrieval_tools_service()
        self._user_id = "default_user"
        self._all_results: Dict[str, SearchResult] = {}  # Cache results by note_id
        self._steps: List[AgentStep] = []
    
    def _extract_keywords_beyond_tag(self, query: str, detected_tags: List[str]) -> Tuple[str, List[str]]:
        """
        Extract meaningful keywords from query after removing tag words.
        
        Args:
            query: Original user query
            detected_tags: List of detected tag names
        
        Returns:
            Tuple of (remaining_query, meaningful_keywords)
        
        Example:
            query="pan card from personal docs", tags=["personal docs"]
            -> ("pan card from", ["pan", "card"])
        """
        query_lower = query.lower()
        
        # Remove tag words from query
        for tag in detected_tags:
            tag_lower = tag.lower()
            # Remove exact tag match
            query_lower = re.sub(r'\b' + re.escape(tag_lower) + r'\b', '', query_lower)
        
        # Clean up extra spaces
        remaining_query = ' '.join(query_lower.split())
        
        # Extract words and filter stop words
        words = re.findall(r'\b\w+\b', remaining_query)
        meaningful = [w for w in words if w not in self.TAG_INTENT_STOP_WORDS and len(w) > 1]
        
        logger.debug(f"🏷️ TAG KEYWORDS: query='{query}', tags={detected_tags}, remaining='{remaining_query}', meaningful={meaningful}")
        
        return remaining_query, meaningful
    
    async def _classify_tag_intent(
        self, 
        query: str, 
        detected_tags: List[str],
        remaining_keywords: List[str]
    ) -> TagSearchIntent:
        """
        Classify whether user wants all docs for a tag or specific info within the tag.
        Uses fast LLM (llama-3.1-8b-instant) for quick classification.
        
        Args:
            query: Original user query
            detected_tags: List of detected tag names
            remaining_keywords: Keywords left after removing tag words
        
        Returns:
            TagSearchIntent.LIST_ALL or TagSearchIntent.SPECIFIC
        """
        # Fast path: if no meaningful keywords remain, it's LIST_ALL
        if not remaining_keywords:
            logger.info(f"🏷️ TAG INTENT: LIST_ALL (no keywords beyond tag)")
            return TagSearchIntent.LIST_ALL
        
        # Use fast LLM to classify ambiguous cases
        step_start = time.time()
        
        prompt = f"""Classify this query intent. The user's query contains a document category/tag "{', '.join(detected_tags)}".

Query: "{query}"
Keywords beyond the tag: {remaining_keywords}

Question: Does the user want to:
A) LIST_ALL: See all documents in the "{', '.join(detected_tags)}" category
B) SPECIFIC: Find specific information/document within that category

Examples:
- "show me personal docs" → LIST_ALL (just wants to see the category)
- "pan card from personal docs" → SPECIFIC (wants specific document)
- "redis documents" → LIST_ALL (just wants redis category)
- "redis pricing details" → SPECIFIC (wants specific info about pricing)

Answer with just: LIST_ALL or SPECIFIC"""

        try:
            response = self.client.chat.completions.create(
                model=self.FAST_MODEL,
                messages=[{"role": "user", "content": prompt}],
                max_tokens=20,
                temperature=0
            )
            
            answer = response.choices[0].message.content.strip().upper()
            duration_ms = int((time.time() - step_start) * 1000)
            
            if "LIST_ALL" in answer:
                logger.info(f"🏷️ TAG INTENT: LIST_ALL (LLM classified in {duration_ms}ms)")
                return TagSearchIntent.LIST_ALL
            else:
                logger.info(f"🏷️ TAG INTENT: SPECIFIC (LLM classified in {duration_ms}ms)")
                return TagSearchIntent.SPECIFIC
                
        except Exception as e:
            logger.warning(f"🏷️ TAG INTENT: Failed to classify via LLM ({e}), defaulting to SPECIFIC")
            # Default to SPECIFIC (safer - will search for specific info)
            return TagSearchIntent.SPECIFIC

    def _build_system_prompt(self, analysis: AnalyzedQuery) -> str:
        """Build system prompt based on query analysis"""
        
        # Build temporal instructions
        temporal_instructions = ""
        if analysis.temporal_sort != TemporalSort.NONE:
            sort_order = "most recent (newest)" if analysis.temporal_sort == TemporalSort.NEWEST else "oldest"
            temporal_instructions = f"""
TEMPORAL CONSTRAINT:
- User wants the {sort_order} document(s)
- CRITICAL: Include ALL matching documents in your finalize_results call - do NOT pick just one yourself
- The SYSTEM (not you) will sort by created_at and apply limit_to_one constraint automatically
- Your job is to find relevant documents; the system handles temporal selection
- Example: If searching for "latest CV", include ALL CV documents (not just one) and let the system pick the newest"""
        
        return f"""You are a document retrieval assistant. Your job is to find relevant documents and optionally provide a synthesized answer.

QUERY ANALYSIS:
- Intent: {analysis.intent.value}
- Complexity: {analysis.complexity.value}
- Max iterations allowed: {analysis.max_iterations}
- Needs synthesis: {analysis.needs_synthesis}
- Detected tags: {analysis.detected_tags if analysis.detected_tags else 'None'}
- Keywords: {analysis.keywords}
- Temporal sort: {analysis.temporal_sort.value}
- Limit to one: {analysis.limit_to_one}
{temporal_instructions}

RULES:
1. ALWAYS retrieve documents first. Documents are mandatory in the response.
2. Only provide an answer if the query explicitly asks a question or needs synthesis.
3. **TAG PRIORITY**: If detected_tags is not empty, you MUST use search_by_tag to filter results to ONLY that tag. Do NOT return documents with different tags.
4. **SEARCH TOOL SELECTION**:
   - Use `hybrid_search` for ALL search queries - it combines semantic understanding with keyword matching for best results
   - Use `chunk_search` for detailed QUESTIONS about specific sections AFTER hybrid_search returns relevant documents
5. **KEYWORD MATCHING**: If the query contains a specific company/product name, verify results contain that keyword before including them.
6. If a tag seems to be mentioned but not in detected_tags, use fuzzy_match_tag first to find the exact tag name, then search_by_tag.
7. After searching, call finalize_results with your selected documents and optional answer.
8. Maximum {analysis.max_iterations} tool calls allowed - be efficient.
9. If initial results are poor, try query variations with hybrid_search.
10. **TEMPORAL QUERIES**: For "latest/newest" or "oldest/earliest" queries, include ALL matching documents in finalize_results. The system handles sorting and filtering - DO NOT pick just one.
11. **SIMILARITY FILTER**: For hybrid_search results, include documents with similarity_score >= 0.25. For keyword-based queries, prioritize results with text_rank > 0 (meaning they contain the keywords).
12. **DO NOT return documents that don't contain the specific entity/company mentioned in the query.**

**CRITICAL FILTERING RULES**:
13. **QUERY INTENT MATCHING**: Only include documents that DIRECTLY answer the user's query intent. Ask yourself: "Does this document's PRIMARY PURPOSE match what the user is asking for?"
    - Example: Query "job openings at Centric" → Include job postings, EXCLUDE resumes (even if they mention Centric)
    - Example: Query "my resume" → Include resumes, EXCLUDE job postings
    - Example: Query "pricing for Redis" → Include pricing documents, EXCLUDE general Redis overviews
14. **DOCUMENT TYPE AWARENESS**: Pay attention to document titles and types:
    - "Job Openings..." = job posting document
    - "Resume of..." = personal CV/resume
    - "Pricing Guide..." = pricing information
    - "Overview of..." = general information document
    Only include documents whose TYPE matches the query intent.

RESPONSE FORMAT:
- selected_note_ids: List of ALL relevant note IDs (system applies limit_to_one if needed)
- answer: Synthesized answer (ONLY if query needs it, otherwise leave empty)
- reasoning: Why you selected these documents"""

    async def _synthesize_answer_with_full_content(
        self,
        query: str,
        documents: List[Dict[str, Any]],
        analysis: AnalyzedQuery
    ) -> Optional[str]:
        """
        Synthesize answer using FULL document content instead of truncated previews.
        This ensures the LLM has access to all information needed to answer questions accurately.
        
        Args:
            query: Original user query
            documents: List of selected documents (with content_preview)
            analysis: Query analysis results
        
        Returns:
            Synthesized answer or None if synthesis fails
        """
        if not documents:
            return None
        
        import time
        step_start = time.time()
        
        # Fetch full content for each document
        full_contents = []
        for doc in documents[:5]:  # Limit to top 5 docs for context window
            note_id = doc.get("note_id")
            if not note_id:
                continue
            
            try:
                full_note = await self.retrieval_tools.get_document_content(
                    note_id=note_id,
                    user_id=self._user_id
                )
                if full_note:
                    content = full_note.get("content_markdown", "")
                    # Truncate individual docs if too long
                    if len(content) > self.MAX_CONTENT_PER_DOC:
                        content = content[:self.MAX_CONTENT_PER_DOC] + "\n... [content truncated]"
                    
                    full_contents.append({
                        "title": full_note.get("title", doc.get("title", "Untitled")),
                        "content": content,
                        "tag": full_note.get("tag", doc.get("tag", "")),
                        "note_id": note_id
                    })
            except Exception as e:
                logger.warning(f"Failed to fetch full content for note {note_id}: {e}")
                # Fall back to preview
                full_contents.append({
                    "title": doc.get("title", "Untitled"),
                    "content": doc.get("content_preview", ""),
                    "tag": doc.get("tag", ""),
                    "note_id": note_id
                })
        
        if not full_contents:
            logger.warning("No full content could be fetched for synthesis")
            return None
        
        # Build context for synthesis
        context_parts = []
        for i, fc in enumerate(full_contents, 1):
            context_parts.append(f"""
=== DOCUMENT {i}: {fc['title']} ===
Tag: {fc['tag']}
Content:
{fc['content']}
""")
        
        context_text = "\n".join(context_parts)
        
        # Synthesis prompt
        synthesis_prompt = f"""You are a helpful assistant that answers questions based on the provided documents.

QUESTION: {query}

DOCUMENTS:
{context_text}

INSTRUCTIONS:
1. Answer the question directly and specifically based on the document content.
2. If the documents contain the specific information asked for (names, dates, numbers, etc.), extract and state it clearly.
3. Do NOT give vague or hedging answers like "you may need to check" - if the information is in the documents, state it.
4. If the information is NOT in any of the documents, say "I couldn't find this information in your documents."
5. Keep the answer concise but complete.

ANSWER:"""

        try:
            logger.debug(f"Synthesizing answer with {len(full_contents)} full documents")
            response = self.client.chat.completions.create(
                model=self.SYNTHESIS_MODEL,
                messages=[
                    {"role": "system", "content": "You are a precise document Q&A assistant. Extract and state information directly from documents."},
                    {"role": "user", "content": synthesis_prompt}
                ],
                temperature=0.1,
                max_tokens=1000
            )
            
            answer = response.choices[0].message.content.strip()
            
            # Record synthesis step
            self._steps.append(AgentStep(
                step_number=len(self._steps) + 1,
                state=AgentState.SYNTHESIZING,
                action="synthesize_with_full_content",
                tool_name="synthesis_llm",
                tool_input={"query": query, "doc_count": len(full_contents)},
                tool_output={"answer_length": len(answer)},
                thought=f"Synthesized answer using full content from {len(full_contents)} documents",
                duration_ms=int((time.time() - step_start) * 1000)
            ))
            
            logger.info(f"Synthesis complete: {len(answer)} chars answer")
            return answer
            
        except Exception as e:
            logger.error(f"Synthesis failed: {e}")
            return None

    async def _execute_tool(
        self,
        tool_name: str,
        tool_args: Dict[str, Any]
    ) -> Any:
        """Execute a tool and return results"""
        
        # NOTE: vector_search removed - redirect to hybrid_search for backwards compatibility
        if tool_name == "vector_search":
            tool_name = "hybrid_search"
            logger.info("vector_search redirected to hybrid_search")
        
        if tool_name == "hybrid_search":
            query = tool_args.get("query", "")
            results = await self.retrieval_tools.hybrid_search(
                query=query,
                user_id=self._user_id,
                tag=tool_args.get("tag"),
                limit=_coerce_limit(tool_args.get("limit"), 10)
            )
            
            # LLM relevance verification - always runs to catch false positives
            if results:
                verified_results = await self._verify_relevance_with_llm(query, results)
                # Update cache with only verified results
                for r in verified_results:
                    self._all_results[r.note_id] = r
                return [asdict(r) for r in verified_results]
            
            return []
        
        elif tool_name == "chunk_search":
            results = await self.retrieval_tools.chunk_search(
                query=tool_args.get("query", ""),
                user_id=self._user_id,
                limit=_coerce_limit(tool_args.get("limit"), 10)
            )
            for r in results:
                self._all_results[r.note_id] = r
            return [asdict(r) for r in results]
        
        elif tool_name == "search_by_tag":
            results = await self.retrieval_tools.search_by_tag(
                tag=tool_args.get("tag", ""),
                user_id=self._user_id,
                limit=_coerce_limit(tool_args.get("limit"), 10)
            )
            for r in results:
                self._all_results[r.note_id] = r
            return [asdict(r) for r in results]
        
        elif tool_name == "get_all_tags":
            return await self.retrieval_tools.get_all_tags(self._user_id)
        
        elif tool_name == "fuzzy_match_tag":
            result = await self.retrieval_tools.fuzzy_match_tag(
                query_tag=tool_args.get("query_tag", ""),
                user_id=self._user_id
            )
            return asdict(result)
        
        elif tool_name == "get_document_content":
            result = await self.retrieval_tools.get_document_content(
                note_id=tool_args.get("note_id", ""),
                user_id=self._user_id
            )
            return result
        
        elif tool_name == "finalize_results":
            # This is handled specially in the main loop
            return {"status": "finalized", **tool_args}
        
        else:
            return {"error": f"Unknown tool: {tool_name}"}
    
    async def _spell_check_query(self, query: str) -> tuple[str, bool, str]:
        """
        Use LLM to check and correct spelling errors in the query.
        
        Only fixes typos and spelling mistakes - does NOT change query semantics.
        
        Args:
            query: The original user query
            
        Returns:
            Tuple of (corrected_query, was_corrected, explanation)
            - corrected_query: The spell-checked query (or original if no errors)
            - was_corrected: True if any corrections were made
            - explanation: Brief description of changes (or "No corrections needed")
        """
        import time
        start_time = time.time()
        
        try:
            prompt = f"""You are a spell checker. Your ONLY job is to fix typos and spelling errors in the query.

RULES:
1. ONLY fix obvious spelling mistakes and typos
2. DO NOT change the meaning or intent of the query
3. DO NOT add or remove words
4. DO NOT change proper nouns, names, or technical terms unless they are clearly misspelled
5. Preserve the original case pattern when possible
6. If the query has no spelling errors, return it EXACTLY as-is

Examples:
- "shwo my latset pan crad" → "show my latest pan card" (typo fixes)
- "waht is my PAN numbr" → "what is my PAN number" (typo fix)
- "documetns about AI" → "documents about AI" (typo fix)
- "show my resume" → "show my resume" (no change needed)
- "find centric consulting" → "find centric consulting" (no change - proper noun)

Query to check: "{query}"

Respond in this EXACT format:
CORRECTED: <the corrected query or original if no errors>
CHANGED: <YES or NO>
EXPLANATION: <brief description of changes or "No corrections needed">"""

            # Use Groq for spell check - using fast 8B model for speed
            response = self.client.chat.completions.create(
                model="llama-3.1-8b-instant",
                messages=[{"role": "user", "content": prompt}],
                temperature=0.1,
                max_tokens=200
            )
            
            response_text = response.choices[0].message.content.strip()
            
            # Parse the response
            corrected_query = query  # Default to original
            was_corrected = False
            explanation = "No corrections needed"
            
            for line in response_text.split("\n"):
                line = line.strip()
                if line.startswith("CORRECTED:"):
                    corrected_query = line[10:].strip()
                    # Remove surrounding quotes if present
                    if corrected_query.startswith('"') and corrected_query.endswith('"'):
                        corrected_query = corrected_query[1:-1]
                    elif corrected_query.startswith("'") and corrected_query.endswith("'"):
                        corrected_query = corrected_query[1:-1]
                elif line.startswith("CHANGED:"):
                    was_corrected = "YES" in line.upper()
                elif line.startswith("EXPLANATION:"):
                    explanation = line[12:].strip()
            
            duration_ms = int((time.time() - start_time) * 1000)
            
            if was_corrected:
                logger.info(f"Spell check: '{query}' → '{corrected_query}' ({explanation}) [{duration_ms}ms]")
            else:
                logger.debug(f"Spell check: no corrections needed for '{query}' [{duration_ms}ms]")
            
            return corrected_query, was_corrected, explanation
            
        except Exception as e:
            logger.warning(f"Spell check failed: {e} - using original query")
            return query, False, f"Spell check failed: {str(e)[:50]}"
    
    async def _verify_relevance_with_llm(
        self,
        query: str,
        results: List[SearchResult]
    ) -> List[SearchResult]:
        """
        Use LLM to verify that search results are actually relevant to the query.
        
        This catches cases where reranker scores are high but semantic match is poor.
        Always runs - no filtering by candidate count.
        
        Args:
            query: The user's search query
            results: List of SearchResult objects from search
            
        Returns:
            Filtered list of only truly relevant results
        """
        if not results:
            return []
        
        start_time = time.time()
        
        # Build candidate list for LLM
        candidates_text = "\n".join([
            f"{i+1}. Title: {r.title}\n   Preview: {r.content_preview[:200] if r.content_preview else 'No preview'}"
            for i, r in enumerate(results[:10])  # Limit to 10 for LLM context
        ])
        
        prompt = f"""You are a search relevance validator. Given the user's search query, identify which documents are ACTUALLY RELEVANT.

User's Search Query: "{query}"

Available Documents:
{candidates_text}

Instructions:
1. Analyze semantic relevance between the query and each document
2. A document is relevant ONLY if it directly answers or relates to the user's query
3. Return the numbers of ALL relevant documents
4. Format: comma-separated numbers (e.g., "1, 3, 5")
5. If NONE of the documents are relevant to the query, return "NONE"
6. Be STRICT - if a document doesn't match the query intent, exclude it

Relevant document numbers:"""

        try:
            response = self.client.chat.completions.create(
                model=self.FAST_MODEL,  # Use fast model for filtering
                messages=[
                    {"role": "system", "content": "You are a search relevance expert. Return only document numbers, nothing else."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0,
                max_tokens=30
            )
            
            result_text = response.choices[0].message.content.strip()
            duration_ms = int((time.time() - start_time) * 1000)
            
            if result_text.upper() == "NONE":
                logger.info(f"LLM relevance check: NONE of {len(results)} results are relevant [{duration_ms}ms]")
                return []
            
            # Parse the numbers
            selected_indices = []
            for num in result_text.replace(",", " ").split():
                try:
                    idx = int(num.strip()) - 1  # Convert to 0-based
                    if 0 <= idx < len(results):
                        selected_indices.append(idx)
                except ValueError:
                    continue
            
            filtered_results = [results[i] for i in selected_indices]
            logger.info(f"LLM relevance check: {len(filtered_results)}/{len(results)} results verified as relevant [{duration_ms}ms]")
            
            return filtered_results
            
        except Exception as e:
            logger.warning(f"LLM relevance verification failed: {e} - returning all results")
            return results
    
    @log_operation(
        service="rag_agent",
        operation="search",
        extract_input=lambda args, kwargs: {
            "query_length": len(kwargs.get("query", "") or (args[1] if len(args) > 1 else "")),
            "max_results": kwargs.get("max_results", 10)
        },
        extract_output=lambda r: {
            "documents_count": len(r.documents) if r else 0,
            "has_answer": bool(r.answer) if r else False,
            "iterations": len(r.agent_steps) if r else 0,
            "total_duration_ms": r.total_duration_ms if r else 0
        }
    )
    async def search(
        self,
        query: str,
        user_id: str = "default_user",
        max_results: int = 10
    ) -> SearchResponse:
        """
        Main search entry point. Analyzes query and runs agentic retrieval.
        
        Args:
            query: Natural language search query
            user_id: User identifier
            max_results: Maximum documents to return
        
        Returns:
            SearchResponse with documents, optional answer, and metadata
        """
        import time
        start_time = time.time()
        
        self._user_id = user_id
        self._all_results = {}
        self._steps = []
        
        original_query = query
        logger.debug(f"=== RAG SEARCH START === query='{query}', user_id={user_id}, max_results={max_results}")
        
        # STEP 0: Spell Check + Tag Fetch in PARALLEL for performance
        step_start = time.time()
        
        # Run spell check and tag fetch concurrently to save ~2s
        spell_check_task = self._spell_check_query(query)
        tags_task = self.retrieval_tools.get_all_tags(user_id)
        
        (corrected_query, was_corrected, spell_explanation), available_tags_result = await asyncio.gather(
            spell_check_task,
            tags_task
        )
        
        # Extract available tags for later use
        available_tags = [t["tag"] for t in available_tags_result]
        parallel_duration = int((time.time() - step_start) * 1000)
        
        logger.debug(f"Parallel spell check + tag fetch completed in {parallel_duration}ms")
        
        self._steps.append(AgentStep(
            step_number=0,
            state=AgentState.ANALYZING,
            action="spell_check_and_tags",
            tool_name="spell_check",
            tool_input={"original_query": query},
            tool_output={
                "corrected_query": corrected_query,
                "was_corrected": was_corrected,
                "explanation": spell_explanation,
                "available_tags": available_tags
            },
            thought=f"Spell check: {spell_explanation}" if was_corrected else "No spelling corrections needed",
            duration_ms=parallel_duration
        ))
        
        # Use corrected query for all subsequent operations
        if was_corrected:
            query = corrected_query
            logger.info(f"Using spell-corrected query: '{original_query}' → '{query}'")
        
        # FAST PATH: Check if this is a discovery query - bypass agent entirely
        if self._is_discovery_query(query):
            logger.info(f"Discovery query detected: '{query}' - using fast path")
            logger.debug("Fast path triggered - skipping LLM agent, using direct hybrid search + LLM relevance check")
            
            step_start = time.time()
            search_results = await self.retrieval_tools.hybrid_search(
                query=query,
                user_id=user_id,
                limit=max_results * 2
            )
            
            # LLM relevance verification - always runs even in fast path
            if search_results:
                search_results = await self._verify_relevance_with_llm(query, search_results)
            
            self._steps.append(AgentStep(
                step_number=1,
                state=AgentState.SEARCHING,
                action="direct_hybrid_search",
                tool_name="hybrid_search",
                tool_input={"query": query, "limit": max_results * 2},
                tool_output={"results_count": len(search_results)},
                thought="Discovery query - using hybrid_search directly (fast path) + LLM relevance check",
                duration_ms=int((time.time() - step_start) * 1000)
            ))
            
            # Apply threshold only for non-reranked results
            # Reranked results use cross-encoder scores which are NOT 0-1 similarity
            threshold = self.SIMILARITY_THRESHOLDS.get("hybrid", 0.25)
            
            # Check if results were reranked (source contains 'reranked')
            is_reranked = search_results and search_results[0].source.endswith("_reranked")
            
            if is_reranked:
                # Reranker already sorted by relevance, just take top results
                filtered_results = search_results[:max_results]
            else:
                # Apply cosine similarity threshold for non-reranked results
                filtered_results = [r for r in search_results if r.similarity_score >= threshold][:max_results]
            
            # Convert SearchResult to dict
            documents = [asdict(r) for r in filtered_results]
            
            # Generate download URLs
            download_urls = await self.retrieval_tools.get_blob_urls(filtered_results)
            
            total_duration = int((time.time() - start_time) * 1000)
            
            # Log for RAGAS evaluation (async, non-blocking)
            try:
                eval_logger = get_rag_eval_logger()
                contexts = [
                    {
                        "note_id": r.note_id,
                        "content": r.content_preview,
                        "similarity_score": r.similarity_score,
                        "title": r.title
                    }
                    for r in filtered_results
                ]
                await eval_logger.log_rag_interaction(
                    user_id=user_id,
                    query=query,
                    retrieved_contexts=contexts,
                    note_ids=[r.note_id for r in filtered_results],
                    answer=None,  # Discovery queries don't generate answers
                    search_type="hybrid_search_fast_path",
                    search_duration_ms=total_duration
                )
            except Exception as e:
                logger.warning(f"Failed to log RAG interaction for evaluation: {e}")
            
            # Store backend trace data (fire-and-forget)
            try:
                from app.core.log_context import current_correlation_id
                corr_id = current_correlation_id.get()
                if corr_id:
                    cb_stats = get_circuit_breaker_stats()
                    asyncio.create_task(_store_backend_trace(
                        correlation_id=corr_id,
                        original_query=original_query,
                        corrected_query=query,
                        was_corrected=was_corrected,
                        spell_explanation=spell_explanation,
                        spell_duration_ms=parallel_duration,
                        tags_available=available_tags,
                        tags_detected=[],  # Fast path doesn't do tag detection
                        tag_intent=None,
                        tags_cache_hit=False,  # We don't track this yet
                        tags_duration_ms=parallel_duration,
                        query_intent="discovery",
                        query_complexity="simple",
                        query_keywords=[],
                        needs_synthesis=False,
                        analysis_duration_ms=0,
                        circuit_breaker_open=cb_stats["is_open"],
                        circuit_breaker_avg_ms=int(cb_stats["avg_response_time_ms"]),
                        synthesis_cache_hit=False,
                        synthesis_cache_key=None,
                        synthesis_duration_ms=0,
                        agent_steps=[asdict(s) for s in self._steps],
                        backend_metadata={"fast_path": True, "threshold": threshold},
                        total_duration_ms=total_duration
                    ))
            except Exception as e:
                logger.warning(f"Failed to queue backend trace: {e}")
            
            return SearchResponse(
                query=query,
                documents=documents,
                answer=None,
                download_urls=download_urls,
                metadata={
                    "query_type": "discovery",
                    "fast_path": True,
                    "search_type": "hybrid_search",
                    "threshold": threshold,
                    "total_candidates": len(search_results),
                    "filtered_count": len(filtered_results),
                    "original_query": original_query,
                    "spell_corrected": was_corrected,
                    "spell_explanation": spell_explanation if was_corrected else None
                },
                agent_steps=self._steps,
                total_duration_ms=total_duration
            )
        
        # NORMAL PATH: Full query analysis for complex queries
        logger.debug("Using NORMAL PATH - full query analysis")
        step_start = time.time()
        # Tags already fetched in parallel with spell check above
        logger.info(f"🏷️ AVAILABLE TAGS from DB: {available_tags}")
        logger.info(f"🔍 ANALYZING QUERY: '{query}'")
        
        analysis = await self.query_analyzer.analyze_query(query, available_tags)
        logger.debug(f"Query analysis: intent={analysis.intent.value}, complexity={analysis.complexity.value}, "
                    f"tags={analysis.detected_tags}, keywords={analysis.keywords}, synthesis={analysis.needs_synthesis}")
        
        self._steps.append(AgentStep(
            step_number=1,
            state=AgentState.ANALYZING,
            action="analyze_query",
            tool_name=None,
            tool_input={"query": query},
            tool_output={
                "intent": analysis.intent.value,
                "complexity": analysis.complexity.value,
                "max_iterations": analysis.max_iterations,
                "detected_tags": analysis.detected_tags,
                "needs_synthesis": analysis.needs_synthesis
            },
            thought="Analyzing query to determine search strategy",
            duration_ms=int((time.time() - step_start) * 1000)
        ))
        
        # TAG-BASED SEARCH PATH: When tag is detected, classify intent and choose appropriate search
        can_use_tag_path = (
            analysis.detected_tags and  # Tag was detected in query
            not analysis.needs_synthesis and  # No answer synthesis required
            analysis.intent in (QueryIntent.LIST, QueryIntent.RETRIEVE)  # Simple retrieval intent
        )
        
        # Initialize variables used in both paths
        finalized = False
        final_note_ids = []
        final_answer = None
        final_reasoning = ""
        iteration = 0
        
        if can_use_tag_path:
            logger.info(f"🏷️ TAG PATH: Tag detected ({analysis.detected_tags}), classifying intent...")
            
            # Step 1: Extract keywords beyond the tag
            remaining_query, meaningful_keywords = self._extract_keywords_beyond_tag(query, analysis.detected_tags)
            
            # Step 2: Classify intent using fast LLM
            tag_intent = await self._classify_tag_intent(query, analysis.detected_tags, meaningful_keywords)
            
            step_start = time.time()
            
            if tag_intent == TagSearchIntent.LIST_ALL:
                # LIST_ALL: User wants all docs for this tag
                logger.info(f"🏷️ TAG PATH: LIST_ALL - returning all docs for tags: {analysis.detected_tags}")
                
                for tag in analysis.detected_tags:
                    tag_results = await self.retrieval_tools.search_by_tag(
                        tag=tag,
                        user_id=user_id,
                        limit=max_results
                    )
                    for r in tag_results:
                        self._all_results[r.note_id] = r
                
                tool_name = "search_by_tag"
                thought = f"User wants all docs for tag(s): {analysis.detected_tags}"
                
            else:
                # SPECIFIC: User wants specific info within the tag - use hybrid search
                logger.info(f"🏷️ TAG PATH: SPECIFIC - searching for '{remaining_query}' within tags: {analysis.detected_tags}")
                
                # Use the meaningful keywords for search, filtered by tag
                search_query = ' '.join(meaningful_keywords) if meaningful_keywords else query
                
                for tag in analysis.detected_tags:
                    tag_results = await self.retrieval_tools.hybrid_search(
                        query=search_query,
                        user_id=user_id,
                        tag=tag,  # Filter by detected tag
                        limit=max_results
                    )
                    for r in tag_results:
                        self._all_results[r.note_id] = r
                
                tool_name = "hybrid_search"
                thought = f"User wants specific info '{search_query}' within tag(s): {analysis.detected_tags}"
            
            # Record the step
            self._steps.append(AgentStep(
                step_number=len(self._steps) + 1,
                state=AgentState.SEARCHING,
                action="tag_path_search",
                tool_name=tool_name,
                tool_input={
                    "tags": analysis.detected_tags, 
                    "intent": tag_intent.value,
                    "meaningful_keywords": meaningful_keywords
                },
                tool_output=f"[{len(self._all_results)} results]",
                thought=thought,
                duration_ms=int((time.time() - step_start) * 1000)
            ))
            
            # Set final_note_ids from results
            final_note_ids = list(self._all_results.keys())[:max_results]
            final_answer = None
            final_reasoning = f"Tag-based search ({tag_intent.value}) for: {analysis.detected_tags}"
            
            # Skip to Step 3 (final response building)
        else:
            # Step 2: Run agent loop (normal path)
            logger.debug("Using LLM agent loop for search")
            messages = [
                {"role": "system", "content": self._build_system_prompt(analysis)},
                {"role": "user", "content": f"Find relevant documents for: {query}"}
            ]
            
            while not finalized and iteration < analysis.max_iterations:
                iteration += 1
                logger.debug(f"LLM iteration {iteration}/{analysis.max_iterations}")
                step_start = time.time()
                
                try:
                    logger.debug(f"Calling LLM: {self.MODEL}")
                    response = self.client.chat.completions.create(
                        model=self.MODEL,
                        messages=messages,
                        tools=TOOLS,
                        tool_choice="auto",
                        temperature=self.TEMPERATURE,
                        max_tokens=2000
                    )
                    llm_duration = int((time.time() - step_start) * 1000)
                    logger.debug(f"LLM response received in {llm_duration}ms")
                    
                    message = response.choices[0].message
                    
                    # Check if model wants to use tools
                    if message.tool_calls:
                        logger.debug(f"LLM requested {len(message.tool_calls)} tool call(s)")
                        for tool_call in message.tool_calls:
                            tool_name = tool_call.function.name
                            tool_args = json.loads(tool_call.function.arguments)
                            
                            logger.info(f"Agent calling tool: {tool_name} with args: {tool_args}")
                            
                            # Execute tool
                            tool_start = time.time()
                            tool_result = await self._execute_tool(tool_name, tool_args)
                            tool_duration = int((time.time() - tool_start) * 1000)
                            
                            # Log tool result summary
                            if isinstance(tool_result, list):
                                logger.debug(f"Tool {tool_name} returned {len(tool_result)} results in {tool_duration}ms")
                            else:
                                logger.debug(f"Tool {tool_name} completed in {tool_duration}ms")
                            
                            # Record step
                            self._steps.append(AgentStep(
                                step_number=len(self._steps) + 1,
                                state=AgentState.SEARCHING if tool_name != "finalize_results" else AgentState.COMPLETE,
                                action=f"call_{tool_name}",
                                tool_name=tool_name,
                                tool_input=tool_args,
                                tool_output=tool_result if not isinstance(tool_result, list) or len(tool_result) < 3 else f"[{len(tool_result)} results]",
                                thought=f"Executing {tool_name}",
                                duration_ms=int((time.time() - step_start) * 1000)
                            ))
                            
                            # Check for finalization
                            if tool_name == "finalize_results":
                                finalized = True
                                # Deduplicate selected_note_ids while preserving order
                                raw_note_ids = tool_args.get("selected_note_ids", [])
                                seen = set()
                                final_note_ids = []
                                for nid in raw_note_ids:
                                    if nid not in seen:
                                        seen.add(nid)
                                        final_note_ids.append(nid)
                                logger.debug(f"Finalized with {len(final_note_ids)} unique documents")
                                final_answer = tool_args.get("answer", "")
                                final_reasoning = tool_args.get("reasoning", "")
                                break
                            
                            # Add tool result to messages
                            messages.append({
                                "role": "assistant",
                                "content": None,
                                "tool_calls": [tool_call]
                            })
                            messages.append({
                                "role": "tool",
                                "tool_call_id": tool_call.id,
                                "content": json.dumps(tool_result) if isinstance(tool_result, (dict, list)) else str(tool_result)
                            })
                    else:
                        # Model didn't call tools - might have a direct response
                        if message.content:
                            logger.info(f"Agent response without tools: {message.content[:200]}")
                        # Force finalization with current results
                        finalized = True
                        final_note_ids = list(self._all_results.keys())[:max_results]
                        final_reasoning = "Agent completed without explicit finalization"
                        
                except Exception as e:
                    logger.error(f"Agent iteration error: {e}")
                    self._steps.append(AgentStep(
                        step_number=len(self._steps) + 1,
                        state=AgentState.ERROR,
                        action="error",
                        tool_name=None,
                        tool_input=None,
                        tool_output={"error": str(e)},
                        thought=f"Error during iteration: {e}",
                        duration_ms=int((time.time() - step_start) * 1000)
                    ))
                    break
        
        # Step 3: Build final response
        # Get selected documents
        documents = []
        # Threshold varies by source:
        # - hybrid: 0.2 (combined score is weighted, pure vector ≈ 0.3 → combined ≈ 0.21)
        # - vector: 0.3 (pure cosine similarity)
        # - chunk: 0.3 (pure cosine similarity)
        SIMILARITY_THRESHOLDS = {
            "hybrid": 0.2,
            "vector": 0.3,
            "chunk": 0.3,
            "tag": 0.0,  # Tag search is exact match, no similarity filter
        }
        DEFAULT_THRESHOLD = 0.25
        
        # Check if query has significant keywords (for text_rank filtering)
        # But disable text_rank filtering for temporal queries - we need all candidates for date sorting
        query_has_keywords = bool(analysis.keywords and len(analysis.keywords) > 0)
        is_temporal_query = analysis.temporal_sort != TemporalSort.NONE
        
        logger.debug(f"Processing {len(final_note_ids)} documents for filtering (keywords={query_has_keywords}, temporal={is_temporal_query})")
        
        for note_id in final_note_ids[:max_results]:
            if note_id in self._all_results:
                r = self._all_results[note_id]
                # Apply source-aware similarity threshold
                threshold = SIMILARITY_THRESHOLDS.get(r.source, DEFAULT_THRESHOLD)
                if r.similarity_score < threshold:
                    logger.debug(f"Filtered out {note_id} (score {r.similarity_score:.3f} < {threshold} for {r.source})")
                    continue
                
                # For hybrid search: filter out documents with text_rank=0 when query has keywords
                # text_rank=0 means the document doesn't contain the search keywords
                # EXCEPT for:
                # 1. Temporal queries where we need all candidates for date-based sorting
                # 2. Documents with high vector similarity (>0.5) - trust semantic match even without keyword match
                #    This handles spelling variations (aadhar vs aadhaar) and synonyms
                # Note: Use threshold < 0.001 to handle floating-point precision (e.g., 2.2e-16)
                if r.source == "hybrid" and query_has_keywords and not is_temporal_query:
                    text_rank = r.metadata.get("text_rank", 0.0) if r.metadata else 0.0
                    vector_similarity = r.metadata.get("vector_similarity", r.similarity_score) if r.metadata else r.similarity_score
                    
                    # High semantic similarity (>0.5) overrides lack of keyword match
                    # This prevents filtering out semantically relevant docs with spelling variations
                    if text_rank < 0.001 and vector_similarity < 0.5:
                        logger.info(f"Filtered out {note_id} (text_rank={text_rank:.6f}, vec_sim={vector_similarity:.3f}, no keyword match for keywords: {analysis.keywords})")
                        continue
                    elif text_rank < 0.001:
                        logger.debug(f"Keeping {note_id} despite text_rank=0 due to high vector similarity ({vector_similarity:.3f})")
                    else:
                        logger.debug(f"Including {note_id} with text_rank={text_rank:.4f}")
                
                documents.append({
                    "note_id": r.note_id,
                    "title": r.title,
                    "content_preview": r.content_preview,
                    "tag": r.tag,
                    "file_type": r.file_type,
                    "similarity_score": r.similarity_score,
                    "source": r.source,
                    "metadata": r.metadata
                })
        
        logger.debug(f"After filtering: {len(documents)} documents remain")
        
        # Apply tag filter if tags were detected - ensure results match detected tags
        if analysis.detected_tags and documents:
            detected_tags_lower = [t.lower() for t in analysis.detected_tags]
            filtered_docs = [d for d in documents if d.get("tag", "").lower() in detected_tags_lower]
            if filtered_docs:
                removed_count = len(documents) - len(filtered_docs)
                if removed_count > 0:
                    logger.info(f"Tag filter removed {removed_count} documents not matching detected tags: {analysis.detected_tags}")
                documents = filtered_docs
        
        # If no documents from agent, fall back to hybrid search
        # The hybrid_search_notes RPC combines vector + full-text search at SQL level
        if not documents:
            logger.warning("Agent returned no documents, falling back to hybrid search")
            
            # If we have detected tags, use tag-filtered search first
            if analysis.detected_tags:
                logger.info(f"Fallback: Using tag-filtered search for tags: {analysis.detected_tags}")
                for tag in analysis.detected_tags:
                    tag_results = await self.retrieval_tools.search_by_tag(
                        tag=tag,
                        user_id=user_id,
                        limit=max_results
                    )
                    for r in tag_results:
                        if r.note_id not in self._all_results:
                            documents.append({
                                "note_id": r.note_id,
                                "title": r.title,
                                "content_preview": r.content_preview,
                                "tag": r.tag,
                                "file_type": r.file_type,
                                "similarity_score": r.similarity_score,
                                "source": r.source,
                                "metadata": r.metadata
                            })
                            self._all_results[r.note_id] = r
            
            # If still no documents, use hybrid search (vector + full-text)
            # The SQL function handles keyword matching efficiently
            if not documents:
                fallback_results = await self.retrieval_tools.hybrid_search(
                    query=query,
                    user_id=user_id,
                    limit=max_results
                )
                
                # Use source-aware threshold for fallback
                fallback_threshold = SIMILARITY_THRESHOLDS.get("hybrid", DEFAULT_THRESHOLD)
                
                for r in fallback_results:
                    # The combined_score from hybrid search already factors in text relevance
                    # Documents with text_rank > 0 have keyword matches
                    if r.similarity_score < fallback_threshold:
                        logger.info(f"Fallback filtered out {r.note_id} (score {r.similarity_score:.3f} < {fallback_threshold})")
                        continue
                    
                    # Filter out documents with text_rank=0 (no keyword matches)
                    # EXCEPT when vector similarity is high (>0.5) - trust semantic match
                    # This handles spelling variations (aadhar vs aadhaar) and synonyms
                    # Note: Use threshold < 0.001 to handle floating-point precision (e.g., 2.2e-16)
                    text_rank = r.metadata.get("text_rank", 0.0) if r.metadata else 0.0
                    vector_similarity = r.metadata.get("vector_similarity", r.similarity_score) if r.metadata else r.similarity_score
                    
                    # High semantic similarity (>0.5) overrides lack of keyword match
                    if text_rank < 0.001 and vector_similarity < 0.5:
                        logger.info(f"Fallback filtered out {r.note_id} with text_rank={text_rank:.6f}, vec_sim={vector_similarity:.3f} (no keyword matches)")
                        continue
                    elif text_rank < 0.001:
                        logger.info(f"Fallback keeping {r.note_id} despite text_rank=0 due to high vector similarity ({vector_similarity:.3f})")
                    else:
                        logger.info(f"Including {r.note_id} with text_rank={text_rank:.4f} (has keyword matches)")
                    
                    documents.append({
                        "note_id": r.note_id,
                        "title": r.title,
                        "content_preview": r.content_preview,
                        "tag": r.tag,
                        "file_type": r.file_type,
                        "similarity_score": r.similarity_score,
                        "source": r.source,
                        "metadata": r.metadata
                    })
                    self._all_results[r.note_id] = r
                
                # Sort by text_rank descending to prioritize keyword matches
                if documents:
                    documents.sort(
                        key=lambda d: d.get("metadata", {}).get("text_rank", 0.0),
                        reverse=True
                    )
        
        # Apply tag filter if tags were detected - ensure results match detected tags
        if analysis.detected_tags and documents:
            detected_tags_lower = [t.lower() for t in analysis.detected_tags]
            filtered_docs = [d for d in documents if d.get("tag", "").lower() in detected_tags_lower]
            if filtered_docs:
                removed_count = len(documents) - len(filtered_docs)
                if removed_count > 0:
                    logger.info(f"Tag filter removed {removed_count} documents not matching detected tags: {analysis.detected_tags}")
                documents = filtered_docs
        
        # Apply temporal sorting if requested
        if documents and analysis.temporal_sort != TemporalSort.NONE:
            # Sort by created_at from metadata
            def get_created_at(doc):
                metadata = doc.get("metadata", {})
                created_at = metadata.get("created_at", "")
                return created_at if created_at else ""
            
            reverse_sort = analysis.temporal_sort == TemporalSort.NEWEST
            documents.sort(key=get_created_at, reverse=reverse_sort)
            logger.info(f"Applied temporal sort: {analysis.temporal_sort.value}, reverse={reverse_sort}")
        
        # Apply limit_to_one constraint
        if analysis.limit_to_one and len(documents) > 1:
            documents = documents[:1]
            logger.info(f"Applied limit_to_one constraint, returning single document")
        
        # Generate download URLs
        results_for_urls = [self._all_results[d["note_id"]] for d in documents if d["note_id"] in self._all_results]
        download_urls = await self.retrieval_tools.get_blob_urls(results_for_urls)
        
        # === SYNTHESIS WITH FULL CONTENT (with Cache + Circuit Breaker) ===
        # Track synthesis for backend trace
        synthesis_cache_hit = False
        synthesis_cache_key = None
        synthesis_duration_ms = 0
        
        # If the query needs answer synthesis and we have documents,
        # re-generate the answer using FULL document content (not truncated previews)
        # This ensures the LLM has complete information to answer accurately
        if analysis.needs_synthesis and documents:
            doc_ids = [d.get("note_id", "") for d in documents if d.get("note_id")]
            synthesis_cache_key = _get_synthesis_cache_key(query, doc_ids)
            
            # Check cache first
            cached_answer = _get_cached_synthesis(synthesis_cache_key)
            if cached_answer:
                final_answer = cached_answer
                synthesis_cache_hit = True
                logger.info("Using CACHED synthesis answer")
            # Check circuit breaker
            elif _is_circuit_breaker_open():
                logger.warning("Circuit breaker OPEN - skipping synthesis, returning documents only")
                # Don't set final_answer, user gets documents without synthesis
            else:
                # Normal synthesis path
                logger.info("Query needs synthesis - generating answer with full document content")
                synthesis_start = time.time()
                synthesized_answer = await self._synthesize_answer_with_full_content(
                    query=query,
                    documents=documents,
                    analysis=analysis
                )
                synthesis_duration_ms = int((time.time() - synthesis_start) * 1000)
                
                # Record response time for circuit breaker
                _record_groq_response_time(synthesis_duration_ms)
                
                if synthesized_answer:
                    final_answer = synthesized_answer
                    # Cache the result
                    _set_cached_synthesis(synthesis_cache_key, synthesized_answer)
                    logger.info(f"Using synthesized answer from full content [{synthesis_duration_ms}ms]")
                else:
                    logger.warning("Full content synthesis failed, using original answer")
        
        total_duration = int((time.time() - start_time) * 1000)
        
        logger.debug(f"=== RAG SEARCH COMPLETE === documents={len(documents)}, answer={'yes' if final_answer else 'no'}, duration={total_duration}ms")
        
        # Log for RAGAS evaluation (async, non-blocking)
        try:
            eval_logger = get_rag_eval_logger()
            contexts = [
                {
                    "note_id": d.get("note_id"),
                    "content": d.get("content_preview", ""),
                    "similarity_score": d.get("similarity_score", 0),
                    "title": d.get("title", "")
                }
                for d in documents
            ]
            # Determine search type from analysis
            search_type = f"{analysis.intent.value}_{analysis.complexity.value}"
            
            await eval_logger.log_rag_interaction(
                user_id=user_id,
                query=query,
                retrieved_contexts=contexts,
                note_ids=[d.get("note_id") for d in documents],
                answer=final_answer if final_answer and analysis.needs_synthesis else None,
                search_type=search_type,
                search_duration_ms=total_duration
            )
        except Exception as e:
            logger.warning(f"Failed to log RAG interaction for evaluation: {e}")
        
        # Store backend trace data (fire-and-forget)
        try:
            from app.core.log_context import current_correlation_id
            corr_id = current_correlation_id.get()
            if corr_id:
                cb_stats = get_circuit_breaker_stats()
                asyncio.create_task(_store_backend_trace(
                    correlation_id=corr_id,
                    original_query=original_query,
                    corrected_query=query,
                    was_corrected=was_corrected,
                    spell_explanation=spell_explanation,
                    spell_duration_ms=parallel_duration,
                    tags_available=available_tags,
                    tags_detected=analysis.detected_tags,
                    tag_intent=None,  # Could add this if needed
                    tags_cache_hit=False,  # We don't track this yet
                    tags_duration_ms=parallel_duration,
                    query_intent=analysis.intent.value,
                    query_complexity=analysis.complexity.value,
                    query_keywords=analysis.keywords,
                    needs_synthesis=analysis.needs_synthesis,
                    analysis_duration_ms=int((time.time() - step_start) * 1000) if 'step_start' in dir() else 0,
                    circuit_breaker_open=cb_stats["is_open"],
                    circuit_breaker_avg_ms=int(cb_stats["avg_response_time_ms"]),
                    synthesis_cache_hit=synthesis_cache_hit,
                    synthesis_cache_key=synthesis_cache_key,
                    synthesis_duration_ms=synthesis_duration_ms,
                    agent_steps=[asdict(s) for s in self._steps],
                    backend_metadata={
                        "iterations_used": iteration,
                        "reasoning": final_reasoning,
                        "confidence": analysis.confidence,
                        "temporal_sort": analysis.temporal_sort.value,
                        "limit_to_one": analysis.limit_to_one
                    },
                    total_duration_ms=total_duration
                ))
        except Exception as e:
            logger.warning(f"Failed to queue backend trace: {e}")
        
        return SearchResponse(
            query=query,
            documents=documents,
            answer=final_answer if final_answer and analysis.needs_synthesis else None,
            download_urls=download_urls,
            metadata={
                "analysis": {
                    "intent": analysis.intent.value,
                    "complexity": analysis.complexity.value,
                    "max_iterations": analysis.max_iterations,
                    "needs_synthesis": analysis.needs_synthesis,
                    "detected_tags": analysis.detected_tags,
                    "keywords": analysis.keywords,
                    "confidence": analysis.confidence,
                    "temporal_sort": analysis.temporal_sort.value,
                    "limit_to_one": analysis.limit_to_one
                },
                "iterations_used": iteration,
                "reasoning": final_reasoning,
                "original_query": original_query,
                "spell_corrected": was_corrected,
                "spell_explanation": spell_explanation if was_corrected else None
            },
            agent_steps=self._steps,
            total_duration_ms=total_duration
        )


# Singleton instance
_rag_agent_service = None

def get_rag_agent_service() -> RAGAgentService:
    global _rag_agent_service
    if _rag_agent_service is None:
        _rag_agent_service = RAGAgentService()
    return _rag_agent_service
