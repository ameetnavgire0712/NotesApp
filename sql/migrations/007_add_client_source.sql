-- Migration: Add client_source column to search_traces
-- This allows differentiating between Google search (Chrome extension) and Dashboard chat searches

ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS client_source TEXT;

-- Add index for faster filtering by client_source
CREATE INDEX IF NOT EXISTS idx_search_traces_client_source ON search_traces(client_source);

-- Create a composite index for user + client_source for the stats query
CREATE INDEX IF NOT EXISTS idx_search_traces_user_client_source ON search_traces(user_id, client_source);

COMMENT ON COLUMN search_traces.client_source IS 'Source of the search request: google-search, dashboard, extension, etc.';
