-- =============================================================================
-- SEARCH DEEP-DIVE VIEW FOR GRAFANA
-- =============================================================================
-- This view provides detailed search query analytics including:
-- - Client source (MCP server, Chrome Extension, Website)
-- - Search path (fast_path vs normal)
-- - Search internals (hybrid_search, reranker, spell correction)
-- 
-- Execute this in your Supabase SQL Editor AFTER adding the new metadata fields.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. SEARCH QUERIES DEEP-DIVE VIEW
-- All search/chat queries with full metadata extraction
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_search_queries;
CREATE OR REPLACE VIEW v_search_queries AS
SELECT 
    ua.id,
    ua.user_id,
    ua.created_at,
    ua.status,
    ua.duration_ms,
    ua.action,
    -- Extract the actual query text
    COALESCE(
        SUBSTRING(ua.metadata->>'query' FROM 1 FOR 200),
        '(query not captured)'
    ) as query_text,
    (ua.metadata->>'query_length')::int as query_length,
    -- Client source detection
    COALESCE(
        ua.metadata->>'client_source',
        CASE 
            WHEN ua.metadata->>'streaming' = 'true' THEN 'website'
            ELSE 'unknown'
        END
    ) as client_source,
    -- Search path indicators
    COALESCE((ua.metadata->>'fast_path')::boolean, false) as is_fast_path,
    COALESCE(ua.metadata->>'query_type', 'normal') as query_type,
    COALESCE(ua.metadata->>'search_type', 'hybrid_search') as search_type,
    -- Search internals
    COALESCE((ua.metadata->>'reranker_used')::boolean, false) as reranker_used,
    COALESCE((ua.metadata->>'spell_corrected')::boolean, false) as spell_corrected,
    (ua.metadata->>'total_candidates')::int as total_candidates,
    (ua.metadata->>'source_count')::int as results_returned,
    (ua.metadata->>'search_duration_ms')::int as search_duration_ms,
    -- Detected tags
    ua.metadata->>'detected_tags' as detected_tags,
    -- Streaming mode
    COALESCE((ua.metadata->>'streaming')::boolean, false) as is_streaming,
    -- History (for chat context)
    (ua.metadata->>'history_length')::int as history_length,
    -- Error info
    ua.metadata->>'error' as error_message,
    ua.correlation_id
FROM user_activities ua
WHERE ua.action IN ('chat_query', 'search_notes', 'vector_search', 'hybrid_search', 'instant_search')
  AND ua.created_at >= NOW() - INTERVAL '30 days'
ORDER BY ua.created_at DESC;

COMMENT ON VIEW v_search_queries IS 'Detailed search query view for Grafana deep-dive analysis';


-- -----------------------------------------------------------------------------
-- 2. SEARCH BY CLIENT SOURCE AGGREGATION
-- Aggregate search metrics by client source
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_search_by_source;
CREATE OR REPLACE VIEW v_search_by_source AS
SELECT 
    DATE_TRUNC('hour', created_at) as hour,
    COALESCE(
        metadata->>'client_source',
        CASE 
            WHEN metadata->>'streaming' = 'true' THEN 'website'
            ELSE 'unknown'
        END
    ) as client_source,
    COUNT(*) as query_count,
    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) as success_count,
    SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_count,
    ROUND(AVG(duration_ms)::numeric, 0) as avg_duration_ms,
    ROUND(AVG((metadata->>'source_count')::numeric), 1) as avg_results,
    SUM(CASE WHEN (metadata->>'fast_path')::boolean = true THEN 1 ELSE 0 END) as fast_path_count,
    SUM(CASE WHEN (metadata->>'reranker_used')::boolean = true THEN 1 ELSE 0 END) as reranker_used_count
