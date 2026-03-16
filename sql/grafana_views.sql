-- =============================================================================
-- GRAFANA VIEWS FOR NOTESAPP LOGS
-- =============================================================================
-- These views optimize queries for Grafana dashboards.
-- Execute this in your Supabase SQL Editor.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. USER JOURNEY VIEW
-- Timeline of all user actions for session analysis
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_user_journey AS
SELECT 
    ua.id,
    ua.user_id,
    ua.action,
    ua.resource_type,
    ua.resource_id::text as resource_id,
    ua.status,
    ua.duration_ms,
    ua.correlation_id,
    ua.created_at,
    -- Extract key metadata fields
    ua.metadata->>'error' as error_message,
    ua.metadata->>'query_length' as query_length,
    ua.metadata->>'source_count' as source_count,
    ua.metadata->>'chunks' as chunks_created,
    ua.metadata->>'filename' as filename,
    -- Session grouping (activities within 30 min are same session)
    DATE_TRUNC('hour', ua.created_at) as session_hour
FROM user_activities ua
ORDER BY ua.created_at DESC;

COMMENT ON VIEW v_user_journey IS 'User activity timeline for Grafana dashboards';


-- -----------------------------------------------------------------------------
-- 2. API METRICS VIEW
-- Latency and error rates by endpoint/action
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_api_metrics AS
SELECT 
    DATE_TRUNC('hour', created_at) as hour,
    action,
    resource_type,
    status,
    COUNT(*) as request_count,
    AVG(duration_ms) as avg_latency_ms,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY duration_ms) as p50_latency_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms) as p95_latency_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY duration_ms) as p99_latency_ms,
    MAX(duration_ms) as max_latency_ms,
    SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_count,
    ROUND(
        100.0 * SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0),
        2
    ) as error_rate_pct
FROM user_activities
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY DATE_TRUNC('hour', created_at), action, resource_type, status
ORDER BY hour DESC, request_count DESC;

COMMENT ON VIEW v_api_metrics IS 'API performance metrics aggregated by hour for Grafana';


-- -----------------------------------------------------------------------------
-- 3. SEARCH QUALITY VIEW
-- Query success rates and relevance metrics
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_search_quality AS
SELECT 
    DATE_TRUNC('day', created_at) as day,
    action,
    COUNT(*) as total_searches,
    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) as successful_searches,
    SUM(CASE WHEN (metadata->>'source_count')::int > 0 THEN 1 ELSE 0 END) as searches_with_results,
    AVG((metadata->>'source_count')::numeric) as avg_sources_returned,
    AVG((metadata->>'query_length')::numeric) as avg_query_length,
    AVG(duration_ms) as avg_search_time_ms,
    ROUND(
        100.0 * SUM(CASE WHEN (metadata->>'source_count')::int > 0 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0),
        2
    ) as result_rate_pct
FROM user_activities
WHERE action IN ('chat_query', 'vector_search', 'hybrid_search', 'search_notes')
  AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY DATE_TRUNC('day', created_at), action
ORDER BY day DESC;

COMMENT ON VIEW v_search_quality IS 'Search quality metrics for Grafana';


-- -----------------------------------------------------------------------------
-- 4. USER ACTIVITY SUMMARY VIEW
-- Per-user activity aggregates
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_user_activity_summary AS
SELECT 
    user_id,
    DATE_TRUNC('day', created_at) as day,
    COUNT(*) as total_actions,
    COUNT(DISTINCT action) as unique_actions,
    SUM(CASE WHEN action = 'chat_query' THEN 1 ELSE 0 END) as chat_queries,
    SUM(CASE WHEN action LIKE '%search%' THEN 1 ELSE 0 END) as searches,
    SUM(CASE WHEN action LIKE '%upload%' THEN 1 ELSE 0 END) as uploads,
    SUM(CASE WHEN action LIKE '%note%' THEN 1 ELSE 0 END) as note_operations,
    AVG(duration_ms) as avg_latency_ms,
    MIN(created_at) as first_action,
    MAX(created_at) as last_action,
    EXTRACT(EPOCH FROM (MAX(created_at) - MIN(created_at))) / 60 as session_duration_min
FROM user_activities
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY user_id, DATE_TRUNC('day', created_at)
ORDER BY day DESC, total_actions DESC;

COMMENT ON VIEW v_user_activity_summary IS 'Per-user daily activity summary for Grafana';


-- -----------------------------------------------------------------------------
-- 5. ERROR ANALYSIS VIEW
-- Error patterns and frequency
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_error_analysis AS
SELECT 
    DATE_TRUNC('hour', el.created_at) as hour,
    el.error_type,
    el.error_code,
    el.message,
    COUNT(*) as error_count,
    el.user_id
FROM error_logs el
WHERE el.created_at >= NOW() - INTERVAL '30 days'
GROUP BY DATE_TRUNC('hour', el.created_at), el.error_type, el.error_code, el.message, el.user_id
ORDER BY hour DESC, error_count DESC;

COMMENT ON VIEW v_error_analysis IS 'Error frequency and patterns for Grafana';


-- -----------------------------------------------------------------------------
-- 6. OPERATION PERFORMANCE VIEW
-- Backend service operation metrics
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_operation_performance AS
SELECT 
    DATE_TRUNC('hour', created_at) as hour,
    service,
    operation,
    status,
    COUNT(*) as operation_count,
    AVG(duration_ms) as avg_duration_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms) as p95_duration_ms,
    MAX(duration_ms) as max_duration_ms,
    SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_count
