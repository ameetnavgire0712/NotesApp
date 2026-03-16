"""
Query Analyzer Service
Analyzes user queries to determine intent, complexity, and optimal retrieval strategy
"""
import logging
import re
from typing import Optional, List, Dict, Any
from dataclasses import dataclass
from enum import Enum

from app.core.log_decorators import log_operation

logger = logging.getLogger(__name__)


class QueryComplexity(str, Enum):
    """Query complexity levels for dynamic iteration limits"""
    SIMPLE = "simple"        # 1-2 iterations: direct factual, single document
    MODERATE = "moderate"    # 2-3 iterations: comparison, multi-doc
    COMPLEX = "complex"      # 3-5 iterations: synthesis, multi-hop reasoning


class QueryIntent(str, Enum):
    """User intent classification"""
    RETRIEVE = "retrieve"           # Just get documents (default)
    ANSWER = "answer"               # Need synthesized answer
    COMPARE = "compare"             # Compare multiple documents
    SUMMARIZE = "summarize"         # Summarize content
    LIST = "list"                   # List items matching criteria
    EXPLAIN = "explain"             # Explain a concept from notes


class TemporalSort(str, Enum):
    """Temporal sorting preference"""
    NONE = "none"           # No temporal constraint
    NEWEST = "newest"       # Most recent first (latest, newest, most recent)
    OLDEST = "oldest"       # Oldest first (earliest, first, oldest)


@dataclass
class AnalyzedQuery:
    """Result of query analysis"""
    original_query: str
    cleaned_query: str
    intent: QueryIntent
    complexity: QueryComplexity
    max_iterations: int
    should_expand: bool
    detected_tags: List[str]
    detected_file_types: List[str]
    keywords: List[str]
    needs_synthesis: bool
    confidence: float
    # NEW: Temporal constraints
    temporal_sort: TemporalSort
    limit_to_one: bool  # True if user wants single result (e.g., "the latest")


