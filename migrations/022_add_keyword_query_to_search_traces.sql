-- Add keyword query to search_traces for observability
ALTER TABLE search_traces
ADD COLUMN IF NOT EXISTS keyword_query TEXT;