FROM operation_logs
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY DATE_TRUNC('hour', created_at), service, operation, status
ORDER BY hour DESC, operation_count DESC;

COMMENT ON VIEW v_operation_performance IS 'Backend service operation metrics for Grafana';


-- -----------------------------------------------------------------------------
-- 7. DAILY SUMMARY FUNCTION
-- Aggregated daily metrics for overview dashboard
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_daily_summary(days_back int DEFAULT 7)
RETURNS TABLE (
    day date,
    total_users bigint,
    total_activities bigint,
    total_chats bigint,
    total_searches bigint,
    total_uploads bigint,
    total_errors bigint,
    avg_latency_ms numeric,
    error_rate_pct numeric
) 
LANGUAGE SQL
STABLE
AS $$
    SELECT 
        DATE_TRUNC('day', ua.created_at)::date as day,
        COUNT(DISTINCT ua.user_id) as total_users,
        COUNT(*) as total_activities,
        SUM(CASE WHEN ua.action = 'chat_query' THEN 1 ELSE 0 END) as total_chats,
        SUM(CASE WHEN ua.action LIKE '%search%' THEN 1 ELSE 0 END) as total_searches,
        SUM(CASE WHEN ua.action LIKE '%upload%' THEN 1 ELSE 0 END) as total_uploads,
        SUM(CASE WHEN ua.status = 'error' THEN 1 ELSE 0 END) as total_errors,
        ROUND(AVG(ua.duration_ms), 2) as avg_latency_ms,
        ROUND(
            100.0 * SUM(CASE WHEN ua.status = 'error' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0),
            2
        ) as error_rate_pct
    FROM user_activities ua
    WHERE ua.created_at >= NOW() - (days_back || ' days')::interval
    GROUP BY DATE_TRUNC('day', ua.created_at)::date
    ORDER BY day DESC;
$$;

COMMENT ON FUNCTION get_daily_summary IS 'Get daily summary metrics for Grafana overview dashboard';


-- -----------------------------------------------------------------------------
-- 8. AUTH ACTIVITY VIEW
-- Authentication and API key operations
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_auth_activity AS
SELECT 
    DATE_TRUNC('hour', created_at) as hour,
    user_id,
    action,
    status,
    duration_ms,
    metadata->>'auth_method' as auth_method,
    metadata->>'email' as email,
    metadata->>'key_name' as api_key_name,
    metadata->>'scopes' as scopes,
    created_at
FROM user_activities
WHERE action IN ('get_user_info', 'list_api_keys', 'create_api_key', 'delete_api_key', 'revoke_api_key')
  AND created_at >= NOW() - INTERVAL '30 days'
ORDER BY created_at DESC;

COMMENT ON VIEW v_auth_activity IS 'Authentication-related activity for Grafana';


-- -----------------------------------------------------------------------------
-- 9. CHAT ANALYTICS VIEW
-- Chat query patterns and performance
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_chat_analytics AS
SELECT 
    DATE_TRUNC('hour', created_at) as hour,
    user_id,
    status,
    duration_ms,
    (metadata->>'query_length')::int as query_length,
    (metadata->>'history_length')::int as history_length,
    (metadata->>'source_count')::int as source_count,
    (metadata->>'streaming')::boolean as is_streaming,
    metadata->>'error' as error_message,
    created_at
FROM user_activities
WHERE action = 'chat_query'
  AND created_at >= NOW() - INTERVAL '30 days'
ORDER BY created_at DESC;

COMMENT ON VIEW v_chat_analytics IS 'Chat query analytics for Grafana';


-- -----------------------------------------------------------------------------
-- 10. REAL-TIME ACTIVITY (LAST HOUR)
-- For live dashboard panel
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_realtime_activity AS
SELECT 
    ua.id,
    ua.user_id,
    ua.action,
    ua.resource_type,
    ua.status,
    ua.duration_ms,
    ua.created_at,
    EXTRACT(EPOCH FROM (NOW() - ua.created_at)) as seconds_ago
FROM user_activities ua
WHERE ua.created_at >= NOW() - INTERVAL '1 hour'
ORDER BY ua.created_at DESC
LIMIT 100;

COMMENT ON VIEW v_realtime_activity IS 'Real-time activity feed for Grafana live panel';


-- -----------------------------------------------------------------------------
-- GRANT PERMISSIONS (if using RLS)
-- -----------------------------------------------------------------------------
-- If your Supabase uses Row Level Security, you may need to grant access:
-- GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
-- GRANT SELECT ON ALL VIEWS IN SCHEMA public TO authenticated;

-- -----------------------------------------------------------------------------
-- INDEX RECOMMENDATIONS
-- Run these if queries are slow
-- -----------------------------------------------------------------------------
-- CREATE INDEX IF NOT EXISTS idx_user_activities_created_at ON user_activities(created_at DESC);
-- CREATE INDEX IF NOT EXISTS idx_user_activities_user_id ON user_activities(user_id);
-- CREATE INDEX IF NOT EXISTS idx_user_activities_action ON user_activities(action);
-- CREATE INDEX IF NOT EXISTS idx_operation_logs_created_at ON operation_logs(created_at DESC);
-- CREATE INDEX IF NOT EXISTS idx_error_logs_created_at ON error_logs(created_at DESC);