FROM user_activities
WHERE action IN ('chat_query', 'search_notes', 'vector_search', 'hybrid_search', 'instant_search')
  AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY DATE_TRUNC('hour', created_at), 
         COALESCE(
             metadata->>'client_source',
             CASE 
                 WHEN metadata->>'streaming' = 'true' THEN 'website'
                 ELSE 'unknown'
             END
         )
ORDER BY hour DESC;

COMMENT ON VIEW v_search_by_source IS 'Search metrics aggregated by client source for Grafana';


-- -----------------------------------------------------------------------------
-- 3. SEARCH PATH ANALYSIS
-- Analyze fast_path vs normal path performance
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_search_path_analysis;
CREATE OR REPLACE VIEW v_search_path_analysis AS
SELECT 
    DATE_TRUNC('day', created_at) as day,
    CASE 
        WHEN (metadata->>'fast_path')::boolean = true THEN 'fast_path'
        ELSE 'normal_path'
    END as search_path,
    metadata->>'query_type' as query_type,
    COUNT(*) as query_count,
    ROUND(AVG(duration_ms)::numeric, 0) as avg_duration_ms,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY duration_ms)::numeric, 0) as p50_ms,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms)::numeric, 0) as p95_ms,
    ROUND(AVG((metadata->>'source_count')::numeric), 1) as avg_results
FROM user_activities
WHERE action IN ('chat_query', 'search_notes')
  AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY 
    DATE_TRUNC('day', created_at),
    CASE 
        WHEN (metadata->>'fast_path')::boolean = true THEN 'fast_path'
        ELSE 'normal_path'
    END,
    metadata->>'query_type'
ORDER BY day DESC;

COMMENT ON VIEW v_search_path_analysis IS 'Search path performance analysis for Grafana';


-- -----------------------------------------------------------------------------
-- 4. RERANKER IMPACT ANALYSIS
-- Compare performance with/without reranker
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_reranker_analysis;
CREATE OR REPLACE VIEW v_reranker_analysis AS
SELECT 
    DATE_TRUNC('day', created_at) as day,
    CASE 
        WHEN (metadata->>'reranker_used')::boolean = true THEN 'with_reranker'
        ELSE 'without_reranker'
    END as reranker_status,
    COUNT(*) as query_count,
    ROUND(AVG(duration_ms)::numeric, 0) as avg_total_duration_ms,
    ROUND(AVG((metadata->>'search_duration_ms')::numeric), 0) as avg_search_duration_ms,
    ROUND(AVG((metadata->>'source_count')::numeric), 1) as avg_results_returned,
    ROUND(AVG((metadata->>'total_candidates')::numeric), 1) as avg_candidates_before_rerank,
    ROUND(
        100.0 * SUM(CASE WHEN status = 'success' AND (metadata->>'source_count')::int > 0 THEN 1 ELSE 0 END) 
        / NULLIF(COUNT(*), 0),
        1
    ) as results_found_pct
FROM user_activities
WHERE action IN ('chat_query', 'search_notes')
  AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY 
    DATE_TRUNC('day', created_at),
    CASE 
        WHEN (metadata->>'reranker_used')::boolean = true THEN 'with_reranker'
        ELSE 'without_reranker'
    END
ORDER BY day DESC;

COMMENT ON VIEW v_reranker_analysis IS 'Reranker impact analysis for Grafana';


