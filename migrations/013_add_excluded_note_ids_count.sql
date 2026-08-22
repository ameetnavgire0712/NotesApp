-- Migration 013: Add excluded_note_ids_count column to search_traces
-- This column was being written by the worker but never added to the table schema
-- It also caused the activity logs dashboard to fail with a 400 error

ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS excluded_note_ids_count INTEGER;

COMMENT ON COLUMN search_traces.excluded_note_ids_count IS 'Number of note IDs excluded from search (e.g. already-displayed notes in chat)';
