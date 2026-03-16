"""
Evaluation API Endpoints

Provides endpoints for:
- Running RAGAS evaluations
- Viewing evaluation results and trends
- Submitting user feedback
- Managing evaluation configuration
"""
from fastapi import APIRouter, HTTPException, BackgroundTasks
from pydantic import BaseModel, Field
from typing import Optional, List
from datetime import datetime

from app.services.ragas_evaluator import get_ragas_evaluator
from app.services.rag_eval_logger import get_rag_eval_logger

router = APIRouter(prefix="/evaluation", tags=["evaluation"])


# Request/Response Models
class RunEvaluationRequest(BaseModel):
    """Request to run a RAGAS evaluation."""
    max_samples: int = Field(default=100, ge=1, le=500, description="Maximum samples to evaluate")
    sample_percentage_override: Optional[float] = Field(
        default=None, ge=1, le=100,
        description="Override the configured sample percentage"
    )


class EvaluationResultResponse(BaseModel):
    """Individual evaluation result."""
    interaction_id: str
    faithfulness: Optional[float]
    context_precision: Optional[float]
    context_recall: Optional[float]
    answer_relevancy: Optional[float]
    error: Optional[str] = None


class RunEvaluationResponse(BaseModel):
    """Response from running an evaluation."""
    run_id: str
    status: str
    total_evaluated: int
    total_sampled: int
    avg_faithfulness: float
    avg_context_precision: float
    avg_context_recall: float
    avg_answer_relevancy: float
    duration_seconds: float
    started_at: datetime
    completed_at: datetime


class EvaluationHistoryItem(BaseModel):
    """Historical evaluation run."""
    run_id: str
    created_at: datetime
    sample_percentage: float
    total_evaluated: int
    avg_faithfulness: float
    avg_context_precision: float
    avg_context_recall: float
    avg_answer_relevancy: float
    llm_judge_model: str


class QueryEvaluationResult(BaseModel):
    """Individual query evaluation result."""
    interaction_id: str
    query: str
    answer: Optional[str] = None
    search_type: Optional[str] = None
    faithfulness: Optional[float] = None
    context_precision: Optional[float] = None
    context_recall: Optional[float] = None
    answer_relevancy: Optional[float] = None
    created_at: Optional[datetime] = None


class RunDetailsResponse(BaseModel):
    """Detailed evaluation run with per-query results."""
    run_id: str
    run_name: Optional[str] = None
    created_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    sample_size: int
    sample_percentage: float
    llm_judge_model: str
    avg_faithfulness: float
    avg_context_precision: float
    avg_context_recall: float
    avg_answer_relevancy: float
    overall_score: float
    duration_seconds: Optional[int] = None
    status: Optional[str] = None
    individual_results: List[QueryEvaluationResult]


class EvaluationStatsResponse(BaseModel):
    """Statistics about evaluation data."""
    total_queries: int
    evaluated_queries: int
    unevaluated_queries: int
    with_feedback: int
    evaluation_coverage: float


class UpdateConfigRequest(BaseModel):
    """Request to update evaluation configuration."""
    sample_percentage: Optional[float] = Field(
        default=None, ge=1, le=100,
        description="Percentage of queries to sample for evaluation"
    )
    llm_judge_model: Optional[str] = Field(
        default=None,
        description="Groq model to use as LLM judge"
    )
    enabled_metrics: Optional[List[str]] = Field(
        default=None,
        description="List of metrics to compute"
    )
    min_queries_for_eval: Optional[int] = Field(
        default=None, ge=1,
        description="Minimum number of unevaluated queries required to run evaluation"
    )


class ConfigResponse(BaseModel):
    """Current evaluation configuration."""
    sample_percentage: float
    llm_judge_model: str
    enabled_metrics: List[str]
    min_queries_for_eval: int = 10


class UserFeedbackRequest(BaseModel):
    """Request to submit user feedback."""
    feedback: str = Field(
        ..., 
        pattern="^(positive|negative|neutral)$",
        description="User feedback: positive, negative, or neutral"
    )


