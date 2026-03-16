"""
RAG Evaluation Logging Service

Captures query-context-answer triplets for RAGAS evaluation.
Stores interactions in rag_evaluation_logs table for later batch evaluation.
"""
import logging
from typing import Optional, List, Dict, Any
from datetime import datetime
from uuid import UUID

from app.core.config import get_settings

logger = logging.getLogger(__name__)


class RAGEvaluationLogger:
    """
    Logs RAG interactions for evaluation.
    
    Captures the complete data needed for RAGAS metrics:
    - Query (user question)
    - Retrieved contexts (document chunks with similarity scores)
    - Answer (generated response, if any)
    - Metadata (search type, durations, etc.)
    """
    
    def __init__(self):
        self.settings = get_settings()
        self._supabase = None
    
    @property
    def supabase(self):
        """Lazy-load Supabase client."""
        if self._supabase is None:
            from supabase import create_client
            self._supabase = create_client(
                self.settings.supabase_url,
                self.settings.supabase_service_key
            )
        return self._supabase
    
    async def log_rag_interaction(
        self,
        user_id: str,
        query: str,
        retrieved_contexts: List[Dict[str, Any]],
        note_ids: List[str],
        answer: Optional[str] = None,
        search_type: Optional[str] = None,
        search_duration_ms: Optional[int] = None,
        llm_duration_ms: Optional[int] = None
    ) -> Optional[UUID]:
        """
        Log a RAG interaction for later evaluation.
        
        Args:
            user_id: User who made the query
            query: The search query text
            retrieved_contexts: List of retrieved document contexts with scores
                Each context should have: {note_id, content, similarity_score, title?}
            note_ids: List of returned note IDs
            answer: Generated answer (if synthesis was requested)
            search_type: Type of search used (hybrid, vector, tag, etc.)
            search_duration_ms: Time spent on retrieval
            llm_duration_ms: Time spent on LLM generation
        
        Returns:
            UUID of the logged interaction, or None on failure
        """
        try:
            # Prepare contexts for storage (limit content size)
            processed_contexts = []
            for ctx in retrieved_contexts[:10]:  # Limit to top 10 contexts
                processed_contexts.append({
                    "note_id": str(ctx.get("note_id", "")),
                    "content": str(ctx.get("content", ""))[:2000],  # Limit content size
                    "similarity_score": float(ctx.get("similarity_score", 0)),
                    "title": str(ctx.get("title", ""))[:200]
                })
            
            data = {
                "user_id": user_id,
                "query": query[:1000],  # Limit query size
                "retrieved_contexts": processed_contexts,
                "note_ids": [str(nid) for nid in note_ids],
                "answer": answer[:5000] if answer else None,  # Limit answer size
                "search_type": search_type,
                "total_results": len(note_ids),
                "search_duration_ms": search_duration_ms,
                "llm_duration_ms": llm_duration_ms,
                "evaluated": False
            }
            
            result = self.supabase.table("rag_evaluation_logs").insert(data).execute()
            
            if result.data:
                log_id = result.data[0].get("id")
                logger.debug(f"Logged RAG interaction for evaluation: {log_id}")
                return UUID(log_id) if log_id else None
            
            return None
            
        except Exception as e:
            # Don't fail the main request if logging fails
            logger.warning(f"Failed to log RAG interaction for evaluation: {e}")
            return None
    
    async def log_user_feedback(
        self,
        interaction_id: UUID,
        feedback: str  # 'positive', 'negative', 'neutral'
    ) -> bool:
        """
        Record user feedback for a RAG interaction.
        
        This provides ground truth for evaluation.
        """
        try:
            if feedback not in ('positive', 'negative', 'neutral'):
                logger.warning(f"Invalid feedback value: {feedback}")
                return False
            
            result = self.supabase.table("rag_evaluation_logs").update({
                "user_feedback": feedback,
                "feedback_timestamp": datetime.utcnow().isoformat()
            }).eq("id", str(interaction_id)).execute()
            
            return len(result.data) > 0
            
        except Exception as e:
            logger.warning(f"Failed to log user feedback: {e}")
            return False
    
    async def get_unevaluated_sample(
        self,
        sample_percentage: float = 50.0,
        max_samples: int = 100
    ) -> List[Dict[str, Any]]:
        """
        Get a random sample of unevaluated queries for batch evaluation.
        
        Args:
            sample_percentage: Percentage of queries to sample (1-100)
            max_samples: Maximum number of samples to return
        
        Returns:
            List of query-context-answer triplets for evaluation
        """
        try:
            # Use RPC to call the sampling function
            result = self.supabase.rpc(
                "sample_unevaluated_queries",
                {
                    "sample_pct": sample_percentage,
                    "max_samples": max_samples
                }
            ).execute()
            
            return result.data or []
            
        except Exception as e:
            logger.error(f"Failed to get unevaluated sample: {e}")
            # Fallback: direct query with random sampling
            try:
                result = self.supabase.table("rag_evaluation_logs")\
                    .select("*")\
                    .eq("evaluated", False)\
                    .order("created_at", desc=True)\
                    .limit(max_samples)\
                    .execute()
                
                # Manual random sampling
                import random
                data = result.data or []
                sample_size = int(len(data) * (sample_percentage / 100))
                return random.sample(data, min(sample_size, len(data)))
                
            except Exception as e2:
                logger.error(f"Fallback sampling also failed: {e2}")
                return []
    
    async def mark_as_evaluated(
        self,
        query_ids: List[str],
        evaluation_run_id: str
    ) -> int:
        """
        Mark queries as evaluated and link to evaluation result.
        
        Args:
            query_ids: List of query IDs (as strings)
            evaluation_run_id: The evaluation run ID (as string)
        
        Returns:
            Number of queries marked
        """
        try:
            result = self.supabase.rpc(
                "mark_queries_evaluated",
                {
                    "query_ids": query_ids,
                    "eval_result_id": evaluation_run_id
                }
            ).execute()
            
            return result.data if isinstance(result.data, int) else 0
            
        except Exception as e:
            logger.error(f"Failed to mark queries as evaluated: {e}")
            return 0
    
    async def get_evaluation_stats(self) -> Dict[str, Any]:
        """Get statistics about evaluation data."""
        try:
            # Count total and unevaluated
            total = self.supabase.table("rag_evaluation_logs")\
                .select("id", count="exact")\
                .execute()
            
            unevaluated = self.supabase.table("rag_evaluation_logs")\
                .select("id", count="exact")\
                .eq("evaluated", False)\
                .execute()
            
            with_feedback = self.supabase.table("rag_evaluation_logs")\
                .select("id", count="exact")\
                .neq("user_feedback", None)\
                .execute()
            
            total_count = total.count or 0
            unevaluated_count = unevaluated.count or 0
            evaluated_count = total_count - unevaluated_count
            
            return {
                "total": total_count,
                "evaluated": evaluated_count,
                "unevaluated": unevaluated_count,
                "with_feedback": with_feedback.count or 0
            }
            
        except Exception as e:
            logger.error(f"Failed to get evaluation stats: {e}")
            return {
                "total_interactions": 0,
                "unevaluated_count": 0,
                "evaluated_count": 0,
                "with_feedback_count": 0
            }


# Singleton instance
_eval_logger: Optional[RAGEvaluationLogger] = None


def get_rag_eval_logger() -> RAGEvaluationLogger:
    """Get or create the RAG evaluation logger singleton."""
    global _eval_logger
    if _eval_logger is None:
        _eval_logger = RAGEvaluationLogger()
    return _eval_logger
