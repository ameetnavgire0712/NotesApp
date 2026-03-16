-- =============================================================================
-- Supabase Migration: Log Exports Table
-- 
-- Tracks log export jobs to Azure Blob Storage
-- Run with: supabase db push
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.log_exports (
    id BIGSERIAL PRIMARY KEY,
    job_id VARCHAR(100) NOT NULL UNIQUE,
    export_type VARCHAR(50) NOT NULL,
    status VARCHAR(20) NOT NULL CHECK (status IN ('started', 'completed', 'failed')),
    record_count INTEGER,
    time_range_start TIMESTAMPTZ,
    time_range_end TIMESTAMPTZ,
    blob_path TEXT,
    error_message TEXT,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for querying
CREATE INDEX IF NOT EXISTS idx_log_exports_job_id ON public.log_exports(job_id);
CREATE INDEX IF NOT EXISTS idx_log_exports_type ON public.log_exports(export_type);
CREATE INDEX IF NOT EXISTS idx_log_exports_status ON public.log_exports(status);
CREATE INDEX IF NOT EXISTS idx_log_exports_created ON public.log_exports(created_at DESC);

-- Comments
COMMENT ON TABLE public.log_exports IS 'Tracks logs exported to Azure Blob Storage';
COMMENT ON COLUMN public.log_exports.job_id IS 'Unique job identifier';
COMMENT ON COLUMN public.log_exports.export_type IS 'Type of export: supabase_search_traces, cloudflare_worker_logs';
COMMENT ON COLUMN public.log_exports.blob_path IS 'Path in Azure Blob: container/filename.json';
