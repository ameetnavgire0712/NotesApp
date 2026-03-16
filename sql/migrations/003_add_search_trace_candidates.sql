-- =============================================================================
-- ADD CANDIDATE ARRAYS TO SEARCH_TRACES TABLE
-- Run this SQL in your Supabase SQL Editor to add the missing columns
-- =============================================================================

-- Add candidate array columns if they don't exist
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS vector_candidates JSONB DEFAULT '[]';
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS keyword_candidates JSONB DEFAULT '[]';
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS combined_candidates JSONB DEFAULT '[]';
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS reranked_candidates JSONB DEFAULT '[]';
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS relevance_verified_candidates JSONB DEFAULT '[]';
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS final_results JSONB DEFAULT '[]';

-- Add chunk grouping columns
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS chunks_before_grouping INTEGER;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS chunks_after_grouping INTEGER;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS unique_documents INTEGER;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS chunks_per_doc_limit INTEGER;

-- Add dedup columns
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS dedup_before_count INTEGER;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS dedup_after_count INTEGER;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS dedup_removed INTEGER;

-- Add relevance verified count
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS relevance_verified_count INTEGER;

-- Add threshold columns
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS min_vector_threshold NUMERIC;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS min_rerank_threshold NUMERIC;

COMMENT ON COLUMN search_traces.vector_candidates IS 'Raw vector search results before combining';
COMMENT ON COLUMN search_traces.keyword_candidates IS 'Raw keyword search results before combining';
COMMENT ON COLUMN search_traces.combined_candidates IS 'Results after combining vector + keyword (top 3 per doc)';
COMMENT ON COLUMN search_traces.reranked_candidates IS 'Results after reranking with Voyage';
COMMENT ON COLUMN search_traces.relevance_verified_candidates IS 'Results after LLM relevance verification';
COMMENT ON COLUMN search_traces.final_results IS 'Final deduplicated results returned to user';
