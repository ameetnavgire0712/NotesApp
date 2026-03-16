-- Migration 006: Add user_id indexes for faster queries
-- Run this in Supabase SQL Editor

-- ============================================================================
-- 1. Index on user_id (used in almost every query)
-- ============================================================================

-- Primary index on user_id for fast user-scoped queries
CREATE INDEX IF NOT EXISTS notes_user_id_idx ON notes (user_id);

-- ============================================================================
-- 2. Composite index for get_tags_with_counts (user_id + tag)
-- ============================================================================

-- This speeds up the GROUP BY tag WHERE user_id = X queries
CREATE INDEX IF NOT EXISTS notes_user_tag_idx ON notes (user_id, tag) 
WHERE tag IS NOT NULL;

-- ============================================================================
-- 3. Index on note_chunks.note_id for faster joins
-- ============================================================================

-- Speeds up JOIN between note_chunks and notes tables
CREATE INDEX IF NOT EXISTS note_chunks_note_id_idx ON note_chunks (note_id);

-- ============================================================================
-- 4. Composite index for chunk search by user (via join)
-- ============================================================================

-- Index on user_id in notes for chunk search joins
CREATE INDEX IF NOT EXISTS notes_user_id_created_idx ON notes (user_id, created_at DESC);

-- ============================================================================
-- Verify indexes were created
-- ============================================================================

-- Run this to verify:
-- SELECT indexname, tablename FROM pg_indexes 
-- WHERE tablename IN ('notes', 'note_chunks') 
-- ORDER BY tablename, indexname;
