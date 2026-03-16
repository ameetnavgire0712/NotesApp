-- Migration: Add individual evaluation score columns to rag_evaluation_logs
-- Purpose: Store per-query RAGAS scores for detailed analysis
-- Date: 2026-01-21

-- =============================================================================
-- Add individual score columns to rag_evaluation_logs
-- These will store the RAGAS scores for each individual query
-- =============================================================================

-- Evaluation run reference (renamed from evaluation_id for clarity)
ALTER TABLE rag_evaluation_logs 
    ADD COLUMN IF NOT EXISTS evaluation_run_id UUID REFERENCES rag_evaluation_results(id);

-- Individual RAGAS metric scores
ALTER TABLE rag_evaluation_logs 
    ADD COLUMN IF NOT EXISTS faithfulness_score NUMERIC(5,4);

ALTER TABLE rag_evaluation_logs 
    ADD COLUMN IF NOT EXISTS context_precision_score NUMERIC(5,4);

ALTER TABLE rag_evaluation_logs 
    ADD COLUMN IF NOT EXISTS context_recall_score NUMERIC(5,4);

ALTER TABLE rag_evaluation_logs 
    ADD COLUMN IF NOT EXISTS answer_relevancy_score NUMERIC(5,4);

-- Index for fetching queries by evaluation run
CREATE INDEX IF NOT EXISTS idx_rag_eval_logs_run_id 
    ON rag_evaluation_logs (evaluation_run_id) 
    WHERE evaluation_run_id IS NOT NULL;

-- Comment the columns
COMMENT ON COLUMN rag_evaluation_logs.evaluation_run_id IS 'References the evaluation run that scored this query';
COMMENT ON COLUMN rag_evaluation_logs.faithfulness_score IS 'RAGAS faithfulness score (0-1): Is the answer grounded in context?';
COMMENT ON COLUMN rag_evaluation_logs.context_precision_score IS 'RAGAS context precision score (0-1): Are contexts ranked by relevance?';
COMMENT ON COLUMN rag_evaluation_logs.context_recall_score IS 'RAGAS context recall score (0-1): Does context contain needed info?';
COMMENT ON COLUMN rag_evaluation_logs.answer_relevancy_score IS 'RAGAS answer relevancy score (0-1): Is the answer relevant to the question?';

-- =============================================================================
-- Add reasoning columns to explain WHY each score was given
-- These help debug low scores by showing LLM's analysis
-- =============================================================================

ALTER TABLE rag_evaluation_logs 
    ADD COLUMN IF NOT EXISTS faithfulness_reason TEXT;

ALTER TABLE rag_evaluation_logs 
    ADD COLUMN IF NOT EXISTS context_precision_reason TEXT;

ALTER TABLE rag_evaluation_logs 
    ADD COLUMN IF NOT EXISTS context_recall_reason TEXT;

ALTER TABLE rag_evaluation_logs 
    ADD COLUMN IF NOT EXISTS answer_relevancy_reason TEXT;

-- Comments for reasoning columns
COMMENT ON COLUMN rag_evaluation_logs.faithfulness_reason IS 'Explanation of faithfulness score - which claims were/were not grounded';
COMMENT ON COLUMN rag_evaluation_logs.context_precision_reason IS 'Explanation of context precision - how well contexts were ranked';
COMMENT ON COLUMN rag_evaluation_logs.context_recall_reason IS 'Explanation of context recall - what info was missing from context';
COMMENT ON COLUMN rag_evaluation_logs.answer_relevancy_reason IS 'Explanation of answer relevancy - how well answer addressed the question';
