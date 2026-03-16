-- Migration: Drop note_chunks table
-- Date: 2026-02-10
-- Description: Remove note_chunks table - chunks are now stored exclusively in Cloudflare Vectorize
-- 
-- BACKGROUND:
-- The note_chunks table was storing chunk content and embeddings redundantly.
-- Vectorize (Cloudflare's vector database) now handles all vector storage and search.
-- This migration removes the redundant storage to:
-- 1. Reduce Supabase storage costs
-- 2. Eliminate dual-write overhead on uploads
-- 3. Simplify the architecture (Vectorize is the single source of truth for vectors)
--
-- WHAT'S PRESERVED:
-- - notes table (contains full content_markdown for synthesis)
-- - notes.embedding (document-level embedding, may be removed in future)
-- - All logging tables
-- - Full-text search via content_tsv
--
-- ROLLBACK: If needed, run reindex_to_vectorize.py which can recreate chunks from notes table

-- ============================================================================
-- STEP 1: Drop RPC functions that use note_chunks
-- ============================================================================

-- Drop match_chunks (vector similarity search on chunks)
DROP FUNCTION IF EXISTS match_chunks(vector(768), integer, text);
DROP FUNCTION IF EXISTS match_chunks(vector, integer, text);

-- Drop search_chunks_with_context (chunk search with note joins)
DROP FUNCTION IF EXISTS search_chunks_with_context(vector(768), text, text, integer);
DROP FUNCTION IF EXISTS search_chunks_with_context(vector, text, text, integer);

-- ============================================================================
-- STEP 2: Drop indexes on note_chunks
-- ============================================================================

DROP INDEX IF EXISTS idx_chunks_note_id;
DROP INDEX IF EXISTS idx_chunks_embedding;
DROP INDEX IF EXISTS note_chunks_note_id_idx;
DROP INDEX IF EXISTS note_chunks_embedding_idx;

-- ============================================================================
-- STEP 3: Drop the note_chunks table
-- ============================================================================

DROP TABLE IF EXISTS note_chunks CASCADE;

-- ============================================================================
-- VERIFICATION: Run these to confirm cleanup
-- ============================================================================

-- Should return empty (no note_chunks related objects)
-- SELECT routine_name FROM information_schema.routines WHERE routine_name LIKE '%chunk%';
-- SELECT tablename FROM pg_tables WHERE tablename = 'note_chunks';

-- ============================================================================
-- NOTES:
-- ============================================================================
-- After running this migration:
-- 1. Deploy updated Python code (upload.py, notes_db.py, retrieval_tools.py, notes.py)
-- 2. Verify uploads still work (chunks go to Vectorize only)
-- 3. Verify search still works (uses Vectorize via Worker)
-- 4. Monitor Supabase storage - should decrease over time
