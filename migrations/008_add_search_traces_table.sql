-- =============================================================================
-- SEARCH TRACE TABLE
-- Stores detailed search execution data for debugging and analysis
-- Each row = one search request with ALL intermediate data from Worker + Backend
-- =============================================================================

CREATE TABLE IF NOT EXISTS search_traces (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Request identification
    correlation_id TEXT NOT NULL,  -- Backend correlation_id (links Worker trace to backend)
    user_id TEXT NOT NULL,
    
    -- Query info
    query TEXT NOT NULL,
    query_corrected TEXT,  -- After spell check
    
    -- ==========================================================================
    -- WORKER-LEVEL DATA (Cloudflare Worker /hybrid endpoint)
    -- ==========================================================================
    
    -- Timing breakdown (all in milliseconds)
    timing_total_ms INTEGER,
    timing_gateway_ms INTEGER,       -- Time in CF Gateway
    timing_worker_ms INTEGER,        -- Time in CF Worker
    timing_embedding_ms INTEGER,     -- Embedding generation
    timing_vector_search_ms INTEGER, -- Vectorize query
    timing_keyword_search_ms INTEGER,-- Supabase FTS
    timing_rerank_ms INTEGER,        -- Voyage AI rerank
    timing_fly_ms INTEGER,           -- Time in Fly.io backend
    
    -- Cache status
    embedding_cached BOOLEAN DEFAULT FALSE,
    search_cached BOOLEAN DEFAULT FALSE,
    
    -- Search candidates at each stage (stored as JSONB for flexibility)
    vector_candidates JSONB,    -- Raw vector search results with scores
    keyword_candidates JSONB,   -- Keyword search matches
    combined_candidates JSONB,  -- After combining vector + keyword
    reranked_candidates JSONB,  -- After reranking with scores
    final_results JSONB,        -- Final returned results
    
    -- Counts for quick analysis
    vector_count INTEGER,
    keyword_count INTEGER,
    combined_count INTEGER,
    reranked_count INTEGER,
    final_count INTEGER,
    
    -- Thresholds used
    min_vector_threshold REAL,
    min_rerank_threshold REAL,
    
    -- ==========================================================================
    -- BACKEND-LEVEL DATA (Fly.io RAG Agent)
    -- ==========================================================================
    
    -- Spell check
    spell_check_original TEXT,       -- Original query before correction
    spell_check_corrected TEXT,      -- Corrected query (if any)
    spell_check_was_corrected BOOLEAN DEFAULT FALSE,
    spell_check_explanation TEXT,    -- Why it was corrected
    spell_check_duration_ms INTEGER,
    
    -- Tag detection
    tags_available JSONB,            -- All available tags for user
    tags_detected JSONB,             -- Tags detected in query
    tag_intent TEXT,                 -- 'list_all' or 'specific'
    tags_cache_hit BOOLEAN DEFAULT FALSE,
    tags_fetch_duration_ms INTEGER,
    
    -- Query analysis
    query_intent TEXT,               -- 'discovery', 'comparison', 'temporal', etc.
    query_complexity TEXT,           -- 'simple', 'moderate', 'complex'
    query_keywords JSONB,            -- Extracted keywords
    query_needs_synthesis BOOLEAN DEFAULT FALSE,
    query_analysis_duration_ms INTEGER,
    
    -- Circuit breaker status
    circuit_breaker_open BOOLEAN DEFAULT FALSE,
    circuit_breaker_avg_latency_ms INTEGER,
    
    -- Synthesis cache
    synthesis_cache_hit BOOLEAN DEFAULT FALSE,
    synthesis_cache_key TEXT,
    synthesis_duration_ms INTEGER,
    
    -- LLM calls
    llm_calls JSONB,                 -- Array of {model, purpose, tokens_in, tokens_out, duration_ms}
    
    -- Agent steps (full trace from RAG agent)
    agent_steps JSONB,               -- Array of AgentStep objects
    
    -- Final metadata from backend
    backend_metadata JSONB,          -- Additional metadata from RAG agent
    
    -- Source info
    source_gateway TEXT,  -- 'cloudflare-gateway'
    source_worker TEXT,   -- 'cloudflare-worker'
    source_backend TEXT,  -- 'fly-io'
    
    -- Metadata
    request_path TEXT,
    client_ip TEXT,
    user_agent TEXT,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_st_correlation ON search_traces(correlation_id);
CREATE INDEX IF NOT EXISTS idx_st_user_time ON search_traces(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_st_created ON search_traces(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_st_query ON search_traces USING gin(to_tsvector('english', query));

-- Enable RLS
ALTER TABLE search_traces ENABLE ROW LEVEL SECURITY;

-- Policy: Service role can do everything
CREATE POLICY "Service role full access" ON search_traces
    FOR ALL USING (true);

COMMENT ON TABLE search_traces IS 'Detailed search execution traces for debugging and analysis';
COMMENT ON COLUMN search_traces.vector_candidates IS 'Array of {note_id, title, vector_score, content_preview}';
COMMENT ON COLUMN search_traces.keyword_candidates IS 'Array of {note_id, keyword_score}';
COMMENT ON COLUMN search_traces.combined_candidates IS 'Array of {note_id, title, vector_score, keyword_score, combined_score}';
COMMENT ON COLUMN search_traces.reranked_candidates IS 'Array of {note_id, title, combined_score, rerank_score, passed_threshold}';
