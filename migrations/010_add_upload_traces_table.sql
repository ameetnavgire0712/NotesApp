-- =============================================================================
-- UPLOAD TRACES TABLE + STORAGE QUOTA FUNCTION
-- Stores detailed upload execution data for debugging and activity dashboard
-- Each row = one upload request with ALL intermediate pipeline timing data
-- =============================================================================

-- Upload traces table
CREATE TABLE IF NOT EXISTS upload_traces (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Request identification
    trace_id TEXT NOT NULL UNIQUE,
    user_id TEXT NOT NULL,
    
    -- Upload info
    upload_type TEXT NOT NULL,  -- 'file', 'screenshot', 'quick_note'
    original_filename TEXT,
    file_type TEXT,
    file_size_bytes BIGINT,
    tag TEXT,
    status TEXT NOT NULL DEFAULT 'accepted',  -- 'accepted', 'processing', 'completed', 'failed'
    
    -- Timestamps for each phase (ISO format)
    request_received_at TIMESTAMPTZ,
    processing_started_at TIMESTAMPTZ,
    blob_upload_started_at TIMESTAMPTZ,
    blob_upload_completed_at TIMESTAMPTZ,
    conversion_started_at TIMESTAMPTZ,
    conversion_completed_at TIMESTAMPTZ,
    html_cleanup_started_at TIMESTAMPTZ,
    html_cleanup_completed_at TIMESTAMPTZ,
    title_gen_started_at TIMESTAMPTZ,
    title_gen_completed_at TIMESTAMPTZ,
    embedding_started_at TIMESTAMPTZ,
    embedding_completed_at TIMESTAMPTZ,
    db_insert_started_at TIMESTAMPTZ,
    db_insert_completed_at TIMESTAMPTZ,
    vectorize_started_at TIMESTAMPTZ,
    vectorize_completed_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    
    -- Timing durations (milliseconds)
    timing_total_ms INTEGER,
    timing_blob_upload_ms INTEGER,
    timing_conversion_ms INTEGER,
    timing_html_cleanup_ms INTEGER,
    timing_title_gen_ms INTEGER,
    timing_embedding_ms INTEGER,
    timing_db_insert_ms INTEGER,
    timing_vectorize_ms INTEGER,
    
    -- Results
    title_generated TEXT,
    chunk_count INTEGER,
    vector_count INTEGER,
    note_id TEXT,          -- References notes.id if upload succeeded
    blob_url TEXT,
    conversion_method TEXT,  -- 'tensorlake', 'plain_text', 'direct', 'direct_html'
    content_length INTEGER,
    
    -- Storage quota tracking
    user_storage_before_bytes BIGINT,
    user_storage_after_bytes BIGINT,
    
    -- Errors
    error_message TEXT,
    pipeline_errors JSONB,   -- Array of non-fatal error strings
    
    -- Auth info
    auth_method TEXT,
    
    -- Auto timestamp
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_upload_traces_user_id ON upload_traces(user_id);
CREATE INDEX IF NOT EXISTS idx_upload_traces_trace_id ON upload_traces(trace_id);
CREATE INDEX IF NOT EXISTS idx_upload_traces_status ON upload_traces(status);
CREATE INDEX IF NOT EXISTS idx_upload_traces_created_at ON upload_traces(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_upload_traces_user_created ON upload_traces(user_id, created_at DESC);

-- =============================================================================
-- RPC Function: Get user's total storage in bytes
-- Only counts documents that successfully made it into the notes table
-- =============================================================================
CREATE OR REPLACE FUNCTION get_user_storage_bytes(p_user_id TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    total_bytes BIGINT;
BEGIN
    SELECT COALESCE(SUM(
        CASE 
            WHEN metadata->>'size_bytes' IS NOT NULL 
            THEN (metadata->>'size_bytes')::BIGINT
            ELSE LENGTH(content_markdown)  -- fallback to content length
        END
    ), 0)
    INTO total_bytes
    FROM notes
    WHERE user_id = p_user_id;
    
    RETURN total_bytes;
END;
$$;

-- Grant access to the function
GRANT EXECUTE ON FUNCTION get_user_storage_bytes(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION get_user_storage_bytes(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_storage_bytes(TEXT) TO service_role;

-- =============================================================================
-- Enable RLS on upload_traces
-- =============================================================================
ALTER TABLE upload_traces ENABLE ROW LEVEL SECURITY;

-- Allow service role full access
CREATE POLICY "Service role full access on upload_traces"
    ON upload_traces
    FOR ALL
    USING (true)
    WITH CHECK (true);

-- Allow users to read their own traces
CREATE POLICY "Users can read own upload traces"
    ON upload_traces
    FOR SELECT
    USING (auth.uid()::TEXT = user_id);
