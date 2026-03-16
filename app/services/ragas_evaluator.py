"""
RAGAS Evaluation Service

Uses RAGAS framework with Groq as LLM judge to evaluate RAG quality.
Implements batch evaluation with configurable sample percentage.

Metrics computed:
- Faithfulness: Is the answer grounded in the retrieved context?
- Context Precision: Are retrieved contexts ranked by relevance?
- Context Recall: Does the context contain all needed information?
- Answer Relevancy: Is the answer relevant to the question?
"""
import logging
import asyncio
from typing import List, Dict, Any, Optional
from datetime import datetime
from uuid import UUID, uuid4
from dataclasses import dataclass

from app.core.config import get_settings
from app.services.rag_eval_logger import get_rag_eval_logger

logger = logging.getLogger(__name__)


@dataclass
class EvaluationResult:
    """Result of a single evaluation"""
    interaction_id: str
    faithfulness: Optional[float]
    context_precision: Optional[float]
    context_recall: Optional[float]
    answer_relevancy: Optional[float]
    error: Optional[str] = None


@dataclass
class BatchEvaluationResult:
    """Result of a batch evaluation run"""
    run_id: str
    total_evaluated: int
    total_sampled: int
    avg_faithfulness: float
    avg_context_precision: float
    avg_context_recall: float
    avg_answer_relevancy: float
    individual_results: List[EvaluationResult]
    started_at: datetime
    completed_at: datetime
    duration_seconds: float


