-- =============================================================================
-- LOGGING TABLES FOR NOTESAPP
-- Run this SQL in your Supabase SQL Editor to create the logging tables
-- =============================================================================

-- -----------------------------------------------------------------------------
-- USER ACTIVITIES TABLE
-- Tracks user actions like uploads, searches, deletions
-- Queryable for last 30 days, then archived to blob storage
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_activities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    correlation_id UUID NOT NULL,
    user_id TEXT NOT NULL,
    action TEXT NOT NULL,
    resource_type TEXT,
    resource_id UUID,
    status TEXT NOT NULL CHECK (status IN ('success', 'error', 'pending')),
    duration_ms INTEGER,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_ua_user_time ON user_activities(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ua_action ON user_activities(action, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ua_correlation ON user_activities(correlation_id);
CREATE INDEX IF NOT EXISTS idx_ua_created ON user_activities(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ua_status ON user_activities(status) WHERE status = 'error';

-- Enable Row Level Security (optional - enable if you want user isolation)
-- ALTER TABLE user_activities ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE user_activities IS 'User activity logs - retained for 30 days then archived to blob storage';
COMMENT ON COLUMN user_activities.correlation_id IS 'Request correlation ID for tracing';
COMMENT ON COLUMN user_activities.action IS 'Action type: upload_file, search_notes, delete_note, etc.';
COMMENT ON COLUMN user_activities.resource_type IS 'Resource type: note, file, screenshot, quick_note';
COMMENT ON COLUMN user_activities.metadata IS 'Additional context as JSON';


-- -----------------------------------------------------------------------------
-- OPERATION LOGS TABLE
-- Tracks internal service operations for debugging
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS operation_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    correlation_id UUID NOT NULL,
    service TEXT NOT NULL,
    operation TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('success', 'error', 'timeout')),
    duration_ms INTEGER,
    input_summary JSONB DEFAULT '{}',
    output_summary JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_ol_correlation ON operation_logs(correlation_id);
CREATE INDEX IF NOT EXISTS idx_ol_service ON operation_logs(service, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ol_created ON operation_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ol_status ON operation_logs(status) WHERE status = 'error';

COMMENT ON TABLE operation_logs IS 'Internal service operation logs for debugging';
COMMENT ON COLUMN operation_logs.service IS 'Service name: tensorlake, embeddings, blob_storage, notes_db';
COMMENT ON COLUMN operation_logs.operation IS 'Operation name: convert_to_markdown, generate_embeddings, etc.';


-- -----------------------------------------------------------------------------
-- ERROR LOGS TABLE
-- Captures all errors with full context and stack traces
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS error_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    correlation_id UUID,
    user_id TEXT,
    error_code TEXT NOT NULL,
    error_type TEXT NOT NULL,
    message TEXT NOT NULL,
    stack_trace TEXT,
    context JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_el_correlation ON error_logs(correlation_id);
CREATE INDEX IF NOT EXISTS idx_el_error_type ON error_logs(error_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_el_error_code ON error_logs(error_code, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_el_created ON error_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_el_user ON error_logs(user_id, created_at DESC);

COMMENT ON TABLE error_logs IS 'Error logs with full context and stack traces';
COMMENT ON COLUMN error_logs.error_code IS 'Application error code like ERR_2001';
COMMENT ON COLUMN error_logs.error_type IS 'Exception class name';
COMMENT ON COLUMN error_logs.stack_trace IS 'Full Python stack trace';


-- -----------------------------------------------------------------------------
-- API METRICS (HOURLY AGGREGATES)
-- Pre-aggregated metrics for dashboard performance
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS api_metrics_hourly (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hour TIMESTAMPTZ NOT NULL,
    endpoint TEXT NOT NULL,
    method TEXT NOT NULL,
    total_requests INTEGER DEFAULT 0,
    success_count INTEGER DEFAULT 0,
    error_count INTEGER DEFAULT 0,
    total_duration_ms BIGINT DEFAULT 0,
    min_duration_ms INTEGER,
    max_duration_ms INTEGER,
    p50_duration_ms INTEGER,
    p95_duration_ms INTEGER,
    p99_duration_ms INTEGER,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(hour, endpoint, method)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_amh_hour ON api_metrics_hourly(hour DESC);
CREATE INDEX IF NOT EXISTS idx_amh_endpoint ON api_metrics_hourly(endpoint, hour DESC);

COMMENT ON TABLE api_metrics_hourly IS 'Hourly aggregated API metrics for dashboard';


-- -----------------------------------------------------------------------------
-- ARCHIVAL STATUS TABLE
-- Tracks log archival jobs for reliability
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS archival_status (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id UUID NOT NULL,
    target_date DATE NOT NULL,
    table_name TEXT NOT NULL,
    records_archived INTEGER DEFAULT 0,
    records_deleted INTEGER DEFAULT 0,
    blob_path TEXT,
    status TEXT NOT NULL CHECK (status IN ('in_progress', 'completed', 'failed')),
    error_message TEXT,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_as_job ON archival_status(job_id);
CREATE INDEX IF NOT EXISTS idx_as_date ON archival_status(target_date DESC);
CREATE INDEX IF NOT EXISTS idx_as_status ON archival_status(status);

COMMENT ON TABLE archival_status IS 'Tracks log archival job status';


-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Function to get activity count by action for a time period
CREATE OR REPLACE FUNCTION get_activity_counts(
    p_user_id TEXT DEFAULT NULL,
    p_start_time TIMESTAMPTZ DEFAULT NOW() - INTERVAL '24 hours',
    p_end_time TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    action TEXT,
    total_count BIGINT,
    success_count BIGINT,
    error_count BIGINT
)
LANGUAGE SQL
AS $$
    SELECT 
        action,
        COUNT(*) as total_count,
        COUNT(*) FILTER (WHERE status = 'success') as success_count,
        COUNT(*) FILTER (WHERE status = 'error') as error_count
    FROM user_activities
    WHERE created_at BETWEEN p_start_time AND p_end_time
      AND (p_user_id IS NULL OR user_id = p_user_id)
    GROUP BY action
    ORDER BY total_count DESC;
$$;


-- Function to get error summary for a time period
CREATE OR REPLACE FUNCTION get_error_summary(
    p_start_time TIMESTAMPTZ DEFAULT NOW() - INTERVAL '24 hours',
    p_end_time TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    error_type TEXT,
    error_code TEXT,
    count BIGINT,
    latest_message TEXT,
    latest_at TIMESTAMPTZ
)
LANGUAGE SQL
AS $$
    SELECT 
        error_type,
        error_code,
        COUNT(*) as count,
        (ARRAY_AGG(message ORDER BY created_at DESC))[1] as latest_message,
        MAX(created_at) as latest_at
    FROM error_logs
    WHERE created_at BETWEEN p_start_time AND p_end_time
    GROUP BY error_type, error_code
    ORDER BY count DESC;
$$;


-- Function to get operation performance stats
CREATE OR REPLACE FUNCTION get_operation_stats(
    p_service TEXT DEFAULT NULL,
    p_start_time TIMESTAMPTZ DEFAULT NOW() - INTERVAL '24 hours',
    p_end_time TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    service TEXT,
    operation TEXT,
    total_count BIGINT,
    success_count BIGINT,
    error_count BIGINT,
    avg_duration_ms NUMERIC,
    max_duration_ms INTEGER
)
LANGUAGE SQL
AS $$
    SELECT 
        service,
        operation,
        COUNT(*) as total_count,
        COUNT(*) FILTER (WHERE status = 'success') as success_count,
        COUNT(*) FILTER (WHERE status = 'error') as error_count,
        ROUND(AVG(duration_ms), 2) as avg_duration_ms,
        MAX(duration_ms) as max_duration_ms
    FROM operation_logs
    WHERE created_at BETWEEN p_start_time AND p_end_time
      AND (p_service IS NULL OR service = p_service)
    GROUP BY service, operation
    ORDER BY total_count DESC;
$$;


-- Function to get full trace by correlation_id
CREATE OR REPLACE FUNCTION get_request_trace(p_correlation_id UUID)
RETURNS TABLE (
    log_type TEXT,
    log_timestamp TIMESTAMPTZ,
    details JSONB
)
LANGUAGE SQL
AS $$
    SELECT 
        'activity' as log_type,
        created_at as log_timestamp,
        jsonb_build_object(
            'id', id,
            'user_id', user_id,
            'action', action,
            'resource_type', resource_type,
            'status', status,
            'duration_ms', duration_ms,
            'metadata', metadata
        ) as details
    FROM user_activities
    WHERE correlation_id = p_correlation_id
    
    UNION ALL
    
    SELECT 
        'operation' as log_type,
        created_at as log_timestamp,
        jsonb_build_object(
            'id', id,
            'service', service,
            'operation', operation,
            'status', status,
            'duration_ms', duration_ms,
            'input_summary', input_summary,
            'output_summary', output_summary
        ) as details
    FROM operation_logs
    WHERE correlation_id = p_correlation_id
    
    UNION ALL
    
    SELECT 
        'error' as log_type,
        created_at as log_timestamp,
        jsonb_build_object(
            'id', id,
            'error_code', error_code,
            'error_type', error_type,
            'message', message,
            'context', context
        ) as details
    FROM error_logs
    WHERE correlation_id = p_correlation_id
    
    ORDER BY log_timestamp ASC;
$$;


-- =============================================================================
-- GRANTS (adjust as needed for your setup)
-- =============================================================================
-- GRANT SELECT, INSERT ON user_activities TO authenticated;
-- GRANT SELECT, INSERT ON operation_logs TO service_role;
-- GRANT SELECT, INSERT ON error_logs TO service_role;
-- GRANT SELECT, INSERT, UPDATE ON api_metrics_hourly TO service_role;
-- GRANT SELECT, INSERT, UPDATE ON archival_status TO service_role;
