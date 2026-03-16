-- Migration to add timestamp and auth columns to search_traces table
-- These columns track when each phase of the request occurred and auth details

-- Timestamps for each phase (ISO format)
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS request_received_at TIMESTAMPTZ;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS auth_started_at TIMESTAMPTZ;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS auth_completed_at TIMESTAMPTZ;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS spell_check_started_at TIMESTAMPTZ;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS tags_fetch_started_at TIMESTAMPTZ;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS embedding_started_at TIMESTAMPTZ;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS search_started_at TIMESTAMPTZ;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS rerank_started_at TIMESTAMPTZ;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS relevance_check_started_at TIMESTAMPTZ;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS synthesis_started_at TIMESTAMPTZ;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS response_sent_at TIMESTAMPTZ;

-- Auth timing and details
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS timing_auth_ms INTEGER;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS auth_method TEXT;  -- 'jwt', 'api_key', 'worker_key'
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS auth_user_email TEXT;

-- Add comments
COMMENT ON COLUMN search_traces.request_received_at IS 'When the request arrived at the Worker';
COMMENT ON COLUMN search_traces.auth_started_at IS 'When authentication validation started';
COMMENT ON COLUMN search_traces.auth_completed_at IS 'When authentication validation completed';
COMMENT ON COLUMN search_traces.spell_check_started_at IS 'When spell check started';
COMMENT ON COLUMN search_traces.tags_fetch_started_at IS 'When tags fetch started';
COMMENT ON COLUMN search_traces.embedding_started_at IS 'When embedding generation started';
COMMENT ON COLUMN search_traces.search_started_at IS 'When vector/keyword search started';
COMMENT ON COLUMN search_traces.rerank_started_at IS 'When reranking started';
COMMENT ON COLUMN search_traces.relevance_check_started_at IS 'When LLM relevance check started';
COMMENT ON COLUMN search_traces.synthesis_started_at IS 'When LLM synthesis started';
COMMENT ON COLUMN search_traces.response_sent_at IS 'When the response was sent';
COMMENT ON COLUMN search_traces.timing_auth_ms IS 'Auth validation duration in milliseconds';
COMMENT ON COLUMN search_traces.auth_method IS 'Authentication method used: jwt, api_key, or worker_key';
COMMENT ON COLUMN search_traces.auth_user_email IS 'User email from auth if available';

-- Create index on request_received_at for time-based queries
CREATE INDEX IF NOT EXISTS idx_st_request_received ON search_traces(request_received_at DESC);
