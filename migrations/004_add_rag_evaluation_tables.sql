-- Migration: Add RAG Evaluation Tables
-- Purpose: Store query-context-answer triplets for RAGAS evaluation
-- Date: 2026-01-21

-- =============================================================================
-- RAG INTERACTION LOGS (for evaluation)
-- Stores the complete data needed for RAGAS metrics
-- =============================================================================

CREATE TABLE IF NOT EXISTS rag_evaluation_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT NOT NULL,
    query TEXT NOT NULL,
    retrieved_contexts JSONB NOT NULL DEFAULT '[]',  -- Array of {note_id, content, similarity_score}
    answer TEXT,  -- Generated answer (if synthesis was requested)
    note_ids TEXT[] NOT NULL DEFAULT '{}',  -- Array of returned note IDs
    
    -- Metadata for analysis
    search_type TEXT,  -- 'hybrid', 'vector', 'tag', etc.
    total_results INTEGER DEFAULT 0,
    search_duration_ms INTEGER,
    llm_duration_ms INTEGER,
    
    -- User feedback (for ground truth)
    user_feedback TEXT CHECK (user_feedback IN ('positive', 'negative', 'neutral', NULL)),
    feedback_timestamp TIMESTAMPTZ,
    
    -- Evaluation status
    evaluated BOOLEAN DEFAULT FALSE,
    evaluation_id UUID,  -- Links to rag_evaluation_results
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Indexes for efficient querying
    CONSTRAINT valid_contexts CHECK (jsonb_typeof(retrieved_contexts) = 'array')
);

-- Index for sampling unevaluated logs
CREATE INDEX IF NOT EXISTS idx_rag_eval_logs_unevaluated 
    ON rag_evaluation_logs (evaluated, created_at DESC) 
    WHERE evaluated = FALSE;

-- Index for user queries
CREATE INDEX IF NOT EXISTS idx_rag_eval_logs_user 
    ON rag_evaluation_logs (user_id, created_at DESC);


-- =============================================================================
-- RAG EVALUATION RESULTS
-- Stores RAGAS metric scores for each evaluation run
-- =============================================================================

CREATE TABLE IF NOT EXISTS rag_evaluation_results (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Evaluation run metadata
    run_name TEXT,
    sample_size INTEGER NOT NULL,
    sample_percentage NUMERIC(5,2) NOT NULL,
    llm_judge TEXT NOT NULL,  -- e.g., 'groq/llama-3.3-70b'
    
    -- RAGAS Metrics (averaged across samples)
    faithfulness_score NUMERIC(5,4),  -- 0.0 to 1.0
    context_precision_score NUMERIC(5,4),
    context_recall_score NUMERIC(5,4),
    answer_relevancy_score NUMERIC(5,4),
    
    -- Additional metrics
    overall_score NUMERIC(5,4),  -- Weighted average
    
    -- Detailed per-query results
    detailed_results JSONB NOT NULL DEFAULT '[]',  -- Array of per-query scores
    
    -- Execution info
    started_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    duration_seconds INTEGER,
    status TEXT DEFAULT 'running' CHECK (status IN ('running', 'completed', 'failed')),
    error_message TEXT,
    
    -- Cost tracking
    total_tokens_used INTEGER,
    estimated_cost_usd NUMERIC(10,6),
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for latest results
CREATE INDEX IF NOT EXISTS idx_rag_eval_results_created 
    ON rag_evaluation_results (created_at DESC);

-- Index for status filtering
CREATE INDEX IF NOT EXISTS idx_rag_eval_results_status 
    ON rag_evaluation_results (status, created_at DESC);


-- =============================================================================
-- EVALUATION CONFIGURATION
-- Stores evaluation settings (sample %, frequency, etc.)
-- =============================================================================

CREATE TABLE IF NOT EXISTS rag_evaluation_config (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_key TEXT UNIQUE NOT NULL,
    config_value JSONB NOT NULL,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Insert default configuration
INSERT INTO rag_evaluation_config (config_key, config_value, description) VALUES
    ('sample_percentage', '50', 'Percentage of queries to sample for evaluation (1-100)'),
    ('min_queries_for_eval', '10', 'Minimum number of queries required before running evaluation'),
    ('llm_judge', '"groq/llama-3.3-70b-versatile"', 'LLM model to use for RAGAS evaluation'),
    ('enabled_metrics', '["faithfulness", "context_precision", "context_recall", "answer_relevancy"]', 'RAGAS metrics to compute')
ON CONFLICT (config_key) DO NOTHING;


-- =============================================================================
-- HELPER FUNCTION: Get evaluation config
-- =============================================================================

CREATE OR REPLACE FUNCTION get_eval_config(key_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT config_value INTO result
    FROM rag_evaluation_config
    WHERE config_key = key_name;
    
    RETURN result;
END;
$$;


-- =============================================================================
-- HELPER FUNCTION: Sample unevaluated queries
-- =============================================================================

CREATE OR REPLACE FUNCTION sample_unevaluated_queries(
    sample_pct NUMERIC DEFAULT 50,
    max_samples INTEGER DEFAULT 100
)
RETURNS TABLE (
    id UUID,
    user_id TEXT,
    query TEXT,
    retrieved_contexts JSONB,
    answer TEXT,
    note_ids TEXT[],
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        rel.id,
        rel.user_id,
        rel.query,
        rel.retrieved_contexts,
        rel.answer,
        rel.note_ids,
        rel.created_at
    FROM rag_evaluation_logs rel
    WHERE rel.evaluated = FALSE
    AND random() < (sample_pct / 100.0)
    ORDER BY rel.created_at DESC
    LIMIT max_samples;
END;
$$;


-- =============================================================================
-- HELPER FUNCTION: Mark queries as evaluated
-- =============================================================================

CREATE OR REPLACE FUNCTION mark_queries_evaluated(
    query_ids UUID[],
    eval_result_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    updated_count INTEGER;
BEGIN
    UPDATE rag_evaluation_logs
    SET 
        evaluated = TRUE,
        evaluation_id = eval_result_id
    WHERE id = ANY(query_ids);
    
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN updated_count;
END;
$$;


-- Grant permissions
GRANT SELECT, INSERT, UPDATE ON rag_evaluation_logs TO authenticated;
GRANT SELECT, INSERT, UPDATE ON rag_evaluation_results TO authenticated;
GRANT SELECT, UPDATE ON rag_evaluation_config TO authenticated;
GRANT EXECUTE ON FUNCTION get_eval_config TO authenticated;
GRANT EXECUTE ON FUNCTION sample_unevaluated_queries TO authenticated;
GRANT EXECUTE ON FUNCTION mark_queries_evaluated TO authenticated;
