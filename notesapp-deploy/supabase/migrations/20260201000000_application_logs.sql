-- =============================================================================
-- Supabase Migration: Application Logs Table
-- 
-- Creates a table for centralized logging from distributed Fly.io services.
-- Schema matches the existing notesapp.log format exactly.
-- 
-- Run with: supabase db push
-- =============================================================================

-- Create the application_logs table
CREATE TABLE IF NOT EXISTS public.application_logs (
    id BIGSERIAL PRIMARY KEY,
    
    -- Core log fields (matches notesapp.log format)
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    level VARCHAR(10) NOT NULL,
    correlation_id VARCHAR(50),
    user_id UUID,
    logger_name VARCHAR(255) NOT NULL,
    filename VARCHAR(255) NOT NULL,
    line_number INTEGER NOT NULL,
    function_name VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    
    -- Distributed system metadata
    machine_id VARCHAR(50) NOT NULL,
    region VARCHAR(10) NOT NULL,
    service VARCHAR(50) NOT NULL,
    
    -- Timestamps for partitioning/cleanup
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON public.application_logs (timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_logs_user_id ON public.application_logs (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_logs_correlation_id ON public.application_logs (correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_logs_level ON public.application_logs (level);
CREATE INDEX IF NOT EXISTS idx_logs_service ON public.application_logs (service);
CREATE INDEX IF NOT EXISTS idx_logs_machine_region ON public.application_logs (machine_id, region);

-- Composite index for dashboard queries
CREATE INDEX IF NOT EXISTS idx_logs_service_level_time 
    ON public.application_logs (service, level, timestamp DESC);

-- =============================================================================
-- Row Level Security
-- =============================================================================

ALTER TABLE public.application_logs ENABLE ROW LEVEL SECURITY;

-- Service role can insert logs (from Fly.io services)
CREATE POLICY "Service role can insert logs"
    ON public.application_logs
    FOR INSERT
    TO service_role
    WITH CHECK (true);

-- Service role can read all logs
CREATE POLICY "Service role can read logs"
    ON public.application_logs
    FOR SELECT
    TO service_role
    USING (true);

-- Authenticated users can read their own logs
CREATE POLICY "Users can read their own logs"
    ON public.application_logs
    FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

-- =============================================================================
-- Cleanup Function (for scheduled job)
-- =============================================================================

-- Function to delete logs older than retention period
CREATE OR REPLACE FUNCTION public.cleanup_old_logs(retention_days INTEGER DEFAULT 30)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    WITH deleted AS (
        DELETE FROM public.application_logs
        WHERE timestamp < NOW() - (retention_days || ' days')::INTERVAL
        RETURNING *
    )
    SELECT COUNT(*) INTO deleted_count FROM deleted;
    
    RETURN deleted_count;
END;
$$;

-- Grant execute to service role
GRANT EXECUTE ON FUNCTION public.cleanup_old_logs TO service_role;

-- =============================================================================
-- Comments for documentation
-- =============================================================================

COMMENT ON TABLE public.application_logs IS 'Centralized application logs from distributed Fly.io services';
COMMENT ON COLUMN public.application_logs.timestamp IS 'When the log event occurred';
COMMENT ON COLUMN public.application_logs.level IS 'Log level: DEBUG, INFO, WARNING, ERROR, CRITICAL';
COMMENT ON COLUMN public.application_logs.correlation_id IS 'Request correlation ID for tracing';
COMMENT ON COLUMN public.application_logs.user_id IS 'User ID if authenticated request';
COMMENT ON COLUMN public.application_logs.logger_name IS 'Python logger name (e.g., app.services.notes_db)';
COMMENT ON COLUMN public.application_logs.machine_id IS 'Fly.io machine ID (FLY_MACHINE_ID)';
COMMENT ON COLUMN public.application_logs.region IS 'Fly.io region (FLY_REGION)';
COMMENT ON COLUMN public.application_logs.service IS 'Service name: search, upload, etc.';