-- -----------------------------------------------------------------------------
-- 5. SPELL CORRECTION ANALYSIS
-- Track spell correction effectiveness
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_spell_correction_analysis;
CREATE OR REPLACE VIEW v_spell_correction_analysis AS
SELECT 
    DATE_TRUNC('day', created_at) as day,
    COUNT(*) as total_queries,
    SUM(CASE WHEN (metadata->>'spell_corrected')::boolean = true THEN 1 ELSE 0 END) as corrected_count,
    ROUND(
        100.0 * SUM(CASE WHEN (metadata->>'spell_corrected')::boolean = true THEN 1 ELSE 0 END) 
        / NULLIF(COUNT(*), 0),
        1
    ) as correction_rate_pct,
    -- Success rate for corrected vs non-corrected
    ROUND(
        100.0 * SUM(CASE WHEN (metadata->>'spell_corrected')::boolean = true AND status = 'success' THEN 1 ELSE 0 END) 
        / NULLIF(SUM(CASE WHEN (metadata->>'spell_corrected')::boolean = true THEN 1 ELSE 0 END), 0),
        1
    ) as corrected_success_rate,
    ROUND(
        100.0 * SUM(CASE WHEN COALESCE((metadata->>'spell_corrected')::boolean, false) = false AND status = 'success' THEN 1 ELSE 0 END) 
        / NULLIF(SUM(CASE WHEN COALESCE((metadata->>'spell_corrected')::boolean, false) = false THEN 1 ELSE 0 END), 0),
        1
    ) as non_corrected_success_rate
FROM user_activities
WHERE action IN ('chat_query', 'search_notes')
  AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY DATE_TRUNC('day', created_at)
ORDER BY day DESC;

COMMENT ON VIEW v_spell_correction_analysis IS 'Spell correction effectiveness for Grafana';


-- -----------------------------------------------------------------------------
-- 6. USER SEARCH JOURNEY
-- Track individual user search sessions for drill-down
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_user_search_journey;
CREATE OR REPLACE VIEW v_user_search_journey AS
SELECT 
    ua.id,
    ua.user_id,
    ua.created_at,
    ua.duration_ms,
    SUBSTRING(ua.metadata->>'query' FROM 1 FOR 100) as query_preview,
    COALESCE(ua.metadata->>'client_source', 'unknown') as client_source,
    ua.status,
    (ua.metadata->>'source_count')::int as results_count,
    COALESCE((ua.metadata->>'fast_path')::boolean, false) as fast_path,
    COALESCE((ua.metadata->>'reranker_used')::boolean, false) as reranker,
    COALESCE((ua.metadata->>'spell_corrected')::boolean, false) as spell_corrected,
    ua.metadata->>'search_type' as search_type,
    ua.metadata->>'query_type' as query_type,
    (ua.metadata->>'search_duration_ms')::int as search_ms,
    ua.metadata->>'detected_tags' as tags_detected,
    ua.metadata->>'error' as error,
    ua.correlation_id::text as correlation_id
FROM user_activities ua
WHERE ua.action IN ('chat_query', 'search_notes', 'instant_search')
  AND ua.created_at >= NOW() - INTERVAL '7 days'
ORDER BY ua.created_at DESC
LIMIT 500;

COMMENT ON VIEW v_user_search_journey IS 'User search journey for drill-down analysis in Grafana';


-- -----------------------------------------------------------------------------
-- 7. DETAILED OPERATION LOGS FOR DRILL-DOWN
-- Shows all operations related to a correlation_id (like notesapp.log)
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_operation_details;
CREATE OR REPLACE VIEW v_operation_details AS
SELECT 
    ol.id,
    ol.correlation_id::text as correlation_id,
    TO_CHAR(ol.created_at, 'YYYY-MM-DD HH24:MI:SS.MS') as timestamp,
    'operation' as log_type,
    'INFO' as log_level,
    ol.service as component,
    ol.operation,
    ol.status,
    ol.duration_ms,
    -- Format message like log file: "Operation completed: search_chunks (234ms) - success"
    CASE 
        WHEN ol.duration_ms IS NOT NULL THEN 
            ol.operation || ' (' || ol.duration_ms || 'ms) - ' || ol.status
        ELSE 
            ol.operation || ' - ' || ol.status
    END as message,
    ol.input_summary as metadata
FROM operation_logs ol
WHERE ol.created_at >= NOW() - INTERVAL '7 days'

UNION ALL