class UserFeedbackResponse(BaseModel):
    """Response from submitting feedback."""
    success: bool
    interaction_id: str
    feedback: str


# Background task for running evaluation
async def run_evaluation_background(
    max_samples: int,
    sample_percentage_override: Optional[float]
):
    """Run evaluation in background."""
    evaluator = get_ragas_evaluator()
    await evaluator.run_evaluation(
        max_samples=max_samples,
        sample_percentage_override=sample_percentage_override
    )


@router.post("/run", response_model=RunEvaluationResponse)
async def run_evaluation(request: RunEvaluationRequest):
    """
    Run a RAGAS evaluation on sampled unevaluated queries.
    
    This endpoint runs synchronously and returns when evaluation completes.
    For large datasets, consider using /run-async instead.
    """
    evaluator = get_ragas_evaluator()
    
    try:
        result = await evaluator.run_evaluation(
            max_samples=request.max_samples,
            sample_percentage_override=request.sample_percentage_override
        )
        
        return RunEvaluationResponse(
            run_id=result.run_id,
            status="completed",
            total_evaluated=result.total_evaluated,
            total_sampled=result.total_sampled,
            avg_faithfulness=result.avg_faithfulness,
            avg_context_precision=result.avg_context_precision,
            avg_context_recall=result.avg_context_recall,
            avg_answer_relevancy=result.avg_answer_relevancy,
            duration_seconds=result.duration_seconds,
            started_at=result.started_at,
            completed_at=result.completed_at
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/run-async")
async def run_evaluation_async(
    request: RunEvaluationRequest,
    background_tasks: BackgroundTasks
):
    """
    Start a RAGAS evaluation in the background.
    
    Returns immediately with a run ID. Check /history for results.
    """
    from uuid import uuid4
    run_id = str(uuid4())
    
    background_tasks.add_task(
        run_evaluation_background,
        request.max_samples,
        request.sample_percentage_override
    )
    
    return {
        "status": "started",
        "message": "Evaluation started in background. Check /history for results.",
        "estimated_run_id": run_id
    }


@router.get("/history", response_model=List[EvaluationHistoryItem])
async def get_evaluation_history(limit: int = 10):
    """
    Get recent evaluation runs.
    
    Returns the most recent evaluation runs with their aggregate metrics.
    """
    evaluator = get_ragas_evaluator()
    
    try:
        history = await evaluator.get_evaluation_history(limit=limit)
        
        return [
            EvaluationHistoryItem(
                run_id=str(item.get("id", "")),  # Use id column as run_id
                created_at=item["created_at"],
                sample_percentage=float(item.get("sample_percentage", 0)),
                total_evaluated=int(item.get("sample_size", 0)),  # Map sample_size to total_evaluated
                avg_faithfulness=float(item.get("faithfulness_score", 0) or 0),
                avg_context_precision=float(item.get("context_precision_score", 0) or 0),
                avg_context_recall=float(item.get("context_recall_score", 0) or 0),
                avg_answer_relevancy=float(item.get("answer_relevancy_score", 0) or 0),
                llm_judge_model=str(item.get("llm_judge", ""))
            )
            for item in history
        ]
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/history/{run_id}", response_model=RunDetailsResponse)
async def get_run_details(run_id: str):
    """
    Get detailed results for a specific evaluation run.
    
    Returns the run summary and individual per-query evaluation scores.
    """
    evaluator = get_ragas_evaluator()
    
    try:
        details = await evaluator.get_run_details(run_id=run_id)
        
        if details is None:
            raise HTTPException(status_code=404, detail="Evaluation run not found")
        
        return RunDetailsResponse(
            run_id=details["run_id"],
            run_name=details.get("run_name"),
            created_at=details.get("created_at"),
            completed_at=details.get("completed_at"),
            sample_size=int(details.get("sample_size", 0) or 0),
            sample_percentage=float(details.get("sample_percentage", 0) or 0),
            llm_judge_model=str(details.get("llm_judge_model", "")),
            avg_faithfulness=float(details.get("avg_faithfulness", 0) or 0),
            avg_context_precision=float(details.get("avg_context_precision", 0) or 0),
            avg_context_recall=float(details.get("avg_context_recall", 0) or 0),
            avg_answer_relevancy=float(details.get("avg_answer_relevancy", 0) or 0),
            overall_score=float(details.get("overall_score", 0) or 0),
            duration_seconds=details.get("duration_seconds"),
            status=details.get("status"),
            individual_results=[
                QueryEvaluationResult(
                    interaction_id=str(r.get("interaction_id", "")),
                    query=str(r.get("query", "")),
                    answer=r.get("answer"),
                    search_type=r.get("search_type"),
                    faithfulness=r.get("faithfulness"),
                    context_precision=r.get("context_precision"),
                    context_recall=r.get("context_recall"),
                    answer_relevancy=r.get("answer_relevancy"),
                    created_at=r.get("created_at")
                )
                for r in details.get("individual_results", [])
            ]
        )
        
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/trends")
async def get_evaluation_trends(days: int = 30):
    """
    Get evaluation metric trends over time.
    
    Returns trend direction (improving, stable, declining) and historical data.
    """
    evaluator = get_ragas_evaluator()
    
    try:
        trends = await evaluator.get_evaluation_trends(days=days)
        return trends
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/stats", response_model=EvaluationStatsResponse)
async def get_evaluation_stats():
    """
    Get statistics about evaluation data.
    
    Returns counts of total, evaluated, and unevaluated queries.
    """
    eval_logger = get_rag_eval_logger()
    
    try:
        stats = await eval_logger.get_evaluation_stats()
        
        total = stats.get("total", 0)
        evaluated = stats.get("evaluated", 0)
        
        return EvaluationStatsResponse(
            total_queries=total,
            evaluated_queries=evaluated,
            unevaluated_queries=stats.get("unevaluated", 0),
            with_feedback=stats.get("with_feedback", 0),
            evaluation_coverage=evaluated / total if total > 0 else 0.0
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/config", response_model=ConfigResponse)
async def get_config():
    """
    Get current evaluation configuration.
    """
    evaluator = get_ragas_evaluator()
    
    try:
        config = await evaluator.get_config()
        
        return ConfigResponse(
            sample_percentage=config["sample_percentage"],
            llm_judge_model=config["llm_judge_model"],
            enabled_metrics=config["enabled_metrics"],
            min_queries_for_eval=config.get("min_queries_for_eval", 10)
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/config", response_model=ConfigResponse)
async def update_config(request: UpdateConfigRequest):
    """
    Update evaluation configuration.
    
    Allows changing sample percentage, LLM model, enabled metrics, and min queries.
    """
    evaluator = get_ragas_evaluator()
    
    try:
        success = await evaluator.update_config(
            sample_percentage=request.sample_percentage,
            llm_judge_model=request.llm_judge_model,
            enabled_metrics=request.enabled_metrics,
            min_queries_for_eval=request.min_queries_for_eval
        )
        
        if not success:
            raise HTTPException(status_code=500, detail="Failed to update configuration")
        
        # Return updated config
        config = await evaluator.get_config()
        
        return ConfigResponse(
            sample_percentage=config["sample_percentage"],
            llm_judge_model=config["llm_judge_model"],
            enabled_metrics=config["enabled_metrics"],
            min_queries_for_eval=config.get("min_queries_for_eval", 10)
        )
        
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/feedback/{interaction_id}", response_model=UserFeedbackResponse)
async def submit_feedback(interaction_id: str, request: UserFeedbackRequest):
    """
    Submit user feedback for a RAG interaction.
    
    Feedback provides ground truth for evaluating RAG quality.
    Valid values: positive, negative, neutral
    """
    eval_logger = get_rag_eval_logger()
    
    try:
        from uuid import UUID
        interaction_uuid = UUID(interaction_id)
        
        success = await eval_logger.log_user_feedback(
            interaction_id=interaction_uuid,
            feedback=request.feedback
        )
        
        if not success:
            raise HTTPException(status_code=404, detail="Interaction not found")
        
        return UserFeedbackResponse(
            success=True,
            interaction_id=interaction_id,
            feedback=request.feedback
        )
        
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid interaction ID format")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
