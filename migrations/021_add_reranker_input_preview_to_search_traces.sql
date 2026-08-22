-- Add reranker input preview payload to search_traces for observability
ALTER TABLE search_traces
ADD COLUMN IF NOT EXISTS reranker_input_preview JSONB DEFAULT '[]'::jsonb;
