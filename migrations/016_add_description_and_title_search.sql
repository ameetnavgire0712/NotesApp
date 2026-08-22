-- Migration 016: Add description field and enable title/description in keyword search
--
-- Changes:
-- 1. Add `description` column to `notes` table (optional, max 200 chars)
-- 2. Add `description` column to `note_chunks` table (for fulltext search)  
-- 3. Update `search_chunks_fulltext` RPC to also search notes.title and notes.description
--    using Option A (JOIN approach) - cleanest, no data duplication
--
-- Run this in Supabase SQL Editor BEFORE deploying the worker.

-- ============================================================================
-- 1. Add description column to notes table
-- ============================================================================
ALTER TABLE notes ADD COLUMN IF NOT EXISTS description TEXT;

-- Add check constraint to limit description to 200 characters
-- (Note: If column already exists without constraint, this will add it)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notes_description_max_length'
  ) THEN
    ALTER TABLE notes ADD CONSTRAINT notes_description_max_length 
      CHECK (description IS NULL OR length(description) <= 200);
  END IF;
END $$;

-- Create index for fulltext search on description
CREATE INDEX IF NOT EXISTS idx_notes_description_fts_english 
    ON notes USING GIN (to_tsvector('english', COALESCE(description, '')));
CREATE INDEX IF NOT EXISTS idx_notes_description_fts_simple 
    ON notes USING GIN (to_tsvector('simple', COALESCE(description, '')));

-- Create index for fulltext search on title (if not exists)
CREATE INDEX IF NOT EXISTS idx_notes_title_fts_english 
    ON notes USING GIN (to_tsvector('english', COALESCE(title, '')));
CREATE INDEX IF NOT EXISTS idx_notes_title_fts_simple 
    ON notes USING GIN (to_tsvector('simple', COALESCE(title, '')));

-- ============================================================================
-- 2. Update search_chunks_fulltext RPC to search title and description via JOIN
-- ============================================================================
-- This uses Option A: JOIN to notes table to include title/description in search
-- Benefits: 
--   - No data duplication (title/description stored only in notes table)
--   - Automatically picks up title changes
--   - Clean separation of concerns

-- Drop existing function first (return type is changing - adding match_source column)
DROP FUNCTION IF EXISTS search_chunks_fulltext(text, text, text, integer);

CREATE OR REPLACE FUNCTION search_chunks_fulltext(
    query_text text,
    match_user_id text,
    match_tag text DEFAULT NULL,
    match_limit int DEFAULT 50
)
RETURNS TABLE (
    note_id uuid,
    chunk_index integer,
    chunk_content text,
    text_rank float,
    match_source text  -- 'chunk', 'title', or 'description'
)
LANGUAGE plpgsql
AS $$
DECLARE
    english_query tsquery;
    simple_query tsquery;
    use_simple boolean := false;
