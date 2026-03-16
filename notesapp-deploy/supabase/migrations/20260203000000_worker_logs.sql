-- =============================================================================
-- Supabase Migration: Worker Logs Table
-- 
-- Creates a table for storing Cloudflare Worker logs permanently.
-- This replaces the ephemeral file-based storage on Fly.io machines.
-- 
-- Run with: supabase db push
-- =============================================================================

-- Create the worker_logs table
CREATE TABLE IF NOT EXISTS public.worker_logs (
    id BIGSERIAL PRIMARY KEY,
    
    -- Request identification
    request_id VARCHAR(50) NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    
    -- Request details
    endpoint VARCHAR(50) NOT NULL,
    method VARCHAR(10) NOT NULL,
    user_id UUID,
    query TEXT,
    
    -- Timing breakdown (milliseconds)
    timing_total_ms INTEGER,
    timing_embedding_ms INTEGER,
    timing_vectorize_ms INTEGER,
    timing_rerank_ms INTEGER,
    timing_parse_ms INTEGER,
    timing_transform_ms INTEGER,
    
    -- Result info
    result_match_count INTEGER,
    result_rerank_count INTEGER,
    
    -- Error tracking
    error TEXT,
    
    -- Metadata
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_worker_logs_timestamp ON public.worker_logs (timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_worker_logs_request_id ON public.worker_logs (request_id);
CREATE INDEX IF NOT EXISTS idx_worker_logs_user_id ON public.worker_logs (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_worker_logs_endpoint ON public.worker_logs (endpoint);
CREATE INDEX IF NOT EXISTS idx_worker_logs_error ON public.worker_logs (id) WHERE error IS NOT NULL;

-- Composite index for performance analysis
CREATE INDEX IF NOT EXISTS idx_worker_logs_timing 
    ON public.worker_logs (endpoint, timing_total_ms DESC, timestamp DESC);

-- =============================================================================
-- Row Level Security
-- =============================================================================

ALTER TABLE public.worker_logs ENABLE ROW LEVEL SECURITY;

-- Policy: Service role can do everything (for backend writes)
CREATE POLICY "Service role full access to worker_logs"
    ON public.worker_logs
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- Policy: Authenticated users can read their own logs
CREATE POLICY "Users can read their own worker_logs"
    ON public.worker_logs
    FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

-- =============================================================================
-- Cleanup function for old logs (optional - keeps last 7 days)
-- =============================================================================

CREATE OR REPLACE FUNCTION cleanup_old_worker_logs()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM public.worker_logs
    WHERE timestamp < NOW() - INTERVAL '7 days';
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute to service role
GRANT EXECUTE ON FUNCTION cleanup_old_worker_logs() TO service_role;

-- =============================================================================
-- Comments
-- =============================================================================

COMMENT ON TABLE public.worker_logs IS 'Stores timing and performance logs from Cloudflare Worker requests';
COMMENT ON COLUMN public.worker_logs.timing_total_ms IS 'Total request time in milliseconds';
COMMENT ON COLUMN public.worker_logs.timing_vectorize_ms IS 'Time spent querying Vectorize index';
COMMENT ON COLUMN public.worker_logs.timing_embedding_ms IS 'Time spent generating embeddings';
COMMENT ON COLUMN public.worker_logs.timing_rerank_ms IS 'Time spent on Voyage reranking';
