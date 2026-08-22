-- Migration 017: Add title/description match fields to search_traces
--
-- Adds new columns to track title and description keyword matching:
-- - title_match_count: Number of notes matching on title
-- - description_match_count: Number of notes matching on description  
-- - title_only_injected: Notes found ONLY by title (no content match)
-- - desc_only_injected: Notes found ONLY by description (no content match)
-- - title_with_content_injected: Notes matching title AND content
-- - desc_with_content_injected: Notes matching description AND content
--
-- Run this in Supabase SQL Editor.

-- ============================================================================
-- Add new columns to search_traces table
-- ============================================================================

-- Title/description match counts
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS title_match_count INTEGER DEFAULT
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS description_match_count INTEGER DEFAULT 0;

-- Injection counts for different match scenarios
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS title_only_injected INTEGER DEFAULT 0;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS desc_only_injected INTEGER DEFAULT 0;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS title_with_content_injected INTEGER DEFAULT 0;
ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS desc_with_content_injected INTEGER DEFAULT 0;

-- Add comment for documentation
COMMENT ON COLUMN search_traces.title_match_count IS 'Number of notes with keyword match in title';
COMMENT ON COLUMN search_traces.description_match_count IS 'Number of notes with keyword match in description';
COMMENT ON COLUMN search_traces.title_only_injected IS 'Notes found ONLY by title keyword match (no content match)';
COMMENT ON COLUMN search_traces.desc_only_injected IS 'Notes found ONLY by description keyword match (no content match)';
COMMENT ON COLUMN search_traces.title_with_content_injected IS 'Notes matching keyword in both title AND content';
COMMENT ON COLUMN search_traces.desc_with_content_injected IS 'Notes matching keyword in both description AND content';

-- ============================================================================
-- Summary of changes:
-- ============================================================================
-- Added 6 new columns to search_traces for tracking title/description keyword matching:
-- 1. title_match_count - total title matches
-- 2. description_match_count - total description matches
-- 3. title_only_injected - title-only matches injected as pseudo-chunks
-- 4. desc_only_injected - description-only matches injected as pseudo-chunks
-- 5. title_with_content_injected - title+content matches (NEW)
-- 6. desc_with_content_injected - description+content matches (NEW)