BEGIN
    -- Try English config first (better stemming for normal words)
    english_query := plainto_tsquery('english', query_text);
    
    -- If English config produces empty tsquery (e.g. "B12", numeric tokens),
    -- fall back to simple config which preserves all tokens
    IF english_query::text = '' THEN
        simple_query := plainto_tsquery('simple', query_text);
        use_simple := true;
    END IF;

    IF use_simple THEN
        -- Simple config search
        RETURN QUERY
        WITH chunk_matches AS (
            -- Search in chunk content
            SELECT 
                nc.note_id,
                nc.chunk_index,
                LEFT(nc.content, 2000) as chunk_content,
                ts_rank_cd(to_tsvector('simple', nc.content), simple_query)::float as text_rank,
                'chunk'::text as match_source
            FROM note_chunks nc
            WHERE nc.user_id = match_user_id
              AND (match_tag IS NULL OR nc.tag = match_tag)
              AND to_tsvector('simple', nc.content) @@ simple_query
        ),
        title_matches AS (
            -- Search in note title (return as chunk -1)
            SELECT 
                n.id as note_id,
                -1 as chunk_index,
                n.title as chunk_content,
                ts_rank_cd(to_tsvector('simple', COALESCE(n.title, '')), simple_query)::float * 1.5 as text_rank,  -- Boost title matches
                'title'::text as match_source
            FROM notes n
            WHERE n.user_id = match_user_id
              AND (match_tag IS NULL OR n.tag = match_tag)
              AND to_tsvector('simple', COALESCE(n.title, '')) @@ simple_query
        ),
        description_matches AS (
            -- Search in note description (return as chunk -2)
            SELECT 
                n.id as note_id,
                -2 as chunk_index,
                n.description as chunk_content,
                ts_rank_cd(to_tsvector('simple', COALESCE(n.description, '')), simple_query)::float * 1.2 as text_rank,  -- Slight boost for description
                'description'::text as match_source
            FROM notes n
            WHERE n.user_id = match_user_id
              AND (match_tag IS NULL OR n.tag = match_tag)
              AND n.description IS NOT NULL
              AND to_tsvector('simple', COALESCE(n.description, '')) @@ simple_query
        ),
        all_matches AS (
            SELECT * FROM chunk_matches
            UNION ALL
            SELECT * FROM title_matches
            UNION ALL
            SELECT * FROM description_matches
        )
        SELECT 
            am.note_id,
            am.chunk_index,
            am.chunk_content,
            am.text_rank,
            am.match_source
        FROM all_matches am
        ORDER BY am.text_rank DESC
        LIMIT match_limit;
    ELSE
        -- English config search
        RETURN QUERY
        WITH chunk_matches AS (
            -- Search in chunk content
            SELECT 
                nc.note_id,
                nc.chunk_index,
                LEFT(nc.content, 2000) as chunk_content,
                ts_rank_cd(to_tsvector('english', nc.content), english_query)::float as text_rank,
                'chunk'::text as match_source
            FROM note_chunks nc
            WHERE nc.user_id = match_user_id
              AND (match_tag IS NULL OR nc.tag = match_tag)
              AND to_tsvector('english', nc.content) @@ english_query
        ),
        title_matches AS (
            -- Search in note title (return as chunk -1)
            SELECT 
                n.id as note_id,
                -1 as chunk_index,
                n.title as chunk_content,
                ts_rank_cd(to_tsvector('english', COALESCE(n.title, '')), english_query)::float * 1.5 as text_rank,  -- Boost title matches
                'title'::text as match_source
            FROM notes n
            WHERE n.user_id = match_user_id
              AND (match_tag IS NULL OR n.tag = match_tag)
              AND to_tsvector('english', COALESCE(n.title, '')) @@ english_query
        ),
        description_matches AS (
            -- Search in note description (return as chunk -2)
            SELECT 
                n.id as note_id,
                -2 as chunk_index,
                n.description as chunk_content,
                ts_rank_cd(to_tsvector('english', COALESCE(n.description, '')), english_query)::float * 1.2 as text_rank,  -- Slight boost for description
                'description'::text as match_source
            FROM notes n
            WHERE n.user_id = match_user_id
              AND (match_tag IS NULL OR n.tag = match_tag)
              AND n.description IS NOT NULL
              AND to_tsvector('english', COALESCE(n.description, '')) @@ english_query
        ),
        all_matches AS (
            SELECT * FROM chunk_matches
            UNION ALL
            SELECT * FROM title_matches
            UNION ALL
            SELECT * FROM description_matches
        )
        SELECT 
            am.note_id,
            am.chunk_index,
            am.chunk_content,
            am.text_rank,
            am.match_source
        FROM all_matches am
        ORDER BY am.text_rank DESC
        LIMIT match_limit;
    END IF;
END;
$$;

-- ============================================================================
-- 3. Grant permissions (if needed)
-- ============================================================================
-- GRANT EXECUTE ON FUNCTION search_chunks_fulltext TO authenticated;
-- GRANT EXECUTE ON FUNCTION search_chunks_fulltext TO service_role;

-- ============================================================================
-- Summary of changes:
-- ============================================================================
-- 1. Added `description` column to `notes` table (max 200 chars)
-- 2. Added fulltext indexes on notes.title and notes.description
-- 3. Updated search_chunks_fulltext to search in:
--    - note_chunks.content (existing) → match_source='chunk'
--    - notes.title (new) → match_source='title', chunk_index=-1, 1.5x boost
--    - notes.description (new) → match_source='description', chunk_index=-2, 1.2x boost
--
-- The RPC now returns `match_source` column to indicate where the match came from.
-- Title matches get 1.5x score boost, description matches get 1.2x boost.
