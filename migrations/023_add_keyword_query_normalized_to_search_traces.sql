-- Add normalized keyword query to search_traces for keyword observability
ALTER TABLE search_traces
ADD COLUMN IF NOT EXISTS keyword_query_normalized TEXT;