class QueryAnalyzerService:
    """Analyzes queries to optimize retrieval strategy"""
    
    # Keywords indicating need for synthesized answer
    ANSWER_KEYWORDS = {
        'what', 'why', 'how', 'explain', 'describe', 'summarize',
        'compare', 'difference', 'between', 'analyze', 'tell me',
        'can you', 'could you', 'please'
    }
    
    # Keywords indicating list/retrieval intent
    LIST_KEYWORDS = {
        'find', 'get', 'show', 'list', 'search', 'retrieve',
        'fetch', 'display', 'give me', 'all', 'documents', 'files', 'notes'
    }
    
    # Comparison keywords
    COMPARE_KEYWORDS = {
        'compare', 'versus', 'vs', 'difference', 'similarities',
        'contrast', 'better', 'worse', 'prefer'
    }
    
    # Complexity indicators
    COMPLEX_INDICATORS = {
        'relationship', 'connection', 'across', 'multiple', 
        'all my', 'everything', 'comprehensive', 'detailed',
        'in-depth', 'thoroughly', 'analyze'
    }
    
    SIMPLE_INDICATORS = {
        'quick', 'just', 'only', 'simple', 'latest', 'recent',
        'last', 'single', 'one', 'specific'
    }
    
    # Temporal indicators for sorting
    NEWEST_INDICATORS = {
        'latest', 'newest', 'most recent', 'last', 'recent', 
        'current', 'updated', 'new'
    }
    
    OLDEST_INDICATORS = {
        'oldest', 'earliest', 'first', 'original', 'initial'
    }
    
    # Singular indicators (user wants ONE result)
    SINGULAR_INDICATORS = {
        'the latest', 'the newest', 'the most recent', 'the last',
        'my latest', 'my newest', 'my most recent', 'my last',
        'the oldest', 'the earliest', 'the first',
        'my oldest', 'my earliest', 'my first',
        'single', 'one', 'a '
    }
    
    # File type patterns
    FILE_TYPE_PATTERNS = {
        'screenshot': r'\b(screenshot|image|picture|photo|capture)\b',
        'quick_note': r'\b(quick note|note|jotted|memo)\b',
        'uploaded_file': r'\b(file|document|pdf|doc|upload)\b'
    }
    
    def __init__(self):
        pass
    
    def _clean_query(self, query: str) -> str:
        """Clean and normalize the query"""
        # Remove extra whitespace
        cleaned = ' '.join(query.split())
        # Remove special characters but keep alphanumeric, spaces, and common punctuation
        cleaned = re.sub(r'[^\w\s\-\?\.\,\!\']', '', cleaned)
        return cleaned.strip()
    
    def _detect_intent(self, query_lower: str) -> QueryIntent:
        """Detect the primary intent of the query"""
        # Check for comparison
        if any(kw in query_lower for kw in self.COMPARE_KEYWORDS):
            return QueryIntent.COMPARE
        
        # Check for summarization
        if 'summarize' in query_lower or 'summary' in query_lower:
            return QueryIntent.SUMMARIZE
        
        # Check for explanation
        if 'explain' in query_lower or 'why' in query_lower:
            return QueryIntent.EXPLAIN
        
        # Check for list/retrieval
        if any(kw in query_lower for kw in self.LIST_KEYWORDS):
            return QueryIntent.LIST
        
        # Check for answer (question patterns)
        if query_lower.endswith('?') or any(kw in query_lower for kw in self.ANSWER_KEYWORDS):
            return QueryIntent.ANSWER
        
        # Default to retrieve
        return QueryIntent.RETRIEVE
    
    def _assess_complexity(self, query_lower: str, intent: QueryIntent) -> QueryComplexity:
        """Assess query complexity for iteration limits"""
        # Complex by intent
        if intent in [QueryIntent.COMPARE, QueryIntent.SUMMARIZE]:
            return QueryComplexity.COMPLEX
        
        # Check for complex indicators
        complex_count = sum(1 for ind in self.COMPLEX_INDICATORS if ind in query_lower)
        if complex_count >= 2:
            return QueryComplexity.COMPLEX
        
        # Check for simple indicators
        simple_count = sum(1 for ind in self.SIMPLE_INDICATORS if ind in query_lower)
        if simple_count >= 2:
            return QueryComplexity.SIMPLE
        
        # Length-based heuristic
        words = query_lower.split()
        if len(words) <= 5:
            return QueryComplexity.SIMPLE
        elif len(words) >= 15:
            return QueryComplexity.COMPLEX
        
        return QueryComplexity.MODERATE
    
    def _get_max_iterations(self, complexity: QueryComplexity) -> int:
        """Get maximum iterations based on complexity"""
        return {
            QueryComplexity.SIMPLE: 2,
            QueryComplexity.MODERATE: 3,
            QueryComplexity.COMPLEX: 5
        }[complexity]
    
    def _should_expand_query(self, query_lower: str, intent: QueryIntent) -> bool:
        """Determine if query expansion would help"""
        # Don't expand simple retrieval
        if intent == QueryIntent.LIST:
            return False
        
        # Expand for answer/explain intents
        if intent in [QueryIntent.ANSWER, QueryIntent.EXPLAIN, QueryIntent.COMPARE]:
            return True
        
        # Expand for short queries (might be ambiguous)
        words = query_lower.split()
        if len(words) <= 3:
            return True
        
        return False
    
    def _detect_tags(self, query: str, available_tags: List[str]) -> List[str]:
        """
        Detect any tags mentioned in the query using exact and fuzzy matching
        
        Args:
            query: The user query
            available_tags: List of tags from the database
        
        Returns:
            List of detected tag names
        """
        detected = []
        query_lower = query.lower()
        query_words = set(re.findall(r'\b\w+\b', query_lower))
        
        logger.debug(f"🏷️ TAG DETECTION: query='{query}', available_tags={available_tags}")
        
        for tag in available_tags:
            tag_lower = tag.lower()
            
            # Exact match only - tag appears as whole word in query
            pattern = r'\b' + re.escape(tag_lower) + r'\b'
            if re.search(pattern, query_lower):
                logger.debug(f"🏷️ TAG MATCH: '{tag}' found in query via exact match")
                detected.append(tag)
                continue
            
            # DISABLED: Fuzzy match was causing false positives
            # e.g., "data" in query matching "dataingestion" tag
            # TODO: Re-enable with stricter matching (e.g., min 50% length ratio)
            #
            # # 2. Fuzzy match - handle pluralization and common variations
            # # e.g., "personal documents" should match "personal docs"
            # tag_words = set(re.findall(r'\b\w+\b', tag_lower))
            # 
            # # Check each tag word against query words with fuzzy matching
            # matched_words = 0
            # for tag_word in tag_words:
            #     for query_word in query_words:
            #         # Exact word match
            #         if tag_word == query_word:
            #             matched_words += 1
            #             break
            #         # Prefix match (docs/documents, note/notes)
            #         if len(tag_word) >= 3 and len(query_word) >= 3:
            #             # Tag word is prefix of query word (docs -> documents)
            #             if query_word.startswith(tag_word[:3]) and len(query_word) > len(tag_word):
            #                 matched_words += 1
            #                 logger.debug(f"🏷️ FUZZY: '{tag_word}' prefix matches '{query_word}'")
            #                 break
            #             # Query word is prefix of tag word (documents -> docs)
            #             if tag_word.startswith(query_word[:3]) and len(tag_word) > len(query_word):
            #                 matched_words += 1
            #                 logger.debug(f"🏷️ FUZZY: '{query_word}' prefix matches '{tag_word}'")
            #                 break
            # 
            # # If all tag words matched, consider it a match
            # if tag_words and matched_words == len(tag_words):
            #     logger.debug(f"🏷️ TAG MATCH: '{tag}' found via fuzzy word matching ({matched_words}/{len(tag_words)} words)")
            #     detected.append(tag)
        
        logger.info(f"🏷️ TAG DETECTION RESULT: query='{query[:50]}...', detected={detected}")
        return detected
    
    def _detect_file_types(self, query_lower: str) -> List[str]:
        """Detect file types mentioned in query"""
        detected = []
        for file_type, pattern in self.FILE_TYPE_PATTERNS.items():
            if re.search(pattern, query_lower, re.IGNORECASE):
                detected.append(file_type)
        return detected
    
    def _extract_keywords(self, query: str) -> List[str]:
        """Extract important keywords from query"""
        # Remove common stop words
        stop_words = {
            'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been',
            'being', 'have', 'has', 'had', 'do', 'does', 'did', 'will',
            'would', 'could', 'should', 'may', 'might', 'must', 'shall',
            'can', 'need', 'dare', 'ought', 'used', 'to', 'of', 'in',
            'for', 'on', 'with', 'at', 'by', 'from', 'up', 'about',
            'into', 'over', 'after', 'beneath', 'under', 'above',
            'i', 'me', 'my', 'myself', 'we', 'our', 'ours', 'you',
            'your', 'yours', 'he', 'him', 'his', 'she', 'her', 'hers',
            'it', 'its', 'they', 'them', 'their', 'what', 'which',
            'who', 'whom', 'this', 'that', 'these', 'those', 'am',
            'and', 'but', 'if', 'or', 'because', 'as', 'until', 'while',
            'all', 'any', 'both', 'each', 'few', 'more', 'most', 'other',
            'some', 'such', 'no', 'nor', 'not', 'only', 'own', 'same',
            'so', 'than', 'too', 'very', 'just', 'also', 'now', 'find',
            'get', 'show', 'tell', 'give', 'please', 'help'
        }
        
        # Tokenize and filter
        words = re.findall(r'\b\w+\b', query.lower())
        keywords = [w for w in words if w not in stop_words and len(w) > 2]
        
        # Return unique keywords preserving order
        seen = set()
        unique = []
        for kw in keywords:
            if kw not in seen:
                seen.add(kw)
                unique.append(kw)
        
        return unique[:10]  # Limit to top 10
    
    def _needs_synthesis(self, intent: QueryIntent, query_lower: str) -> bool:
        """Determine if the query needs a synthesized answer"""
        # Always needs synthesis
        if intent in [QueryIntent.ANSWER, QueryIntent.EXPLAIN, QueryIntent.COMPARE, QueryIntent.SUMMARIZE]:
            return True
        
        # Question patterns
        if query_lower.endswith('?'):
            return True
        
        # Question words at start
        question_starters = ['what', 'why', 'how', 'when', 'where', 'who', 'which']
        first_word = query_lower.split()[0] if query_lower else ''
        if first_word in question_starters:
            return True
        
        return False
    
    def _detect_temporal_sort(self, query_lower: str) -> TemporalSort:
        """Detect if query has temporal sorting preference"""
        # Check for newest indicators
        for indicator in self.NEWEST_INDICATORS:
            if indicator in query_lower:
                return TemporalSort.NEWEST
        
        # Check for oldest indicators
        for indicator in self.OLDEST_INDICATORS:
            if indicator in query_lower:
                return TemporalSort.OLDEST
        
        return TemporalSort.NONE
    
    def _detect_limit_to_one(self, query_lower: str) -> bool:
        """Detect if user wants a single result (e.g., 'the latest', 'my newest')"""
        # Check for singular indicators
        for indicator in self.SINGULAR_INDICATORS:
            if indicator in query_lower:
                return True
        
        # Check for patterns like "get me my latest X" (singular intent)
        singular_patterns = [
            r'\b(the|my)\s+(latest|newest|most recent|oldest|earliest|first)\b',
            r'\bget\s+(me\s+)?(my\s+)?(latest|newest|most recent)\b',
            r'\bfind\s+(me\s+)?(my\s+)?(latest|newest|most recent)\b',
            r'\bshow\s+(me\s+)?(my\s+)?(latest|newest|most recent)\b',
        ]
        for pattern in singular_patterns:
            if re.search(pattern, query_lower):
                return True
        
        return False
    
    @log_operation(
        service="query_analyzer",
        operation="analyze_query",
        extract_input=lambda args, kwargs: {
            "query_length": len(kwargs.get("query", "") or (args[1] if len(args) > 1 else "")),
            "has_available_tags": bool(kwargs.get("available_tags"))
        },
        extract_output=lambda r: {
            "intent": r.intent.value if r else None,
            "complexity": r.complexity.value if r else None,
            "max_iterations": r.max_iterations if r else None,
            "needs_synthesis": r.needs_synthesis if r else None,
            "temporal_sort": r.temporal_sort.value if r else None,
            "limit_to_one": r.limit_to_one if r else None
        }
    )
    async def analyze_query(
        self,
        query: str,
        available_tags: Optional[List[str]] = None
    ) -> AnalyzedQuery:
        """
        Analyze a user query to determine optimal retrieval strategy
        
        Args:
            query: The user's natural language query
            available_tags: List of available tags from the database
        
        Returns:
            AnalyzedQuery with all analysis results
        """
        logger.debug(f"=== QUERY ANALYSIS START === query='{query[:100]}...'")
        
        cleaned = self._clean_query(query)
        query_lower = cleaned.lower()
        logger.debug(f"Cleaned query: '{cleaned[:80]}...'")
        
        # Core analysis
        intent = self._detect_intent(query_lower)
        logger.debug(f"Detected intent: {intent.value}")
        
        complexity = self._assess_complexity(query_lower, intent)
        logger.debug(f"Assessed complexity: {complexity.value}")
        
        max_iterations = self._get_max_iterations(complexity)
        should_expand = self._should_expand_query(query_lower, intent)
        logger.debug(f"Max iterations: {max_iterations}, should_expand: {should_expand}")
        
        # Detection
        detected_tags = self._detect_tags(query, available_tags or [])
        logger.debug(f"Detected tags: {detected_tags}")
        
        detected_file_types = self._detect_file_types(query_lower)
        logger.debug(f"Detected file types: {detected_file_types}")
        
        keywords = self._extract_keywords(query)
        logger.debug(f"Extracted keywords: {keywords}")
        
        # Synthesis decision
        needs_synthesis = self._needs_synthesis(intent, query_lower)
        logger.debug(f"Needs synthesis: {needs_synthesis}")
        
        # Temporal detection
        temporal_sort = self._detect_temporal_sort(query_lower)
        limit_to_one = self._detect_limit_to_one(query_lower)
        logger.debug(f"Temporal sort: {temporal_sort.value}, limit_to_one: {limit_to_one}")
        
        # Confidence based on analysis clarity
        confidence = 0.8  # Base confidence
        if detected_tags:
            confidence += 0.1
        if len(keywords) >= 3:
            confidence += 0.1
        confidence = min(confidence, 1.0)
        
        logger.debug(f"=== QUERY ANALYSIS COMPLETE === intent={intent.value}, complexity={complexity.value}, keywords={len(keywords)}, confidence={confidence:.2f}")
        
        return AnalyzedQuery(
            original_query=query,
            cleaned_query=cleaned,
            intent=intent,
            complexity=complexity,
            max_iterations=max_iterations,
            should_expand=should_expand,
            detected_tags=detected_tags,
            detected_file_types=detected_file_types,
            keywords=keywords,
            needs_synthesis=needs_synthesis,
            confidence=confidence,
            temporal_sort=temporal_sort,
            limit_to_one=limit_to_one
        )


# Singleton instance
_query_analyzer_service = None

def get_query_analyzer_service() -> QueryAnalyzerService:
    global _query_analyzer_service
    if _query_analyzer_service is None:
        _query_analyzer_service = QueryAnalyzerService()
    return _query_analyzer_service