SELECT 
    el.id,
    el.correlation_id::text as correlation_id,
    TO_CHAR(el.created_at, 'YYYY-MM-DD HH24:MI:SS.MS') as timestamp,
    'error' as log_type,
    'ERROR' as log_level,
    'ErrorHandler' as component,
    el.error_type as operation,
    'error' as status,
    NULL as duration_ms,
    -- Format message like log file error format
    el.error_type || ': ' || el.message as message,
    jsonb_build_object('error_code', el.error_code, 'context', el.context, 'stack', LEFT(el.stack_trace, 500)) as metadata
FROM error_logs el
WHERE el.created_at >= NOW() - INTERVAL '7 days'

ORDER BY timestamp ASC;

COMMENT ON VIEW v_operation_details IS 'Detailed operation logs for drill-down (like notesapp.log format)';


-- -----------------------------------------------------------------------------
-- 8. SEARCH QUERY FULL DETAILS
-- Full details for a single search query including all related operations
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_search_query_full;
CREATE OR REPLACE VIEW v_search_query_full AS
SELECT 
    ua.id,
    ua.user_id,
    ua.correlation_id::text as correlation_id,
    TO_CHAR(ua.created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at,
    ua.action,
    ua.status,
    ua.duration_ms,
    ua.metadata->>'query' as query_text,
    COALESCE(ua.metadata->>'client_source', 'unknown') as client_source,
    COALESCE((ua.metadata->>'fast_path')::boolean, false) as is_fast_path,
    COALESCE(ua.metadata->>'query_type', 'normal') as query_type,
    COALESCE(ua.metadata->>'search_type', 'hybrid_search') as search_type,
    COALESCE((ua.metadata->>'reranker_used')::boolean, false) as reranker_used,
    COALESCE((ua.metadata->>'spell_corrected')::boolean, false) as spell_corrected,
    (ua.metadata->>'source_count')::int as results_count,
    (ua.metadata->>'total_candidates')::int as total_candidates,
    (ua.metadata->>'search_duration_ms')::int as search_duration_ms,
    ua.metadata->>'detected_tags' as detected_tags,
    (ua.metadata->>'history_length')::int as history_length,
    COALESCE((ua.metadata->>'streaming')::boolean, false) as streaming,
    ua.metadata->>'error' as error_message
FROM user_activities ua
WHERE ua.action IN ('chat_query', 'search_notes', 'instant_search')
  AND ua.created_at >= NOW() - INTERVAL '30 days'
ORDER BY ua.created_at DESC;

COMMENT ON VIEW v_search_query_full IS 'Full search query details for Grafana reports';


-- -----------------------------------------------------------------------------
-- 9. USERS LIST FOR DROPDOWN
-- List of users with activity counts for Grafana variable
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_active_users;
CREATE OR REPLACE VIEW v_active_users AS
SELECT DISTINCT 
    user_id,
    COUNT(*) as activity_count,
    MAX(created_at) as last_activity
FROM user_activities
WHERE created_at >= NOW() - INTERVAL '30 days'
  AND user_id != 'default_user'
  AND user_id != 'unknown'
GROUP BY user_id
ORDER BY last_activity DESC;

COMMENT ON VIEW v_active_users IS 'Active users list for Grafana dropdown filter';


-- -----------------------------------------------------------------------------
-- INDEX RECOMMENDATIONS FOR SEARCH DEEP-DIVE
-- Run these if queries are slow
-- -----------------------------------------------------------------------------
-- CREATE INDEX IF NOT EXISTS idx_ua_metadata_client_source ON user_activities ((metadata->>'client_source'));
-- CREATE INDEX IF NOT EXISTS idx_ua_metadata_fast_path ON user_activities (((metadata->>'fast_path')::boolean));
-- CREATE INDEX IF NOT EXISTS idx_ua_action_created ON user_activities (action, created_at DESC);
-- CREATE INDEX IF NOT EXISTS idx_ol_correlation ON operation_logs (correlation_id);
-- CREATE INDEX IF NOT EXISTS idx_el_correlation ON error_logs (correlation_id);

