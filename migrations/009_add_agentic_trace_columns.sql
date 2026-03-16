-- =============================================================================
-- ADD AGENTIC RAG COLUMNS TO SEARCH_TRACES TABLE
-- Adds columns for intent classification, tool routing, and error tracking
-- Run this SQL in your Supabase SQL Editor
-- =============================================================================

-- Intent classification columns (LLM Intent Router output)
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS intent_classification TEXT;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS intent_confidence TEXT;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS intent_reasoning TEXT;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS timing_intent_router_ms INTEGER;

-- Tool/handler that was invoked after intent routing
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS tool_invoked TEXT;

-- Collection metadata fetch timing (for COLLECTION_SUMMARY and EXPLORATORY)
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS timing_collection_fetch_ms INTEGER;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS collection_doc_count INTEGER;

-- The path_taken field (already existed as a concept, now stored explicitly)
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS path_taken TEXT;

-- Error tracking
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS error_occurred BOOLEAN DEFAULT FALSE;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS error_message TEXT;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS error_type TEXT;

-- LLM calls array (detailed log of all LLM invocations in the pipeline)
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS llm_calls JSONB DEFAULT '[]';

-- Answer generated (truncated for storage)
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS answer_generated BOOLEAN DEFAULT FALSE;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS answer_preview TEXT;

-- Add comments
COMMENT ON COLUMN search_traces.intent_classification IS 'LLM-classified intent: CONTENT_SEARCH, TAG_BROWSE, COLLECTION_SUMMARY, EXPLORATORY, DATE_QUERY, MULTI_STEP';
COMMENT ON COLUMN search_traces.intent_confidence IS 'LLM confidence: HIGH, MEDIUM, LOW';
COMMENT ON COLUMN search_traces.intent_reasoning IS 'LLM reasoning for intent classification';
COMMENT ON COLUMN search_traces.timing_intent_router_ms IS 'Duration of LLM intent classification call';
COMMENT ON COLUMN search_traces.tool_invoked IS 'Handler/tool invoked: hybrid_search, tag_browse, collection_summary, exploratory, date_query_canned, multi_step_canned';
COMMENT ON COLUMN search_traces.timing_collection_fetch_ms IS 'Duration of collection metadata fetch from Supabase';
COMMENT ON COLUMN search_traces.collection_doc_count IS 'Number of docs fetched for collection summary/exploratory';
COMMENT ON COLUMN search_traces.path_taken IS 'Final path taken: hybrid, tag, tag_browse, collection_summary, exploratory';
COMMENT ON COLUMN search_traces.error_occurred IS 'Whether an error occurred during processing';
COMMENT ON COLUMN search_traces.error_message IS 'Error message if an error occurred';
COMMENT ON COLUMN search_traces.error_type IS 'Error type/category';
COMMENT ON COLUMN search_traces.llm_calls IS 'Array of {model, purpose, duration_ms} for all LLM calls in pipeline';
COMMENT ON COLUMN search_traces.answer_generated IS 'Whether an answer/synthesis was generated';
COMMENT ON COLUMN search_traces.answer_preview IS 'First 200 chars of the generated answer';

-- Index on intent for analytics
CREATE INDEX IF NOT EXISTS idx_st_intent ON search_traces(intent_classification);
CREATE INDEX IF NOT EXISTS idx_st_tool ON search_traces(tool_invoked);
CREATE INDEX IF NOT EXISTS idx_st_error ON search_traces(error_occurred) WHERE error_occurred = TRUE;