class RAGASEvaluator:
    """
    Evaluates RAG quality using RAGAS metrics with Groq as LLM judge.
    
    Configuration is loaded from rag_evaluation_config table:
    - sample_percentage: % of queries to evaluate (default 50%)
    - llm_judge_model: Groq model for evaluation (default llama-3.3-70b-versatile)
    - enabled_metrics: List of metrics to compute
    """
    
    DEFAULT_SAMPLE_PERCENTAGE = 50.0
    DEFAULT_LLM_MODEL = "llama-3.3-70b-versatile"
    DEFAULT_METRICS = ["faithfulness", "context_precision", "context_recall", "answer_relevancy"]
    
    def __init__(self):
        self.settings = get_settings()
        self._supabase = None
        self._config_cache = None
        self._config_cache_time = None
        self._eval_logger = get_rag_eval_logger()
    
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
    
    async def get_config(self) -> Dict[str, Any]:
        """Get evaluation configuration from database with caching."""
        import time
        import json
        
        # Cache for 5 minutes
        if self._config_cache and self._config_cache_time:
            if time.time() - self._config_cache_time < 300:
                return self._config_cache
        
        try:
            result = self.supabase.table("rag_evaluation_config").select("*").execute()
            
            if result.data:
                config = {}
                for row in result.data:
                    # config_value is stored as JSONB
                    value = row["config_value"]
                    if isinstance(value, str):
                        try:
                            value = json.loads(value)
                        except json.JSONDecodeError:
                            pass
                    config[row["config_key"]] = value
                
                self._config_cache = {
                    "sample_percentage": float(config.get("sample_percentage", self.DEFAULT_SAMPLE_PERCENTAGE)),
                    "llm_judge_model": str(config.get("llm_judge", self.DEFAULT_LLM_MODEL)).strip('"'),
                    "enabled_metrics": config.get("enabled_metrics", self.DEFAULT_METRICS),
                    "min_queries_for_eval": int(config.get("min_queries_for_eval", 10))
                }
            else:
                # Use defaults
                self._config_cache = {
                    "sample_percentage": self.DEFAULT_SAMPLE_PERCENTAGE,
                    "llm_judge_model": self.DEFAULT_LLM_MODEL,
                    "enabled_metrics": self.DEFAULT_METRICS,
                    "min_queries_for_eval": 10
                }
            
            self._config_cache_time = time.time()
            return self._config_cache
            
        except Exception as e:
            logger.warning(f"Failed to load evaluation config, using defaults: {e}")
            return {
                "sample_percentage": self.DEFAULT_SAMPLE_PERCENTAGE,
                "llm_judge_model": self.DEFAULT_LLM_MODEL,
                "enabled_metrics": self.DEFAULT_METRICS,
                "min_queries_for_eval": 10
            }
    
    async def _get_min_queries_for_eval(self) -> int:
        """Get minimum number of queries required before running evaluation."""
        try:
            result = self.supabase.table("rag_evaluation_config") \
                .select("config_value") \
                .eq("config_key", "min_queries_for_eval") \
                .single() \
                .execute()
            
            if result.data:
                return int(result.data.get("config_value", 10))
            return 10  # Default
            
        except Exception as e:
            logger.warning(f"Failed to get min_queries_for_eval, using default: {e}")
            return 10
    
    async def update_config(
        self,
        sample_percentage: Optional[float] = None,
        llm_judge_model: Optional[str] = None,
        enabled_metrics: Optional[List[str]] = None,
        min_queries_for_eval: Optional[int] = None
    ) -> bool:
        """Update evaluation configuration."""
        import json
        
        try:
            updates = []
            
            if sample_percentage is not None:
                if not 1 <= sample_percentage <= 100:
                    raise ValueError("sample_percentage must be between 1 and 100")
                updates.append({
                    "config_key": "sample_percentage", 
                    "config_value": str(sample_percentage)
                })
            
            if llm_judge_model is not None:
                updates.append({
                    "config_key": "llm_judge", 
                    "config_value": json.dumps(llm_judge_model)
                })
            
            if enabled_metrics is not None:
                valid_metrics = {"faithfulness", "context_precision", "context_recall", "answer_relevancy"}
                invalid = set(enabled_metrics) - valid_metrics
                if invalid:
                    raise ValueError(f"Invalid metrics: {invalid}")
                updates.append({
                    "config_key": "enabled_metrics", 
                    "config_value": json.dumps(enabled_metrics)
                })
            
            if min_queries_for_eval is not None:
                if min_queries_for_eval < 1:
                    raise ValueError("min_queries_for_eval must be at least 1")
                updates.append({
                    "config_key": "min_queries_for_eval",
                    "config_value": str(min_queries_for_eval)
                })
            
            for update in updates:
                self.supabase.table("rag_evaluation_config").upsert(
                    update, on_conflict="config_key"
                ).execute()
            
            # Invalidate cache
            self._config_cache = None
            self._config_cache_time = None
            
            return True
            
        except Exception as e:
            logger.error(f"Failed to update evaluation config: {e}")
            return False
    
    def _get_full_contexts_from_notes(self, retrieved_contexts: List[Dict[str, Any]]) -> List[str]:
        """
        Fetch full content_markdown from notes table for each retrieved context.
        
        This ensures RAGAS evaluates against the complete document content,
        not just the title and content_preview stored in rag_evaluation_logs.
        
        Args:
            retrieved_contexts: List of context dicts with note_id, title, content
            
        Returns:
            List of full context strings (title + full content_markdown)
        """
        contexts = []
        
        # Collect all note_ids for batch query
        note_ids = [ctx.get("note_id") for ctx in retrieved_contexts if ctx.get("note_id")]
        
        if not note_ids:
            # Fallback to stored content if no note_ids
            for ctx in retrieved_contexts:
                title = ctx.get("title", "")
                content = ctx.get("content", "")
                if title and content:
                    contexts.append(f"{title}\n\n{content}")
                elif title:
                    contexts.append(title)
                elif content:
                    contexts.append(content)
            return contexts
        
        try:
            # Batch fetch full content from notes table
            result = self.supabase.table("notes").select("id, title, content_markdown").in_("id", note_ids).execute()
            
            # Create lookup map by note_id
            notes_map = {}
            if result.data:
                for note in result.data:
                    notes_map[note["id"]] = {
                        "title": note.get("title", ""),
                        "content_markdown": note.get("content_markdown", "")
                    }
            
            # Build contexts using full content where available
            for ctx in retrieved_contexts:
                note_id = ctx.get("note_id")
                
                if note_id and note_id in notes_map:
                    # Use full content from notes table
                    note_data = notes_map[note_id]
                    title = note_data.get("title", "") or ctx.get("title", "")
                    full_content = note_data.get("content_markdown", "")
                    
                    if title and full_content:
                        contexts.append(f"{title}\n\n{full_content}")
                    elif full_content:
                        contexts.append(full_content)
                    elif title:
                        # Fallback to just title if no content
                        contexts.append(title)
                else:
                    # Fallback to stored content if note not found
                    title = ctx.get("title", "")
                    content = ctx.get("content", "")
                    if title and content:
                        contexts.append(f"{title}\n\n{content}")
                    elif title:
                        contexts.append(title)
                    elif content:
                        contexts.append(content)
            
            logger.debug(f"Fetched full content for {len(notes_map)} notes, built {len(contexts)} contexts")
            return contexts
            
        except Exception as e:
            logger.warning(f"Failed to fetch full content from notes table, using stored content: {e}")
            # Fallback to stored content on error
            for ctx in retrieved_contexts:
                title = ctx.get("title", "")
                content = ctx.get("content", "")
                if title and content:
                    contexts.append(f"{title}\n\n{content}")
                elif title:
                    contexts.append(title)
                elif content:
                    contexts.append(content)
            return contexts

    def _setup_ragas(self, llm_model: str):
        """
        Set up RAGAS with Groq as the LLM judge and local embeddings.
        
        Returns:
            Tuple of (evaluate function, metrics list)
        """
        try:
            from ragas import evaluate
            from ragas.metrics import (
                faithfulness,
                context_precision,
                context_recall,
                answer_relevancy
            )
            from langchain_groq import ChatGroq
            from ragas.llms import LangchainLLMWrapper
            from ragas.embeddings import LangchainEmbeddingsWrapper
            from langchain_core.embeddings import Embeddings
            from langchain_core.language_models.chat_models import BaseChatModel
            from app.services.local_embeddings import get_local_embeddings_service
            
            # Create a wrapper that forces n=1 for Groq compatibility
            # RAGAS uses n>1 for some metrics (like answer_relevancy) which Groq doesn't support
            class GroqN1Wrapper(BaseChatModel):
                """Wrapper that forces n=1 for Groq API compatibility."""
                
                def __init__(self, wrapped_llm: ChatGroq):
                    super().__init__()
                    self._wrapped = wrapped_llm
                
                @property
                def _llm_type(self) -> str:
                    return "groq-n1-wrapper"
                
                def _generate(self, messages, stop=None, run_manager=None, **kwargs):
                    # Force n=1 to avoid Groq API error
                    kwargs['n'] = 1
                    return self._wrapped._generate(messages, stop=stop, run_manager=run_manager, **kwargs)
                
                async def _agenerate(self, messages, stop=None, run_manager=None, **kwargs):
                    # Force n=1 to avoid Groq API error
                    kwargs['n'] = 1
                    return await self._wrapped._agenerate(messages, stop=stop, run_manager=run_manager, **kwargs)
                
                def bind(self, **kwargs):
                    # Intercept bind to also force n=1
                    kwargs['n'] = 1
                    return GroqN1Wrapper(self._wrapped.bind(**kwargs))
                
                @property
                def _identifying_params(self):
                    return self._wrapped._identifying_params
            
            # Create a Langchain-compatible wrapper for local embeddings
            class LocalEmbeddingsWrapper(Embeddings):
                """Wrapper to make local embeddings compatible with Langchain."""
                
                def __init__(self):
                    self._local_embeddings = get_local_embeddings_service()
                
                def _generate_embedding_sync(self, text: str, is_query: bool = True) -> list[float]:
                    """Generate embedding synchronously (bypasses async wrapper)."""
                    if not text or not text.strip():
                        return [0.0] * self._local_embeddings.DIMENSIONS
                    
                    # Add prefix for queries (BGE best practice)
                    if is_query:
                        text = self._local_embeddings.QUERY_PREFIX + text
                    
                    # Truncate if too long
                    words = text.split()
                    if len(words) > 400:
                        text = " ".join(words[:400])
                    
                    # Generate embedding directly (model.encode is sync)
                    embedding = self._local_embeddings._model.encode(text, normalize_embeddings=True)
                    return embedding.tolist()
                
                def embed_documents(self, texts: list[str]) -> list[list[float]]:
                    """Embed a list of documents."""
                    embeddings = []
                    for text in texts:
                        emb = self._generate_embedding_sync(text, is_query=False)
                        embeddings.append(emb)
                    return embeddings
                
                def embed_query(self, text: str) -> list[float]:
                    """Embed a single query."""
                    return self._generate_embedding_sync(text, is_query=True)
            
            # Strip 'groq/' prefix if present (database stores 'groq/model-name' but ChatGroq needs just 'model-name')
            model_name = llm_model
            if model_name.startswith("groq/"):
                model_name = model_name[5:]  # Remove 'groq/' prefix
            
            # Create Groq LLM for RAGAS
            groq_llm = ChatGroq(
                model=model_name,
                api_key=self.settings.groq_api_key,
                temperature=0  # Deterministic for evaluation
            )
            
            # Wrap with n=1 enforcer for Groq compatibility
            # RAGAS uses n>1 for metrics like answer_relevancy which Groq doesn't support
            wrapped_llm = GroqN1Wrapper(groq_llm)
            
            # Wrap for RAGAS
            ragas_llm = LangchainLLMWrapper(wrapped_llm)
            
            # Create embeddings wrapper - pass directly without LangchainEmbeddingsWrapper
            # since calculate_similarity calls embed_query/embed_documents directly
            local_embeddings = LocalEmbeddingsWrapper()
            
            # Configure metrics with Groq LLM and local embeddings
            metrics = []
            
            faithfulness_metric = faithfulness
            faithfulness_metric.llm = ragas_llm
            metrics.append(faithfulness_metric)
            
            context_precision_metric = context_precision
            context_precision_metric.llm = ragas_llm
            metrics.append(context_precision_metric)
            
            context_recall_metric = context_recall
            context_recall_metric.llm = ragas_llm
            metrics.append(context_recall_metric)
            
            answer_relevancy_metric = answer_relevancy
            answer_relevancy_metric.llm = ragas_llm
            answer_relevancy_metric.embeddings = local_embeddings  # Direct wrapper, not LangchainEmbeddingsWrapper
            metrics.append(answer_relevancy_metric)
            
            return evaluate, metrics
            
        except ImportError as e:
            logger.error(f"RAGAS dependencies not installed: {e}")
            raise RuntimeError(
                "RAGAS dependencies not installed. Run: pip install ragas langchain-groq"
            )
    
    async def run_evaluation(
        self,
        max_samples: int = 100,
        sample_percentage_override: Optional[float] = None
    ) -> BatchEvaluationResult:
        """
        Run batch RAGAS evaluation on sampled unevaluated queries.
        
        Args:
            max_samples: Maximum number of samples to evaluate
            sample_percentage_override: Override config sample percentage
        
        Returns:
            BatchEvaluationResult with metrics and individual results
        """
        started_at = datetime.utcnow()
        run_id = str(uuid4())
        
        logger.info(f"Starting RAGAS evaluation run: {run_id}")
        
        try:
            # Get configuration
            config = await self.get_config()
            sample_pct = sample_percentage_override or config["sample_percentage"]
            llm_model = config["llm_judge_model"]
            
            # Get minimum queries required from config
            min_queries = await self._get_min_queries_for_eval()
            
            logger.info(f"Evaluation config: sample_pct={sample_pct}%, model={llm_model}, min_queries={min_queries}")
            
            # Check if we have enough queries
            stats = await self._eval_logger.get_evaluation_stats()
            unevaluated_count = stats.get("unevaluated", 0)
            
            if unevaluated_count < min_queries:
                logger.info(f"Not enough unevaluated queries: {unevaluated_count} < {min_queries} required")
                completed_at = datetime.utcnow()
                return BatchEvaluationResult(
                    run_id=run_id,
                    total_evaluated=0,
                    total_sampled=0,
                    avg_faithfulness=0.0,
                    avg_context_precision=0.0,
                    avg_context_recall=0.0,
                    avg_answer_relevancy=0.0,
                    individual_results=[EvaluationResult(
                        interaction_id="",
                        faithfulness=None,
                        context_precision=None,
                        context_recall=None,
                        answer_relevancy=None,
                        error=f"Insufficient queries: {unevaluated_count} < {min_queries} required"
                    )],
                    started_at=started_at,
                    completed_at=completed_at,
                    duration_seconds=(completed_at - started_at).total_seconds()
                )
            
            # Get sample of unevaluated queries
            samples = await self._eval_logger.get_unevaluated_sample(
                sample_percentage=sample_pct,
                max_samples=max_samples
            )
            
            if not samples:
                logger.info("No unevaluated queries to evaluate")
                completed_at = datetime.utcnow()
                return BatchEvaluationResult(
                    run_id=run_id,
                    total_evaluated=0,
                    total_sampled=0,
                    avg_faithfulness=0.0,
                    avg_context_precision=0.0,
                    avg_context_recall=0.0,
                    avg_answer_relevancy=0.0,
                    individual_results=[],
                    started_at=started_at,
                    completed_at=completed_at,
                    duration_seconds=(completed_at - started_at).total_seconds()
                )
            
            logger.info(f"Sampled {len(samples)} queries for evaluation")
            
            # Prepare data for RAGAS - split into with_answer and retrieval_only
            from datasets import Dataset
            
            # Data for queries WITH answers (full evaluation: all 4 metrics)
            ragas_data_full = {
                "question": [],
                "answer": [],
                "contexts": [],
                "ground_truth": []
            }
            sample_ids_full = []
            
            # Data for retrieval-only queries (context metrics only: precision + recall)
            ragas_data_context = {
                "question": [],
                "answer": [],  # Will use placeholder
                "contexts": [],
                "ground_truth": []
            }
            sample_ids_context = []
            
            skipped_count = 0
            for sample in samples:
                # Extract contexts from retrieved_contexts
                retrieved_contexts = sample.get("retrieved_contexts", [])
                contexts = self._get_full_contexts_from_notes(retrieved_contexts)
                
                # Skip queries with no retrieved context
                if not contexts:
                    logger.debug(f"Skipping query without context: {sample.get('query', '')[:50]}...")
                    skipped_count += 1
                    continue
                
                answer = sample.get("answer", "")
                has_answer = answer and answer.strip() != "" and "retrieval only" not in answer.lower()
                
                if has_answer:
                    # Full evaluation with all 4 metrics
                    ragas_data_full["question"].append(sample["query"])
                    ragas_data_full["answer"].append(answer)
                    ragas_data_full["contexts"].append(contexts)
                    ragas_data_full["ground_truth"].append(" ".join(contexts))
                    sample_ids_full.append(sample["id"])
                else:
                    # Retrieval-only: evaluate context quality only
                    ragas_data_context["question"].append(sample["query"])
                    ragas_data_context["answer"].append("N/A - retrieval only")  # Placeholder
                    ragas_data_context["contexts"].append(contexts)
                    ragas_data_context["ground_truth"].append(" ".join(contexts))
                    sample_ids_context.append(sample["id"])
            
            # Check if we have any valid samples
            total_valid = len(sample_ids_full) + len(sample_ids_context)
            if total_valid == 0:
                logger.info(f"No queries with context to evaluate (skipped {skipped_count})")
                completed_at = datetime.utcnow()
                return BatchEvaluationResult(
                    run_id=run_id,
                    total_evaluated=0,
                    total_sampled=len(samples),
                    avg_faithfulness=0.0,
                    avg_context_precision=0.0,
                    avg_context_recall=0.0,
                    avg_answer_relevancy=0.0,
                    individual_results=[EvaluationResult(
                        interaction_id="",
                        faithfulness=None,
                        context_precision=None,
                        context_recall=None,
                        answer_relevancy=None,
                        error=f"No queries with context to evaluate. Skipped {skipped_count}."
                    )],
                    started_at=started_at,
                    completed_at=completed_at,
                    duration_seconds=(completed_at - started_at).total_seconds()
                )
            
            logger.info(f"Evaluating {len(sample_ids_full)} queries with answers, {len(sample_ids_context)} retrieval-only (skipped {skipped_count})")
            
            # Set up RAGAS metrics
            evaluate_fn, all_metrics = self._setup_ragas(llm_model)
            
            # Import metrics for context-only evaluation
            from ragas.metrics import context_precision, context_recall
            
            individual_results = []
            
            # Run in thread pool since RAGAS uses its own async internally
            def run_ragas_eval(dataset, metrics):
                import nest_asyncio
                nest_asyncio.apply()
                return evaluate_fn(dataset, metrics=metrics)
            
            loop = asyncio.get_event_loop()
            
            # Evaluate queries WITH answers (all 4 metrics)
            if sample_ids_full:
                logger.info(f"Running full RAGAS evaluation on {len(sample_ids_full)} queries with answers...")
                dataset_full = Dataset.from_dict(ragas_data_full)
                result_full = await loop.run_in_executor(
                    None,
                    lambda: run_ragas_eval(dataset_full, all_metrics)
                )
                result_df_full = result_full.to_pandas()
                
                for idx, sample_id in enumerate(sample_ids_full):
                    eval_result = EvaluationResult(
                        interaction_id=sample_id,
                        faithfulness=float(result_df_full.iloc[idx].get("faithfulness", 0)) if "faithfulness" in result_df_full.columns else None,
                        context_precision=float(result_df_full.iloc[idx].get("context_precision", 0)) if "context_precision" in result_df_full.columns else None,
                        context_recall=float(result_df_full.iloc[idx].get("context_recall", 0)) if "context_recall" in result_df_full.columns else None,
                        answer_relevancy=float(result_df_full.iloc[idx].get("answer_relevancy", 0)) if "answer_relevancy" in result_df_full.columns else None
                    )
                    individual_results.append(eval_result)
            
            # Evaluate retrieval-only queries (context metrics only)
            if sample_ids_context:
                logger.info(f"Running context-only RAGAS evaluation on {len(sample_ids_context)} retrieval-only queries...")
                dataset_context = Dataset.from_dict(ragas_data_context)
                
                # Only use context_precision and context_recall for retrieval-only
                context_metrics = [m for m in all_metrics if m.name in ["context_precision", "context_recall"]]
                
                result_context = await loop.run_in_executor(
                    None,
                    lambda: run_ragas_eval(dataset_context, context_metrics)
                )
                result_df_context = result_context.to_pandas()
                
                for idx, sample_id in enumerate(sample_ids_context):
                    eval_result = EvaluationResult(
                        interaction_id=sample_id,
                        faithfulness=None,  # Not applicable for retrieval-only
                        context_precision=float(result_df_context.iloc[idx].get("context_precision", 0)) if "context_precision" in result_df_context.columns else None,
                        context_recall=float(result_df_context.iloc[idx].get("context_recall", 0)) if "context_recall" in result_df_context.columns else None,
                        answer_relevancy=None  # Not applicable for retrieval-only
                    )
                    individual_results.append(eval_result)
            
            # Combine sample IDs
            sample_ids = sample_ids_full + sample_ids_context
            # Collect scores from all results
            scores = {
                "faithfulness": [],
                "context_precision": [],
                "context_recall": [],
                "answer_relevancy": []
            }
            
            for eval_result in individual_results:
                if eval_result.faithfulness is not None:
                    scores["faithfulness"].append(eval_result.faithfulness)
                if eval_result.context_precision is not None:
                    scores["context_precision"].append(eval_result.context_precision)
                if eval_result.context_recall is not None:
                    scores["context_recall"].append(eval_result.context_recall)
                if eval_result.answer_relevancy is not None:
                    scores["answer_relevancy"].append(eval_result.answer_relevancy)
            
            # Calculate averages (replace NaN with 0.0)
            import math
            
            def avg(lst):
                if not lst:
                    return 0.0
                result = sum(lst) / len(lst)
                return 0.0 if math.isnan(result) else result
            
            def safe_float(value):
                """Convert value to float, replacing NaN/inf with 0.0"""
                if value is None:
                    return 0.0
                if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
                    return 0.0
                return float(value)
            
            avg_faithfulness = safe_float(avg(scores["faithfulness"]))
            avg_context_precision = safe_float(avg(scores["context_precision"]))
            avg_context_recall = safe_float(avg(scores["context_recall"]))
            avg_answer_relevancy = safe_float(avg(scores["answer_relevancy"]))
            
            completed_at = datetime.utcnow()
            duration = (completed_at - started_at).total_seconds()
            
            # Build samples_data for reasoning generation (includes query, answer, contexts)
            samples_data = []
            for idx, sample_id in enumerate(sample_ids):
                matching_sample = next((s for s in samples if s.get("id") == sample_id), None)
                if matching_sample:
                    samples_data.append(matching_sample)
            
            # Store results in database (with reasoning for low scores)
            await self._store_evaluation_results(
                run_id=run_id,
                sample_ids=sample_ids,
                individual_results=individual_results,
                avg_faithfulness=avg_faithfulness,
                avg_context_precision=avg_context_precision,
                avg_context_recall=avg_context_recall,
                avg_answer_relevancy=avg_answer_relevancy,
                total_evaluated=len(individual_results),
                sample_percentage=sample_pct,
                llm_model=llm_model,
                started_at=started_at,
                completed_at=completed_at,
                samples_data=samples_data
            )
            
            # Mark queries as evaluated
            await self._eval_logger.mark_as_evaluated(sample_ids, run_id)
            
            logger.info(f"Evaluation complete: {len(individual_results)} queries, "
                       f"faithfulness={avg_faithfulness:.3f}, "
                       f"context_precision={avg_context_precision:.3f}, "
                       f"context_recall={avg_context_recall:.3f}, "
                       f"answer_relevancy={avg_answer_relevancy:.3f}")
            
            return BatchEvaluationResult(
                run_id=run_id,
                total_evaluated=len(individual_results),
                total_sampled=len(samples),
                avg_faithfulness=avg_faithfulness,
                avg_context_precision=avg_context_precision,
                avg_context_recall=avg_context_recall,
                avg_answer_relevancy=avg_answer_relevancy,
                individual_results=individual_results,
                started_at=started_at,
                completed_at=completed_at,
                duration_seconds=duration
            )
            
        except Exception as e:
            logger.error(f"Evaluation failed: {e}", exc_info=True)
            completed_at = datetime.utcnow()
            return BatchEvaluationResult(
                run_id=run_id,
                total_evaluated=0,
                total_sampled=0,
                avg_faithfulness=0.0,
                avg_context_precision=0.0,
                avg_context_recall=0.0,
                avg_answer_relevancy=0.0,
                individual_results=[EvaluationResult(
                    interaction_id="",
                    faithfulness=None,
                    context_precision=None,
                    context_recall=None,
                    answer_relevancy=None,
                    error=str(e)
                )],
                started_at=started_at,
                completed_at=completed_at,
                duration_seconds=(completed_at - started_at).total_seconds()
            )
    
    async def _generate_metric_reasoning(
        self,
        query: str,
        answer: str,
        contexts: List[str],
        scores: Dict[str, float],
        llm_model: str
    ) -> Dict[str, str]:
        """
        Generate human-readable explanations for RAGAS metric scores.
        
        Uses an LLM to analyze why each metric scored the way it did.
        Explains ALL metrics with their purpose and reasoning.
        
        Args:
            query: The user's question
            answer: The generated answer
            contexts: List of retrieved context strings
            scores: Dict with metric names and their scores
            llm_model: The LLM model to use for reasoning
            
        Returns:
            Dict mapping metric names to reasoning strings
        """
        from groq import Groq
        
        reasoning = {}
        
        try:
            client = Groq(api_key=self.settings.groq_api_key)
            
            # Strip 'groq/' prefix if present
            model_name = llm_model
            if model_name.startswith("groq/"):
                model_name = model_name[5:]
            
            # Prepare context summary - include ALL contexts with titles clearly marked
            context_parts = []
            for i, ctx in enumerate(contexts or []):
                # Truncate each context but keep title visible
                ctx_preview = ctx[:600] + "..." if len(ctx) > 600 else ctx
                context_parts.append(f"[Document {i+1}]:\n{ctx_preview}")
            context_text = "\n\n".join(context_parts) if context_parts else "No contexts available"
            
            # Final truncation if still too long
            if len(context_text) > 4000:
                context_text = context_text[:4000] + "\n...[additional documents truncated]"
            
            # Handle None answer for retrieval-only queries
            answer_text = answer if answer else "N/A (retrieval-only query)"
            answer_display = answer_text[:500] + "..." if len(answer_text) > 500 else answer_text
            
            # Collect all metrics with non-None scores to explain
            metrics_to_explain = [(metric, score) for metric, score in scores.items() if score is not None]
            
            if not metrics_to_explain:
                return reasoning
            
            # Build prompt to explain ALL metrics with detailed reasoning
            prompt = f"""You are a RAG (Retrieval-Augmented Generation) evaluation expert. Analyze the following query, answer, and retrieved documents to explain each metric score.

QUESTION: {query}

ANSWER: {answer_display}

RETRIEVED DOCUMENTS:
{context_text}

METRIC SCORES TO EXPLAIN:
"""
            for metric, score in metrics_to_explain:
                score_quality = "HIGH" if score >= 0.7 else "LOW"
                prompt += f"- {metric}: {score:.2f} ({score_quality})\n"
            
            prompt += """
For EACH metric, provide a detailed explanation that includes:
1. What this metric measures (purpose)
2. Why the score was given (specific evidence from the query/answer/documents)
3. If LOW: what could be improved

METRIC DEFINITIONS:
- faithfulness (0-1): Measures if the answer is factually grounded in the retrieved documents. HIGH = all claims in the answer can be verified from the documents. LOW = answer contains information not present in documents (hallucination).

- context_precision (0-1): Measures if relevant documents are ranked higher than irrelevant ones. HIGH = the most useful documents appear first. LOW = irrelevant documents are ranked above relevant ones, wasting context space.

- context_recall (0-1): Measures if the retrieved documents contain all the information needed to answer the question. HIGH = documents have comprehensive coverage. LOW = important information is missing from retrieved documents.

- answer_relevancy (0-1): Measures if the answer directly addresses the user's question. HIGH = answer is focused and on-topic. LOW = answer is off-topic, incomplete, or doesn't address what was asked.

Respond with this EXACT format (use ||| as separator):
metric_name ||| [PURPOSE: brief description] [SCORE REASONING: why this score was given based on evidence] [IMPROVEMENT: suggestion if score is low, or "N/A" if high]

Example format:
faithfulness ||| [PURPOSE: Verifies answer is grounded in documents] [SCORE REASONING: Score 0.95 - The answer correctly states the user's name as "John Smith" which appears in Document 1] [IMPROVEMENT: N/A]
context_precision ||| [PURPOSE: Checks if relevant docs rank higher] [SCORE REASONING: Score 0.30 - Document 2 about taxes was ranked above Document 1 about identity, even though identity was more relevant to the name question] [IMPROVEMENT: Adjust retrieval to better match semantic relevance to the query]
"""

            response = client.chat.completions.create(
                model=model_name,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.3,
                max_tokens=800
            )
            
            # Parse response
            response_text = response.choices[0].message.content
            for line in response_text.strip().split("\n"):
                if "|||" in line:
                    parts = line.split("|||", 1)
                    metric_key = parts[0].strip().lower().replace(" ", "_")
                    explanation = parts[1].strip()
                    
                    # Map to correct metric keys
                    if "faithful" in metric_key:
                        reasoning["faithfulness_reason"] = explanation
                    elif "precision" in metric_key:
                        reasoning["context_precision_reason"] = explanation
                    elif "recall" in metric_key:
                        reasoning["context_recall_reason"] = explanation
                    elif "relevan" in metric_key:
                        reasoning["answer_relevancy_reason"] = explanation
            
            # Fill in any missing metrics with basic explanation
            for metric, score in metrics_to_explain:
                reason_key = f"{metric}_reason"
                if reason_key not in reasoning:
                    score_quality = "above threshold" if score >= 0.7 else "below threshold"
                    reasoning[reason_key] = f"[PURPOSE: See metric definition] [SCORE REASONING: Score {score:.2f} - {score_quality}] [IMPROVEMENT: Analysis unavailable]"
            
        except Exception as e:
            logger.warning(f"Failed to generate metric reasoning: {e}")
            for metric, score in scores.items():
                if score is not None:
                    reasoning[f"{metric}_reason"] = f"[PURPOSE: See metric definition] [SCORE REASONING: Score {score:.2f}] [IMPROVEMENT: Reasoning generation failed - {str(e)[:50]}]"
        
        return reasoning

    async def _store_evaluation_results(
        self,
        run_id: str,
        sample_ids: List[str],
        individual_results: List[EvaluationResult],
        avg_faithfulness: float,
        avg_context_precision: float,
        avg_context_recall: float,
        avg_answer_relevancy: float,
        total_evaluated: int,
        sample_percentage: float,
        llm_model: str,
        started_at: datetime,
        completed_at: datetime,
        samples_data: Optional[List[Dict[str, Any]]] = None
    ) -> bool:
        """Store evaluation results in database."""
        try:
            duration = int((completed_at - started_at).total_seconds())
            
            # Calculate overall score (average of all metrics)
            scores = [avg_faithfulness, avg_context_precision, avg_context_recall, avg_answer_relevancy]
            overall_score = sum(scores) / len(scores) if scores else 0.0
            
            data = {
                "run_name": f"Evaluation Run {run_id[:8]}",
                "sample_size": total_evaluated,
                "sample_percentage": sample_percentage,
                "llm_judge": llm_model,
                "faithfulness_score": avg_faithfulness,
                "context_precision_score": avg_context_precision,
                "context_recall_score": avg_context_recall,
                "answer_relevancy_score": avg_answer_relevancy,
                "overall_score": overall_score,
                "detailed_results": [],  # Individual results stored separately
                "started_at": started_at.isoformat(),
                "completed_at": completed_at.isoformat(),
                "duration_seconds": duration,
                "status": "completed"
            }
            
            result = self.supabase.table("rag_evaluation_results").insert(data).execute()
            
            # Get the created run's ID
            if result.data:
                db_run_id = result.data[0].get("id")
                
                # Store individual scores in rag_evaluation_logs
                for eval_result in individual_results:
                    try:
                        import math
                        def safe_val(v):
                            if v is None:
                                return None
                            if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
                                return 0.0
                            return float(v)
                        
                        update_data = {
                            "evaluation_run_id": db_run_id,
                            "faithfulness_score": safe_val(eval_result.faithfulness),
                            "context_precision_score": safe_val(eval_result.context_precision),
                            "context_recall_score": safe_val(eval_result.context_recall),
                            "answer_relevancy_score": safe_val(eval_result.answer_relevancy)
                        }
                        
                        # Generate reasoning for ALL scores if samples_data is available
                        if samples_data:
                            # Find matching sample
                            sample = next(
                                (s for s in samples_data if s.get("id") == eval_result.interaction_id),
                                None
                            )
                            if sample:
                                scores = {
                                    "faithfulness": eval_result.faithfulness,
                                    "context_precision": eval_result.context_precision,
                                    "context_recall": eval_result.context_recall,
                                    "answer_relevancy": eval_result.answer_relevancy
                                }
                                # Generate reasoning for all scores (not just low ones)
                                has_any_score = any(s is not None for s in scores.values())
                                if has_any_score:
                                    try:
                                        contexts = self._get_full_contexts_from_notes(
                                            sample.get("retrieved_contexts", [])
                                        )
                                        reasoning = await self._generate_metric_reasoning(
                                            query=sample.get("query", ""),
                                            answer=sample.get("answer", ""),
                                            contexts=contexts,
                                            scores=scores,
                                            llm_model=llm_model
                                        )
                                        update_data.update(reasoning)
                                    except Exception as reason_e:
                                        logger.warning(f"Failed to generate reasoning: {reason_e}")
                        
                        self.supabase.table("rag_evaluation_logs").update(
                            update_data
                        ).eq("id", eval_result.interaction_id).execute()
                    except Exception as score_e:
                        logger.warning(f"Failed to store individual score for {eval_result.interaction_id}: {score_e}")
            
            logger.debug(f"Stored evaluation results for run {run_id}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to store evaluation results: {e}")
            return False
    
    async def get_evaluation_history(
        self,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """Get recent evaluation runs."""
        try:
            result = self.supabase.table("rag_evaluation_results") \
                .select("*") \
                .order("created_at", desc=True) \
                .limit(limit) \
                .execute()
            
            return result.data or []
            
        except Exception as e:
            logger.error(f"Failed to get evaluation history: {e}")
            return []
    
    async def get_evaluation_trends(
        self,
        days: int = 30
    ) -> Dict[str, Any]:
        """Get evaluation metric trends over time."""
        try:
            from datetime import timedelta
            
            cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()
            
            result = self.supabase.table("rag_evaluation_results") \
                .select("*") \
                .gte("created_at", cutoff) \
                .order("created_at", desc=False) \
                .execute()
            
            if not result.data:
                return {"runs": [], "trend": "no_data"}
            
            runs = result.data
            
            # Calculate trends
            if len(runs) >= 2:
                first_half = runs[:len(runs)//2]
                second_half = runs[len(runs)//2:]
                
                def avg_metric(data, metric):
                    values = [r[metric] for r in data if r.get(metric) is not None]
                    return sum(values) / len(values) if values else 0
                
                # Use the correct column name from migration
                first_avg = avg_metric(first_half, "faithfulness_score")
                second_avg = avg_metric(second_half, "faithfulness_score")
                
                if second_avg > first_avg + 0.05:
                    trend = "improving"
                elif second_avg < first_avg - 0.05:
                    trend = "declining"
                else:
                    trend = "stable"
            else:
                trend = "insufficient_data"
            
            return {
                "runs": runs,
                "trend": trend,
                "total_runs": len(runs),
                "period_days": days
            }
            
        except Exception as e:
            logger.error(f"Failed to get evaluation trends: {e}")
            return {"runs": [], "trend": "error", "error": str(e)}
    
    async def get_run_details(
        self,
        run_id: str
    ) -> Optional[Dict[str, Any]]:
        """
        Get detailed results for a specific evaluation run, including per-query scores.
        
        Args:
            run_id: The evaluation run ID (from rag_evaluation_results.id)
        
        Returns:
            Dictionary with run summary and individual query results
        """
        try:
            # Get run summary
            run_result = self.supabase.table("rag_evaluation_results") \
                .select("*") \
                .eq("id", run_id) \
                .single() \
                .execute()
            
            if not run_result.data:
                return None
            
            run_data = run_result.data
            
            # Get individual query results for this run (including reasoning)
            queries_result = self.supabase.table("rag_evaluation_logs") \
                .select("id, query, answer, search_type, faithfulness_score, context_precision_score, context_recall_score, answer_relevancy_score, faithfulness_reason, context_precision_reason, context_recall_reason, answer_relevancy_reason, created_at") \
                .eq("evaluation_run_id", run_id) \
                .order("created_at", desc=False) \
                .execute()
            
            individual_results = []
            for query in queries_result.data or []:
                individual_results.append({
                    "interaction_id": query.get("id"),
                    "query": query.get("query"),
                    "answer": query.get("answer"),
                    "search_type": query.get("search_type"),
                    "faithfulness": query.get("faithfulness_score"),
                    "context_precision": query.get("context_precision_score"),
                    "context_recall": query.get("context_recall_score"),
                    "answer_relevancy": query.get("answer_relevancy_score"),
                    "faithfulness_reason": query.get("faithfulness_reason"),
                    "context_precision_reason": query.get("context_precision_reason"),
                    "context_recall_reason": query.get("context_recall_reason"),
                    "answer_relevancy_reason": query.get("answer_relevancy_reason"),
                    "created_at": query.get("created_at")
                })
            
            return {
                "run_id": run_id,
                "run_name": run_data.get("run_name"),
                "created_at": run_data.get("created_at"),
                "completed_at": run_data.get("completed_at"),
                "sample_size": run_data.get("sample_size"),
                "sample_percentage": run_data.get("sample_percentage"),
                "llm_judge_model": run_data.get("llm_judge"),
                "avg_faithfulness": run_data.get("faithfulness_score"),
                "avg_context_precision": run_data.get("context_precision_score"),
                "avg_context_recall": run_data.get("context_recall_score"),
                "avg_answer_relevancy": run_data.get("answer_relevancy_score"),
                "overall_score": run_data.get("overall_score"),
                "duration_seconds": run_data.get("duration_seconds"),
                "status": run_data.get("status"),
                "individual_results": individual_results
            }
            
        except Exception as e:
            logger.error(f"Failed to get run details for {run_id}: {e}")
            return None


# Singleton instance
_ragas_evaluator = None


def get_ragas_evaluator() -> RAGASEvaluator:
    """Get singleton RAGAS evaluator instance."""
    global _ragas_evaluator
    if _ragas_evaluator is None:
        _ragas_evaluator = RAGASEvaluator()
    return _ragas_evaluator
