-- Migration 015: Create note_chunks table for chunk-level fulltext keyword search
-- 
-- Problem: keyword search operates on notes.content_markdown (note-level),
-- but hybrid search selects individual chunks. The selected chunk may not
-- contain the keyword that matched at note level (e.g. "b12" is in chunk 3
-- but vector search picks chunk 0 which is the report header).
--
-- Solution: Store raw chunks in note_chunks table with fulltext indexes,
-- so keyword search can find the SPECIFIC chunk containing the keyword.
--
-- Run this in Supabase SQL Editor BEFORE deploying the worker.

-- 1. Create note_chunks table
CREATE TABLE IF NOT EXISTS note_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    note_id UUID NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL,
    content TEXT NOT NULL,
    user_id TEXT NOT NULL,
    tag TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(note_id, chunk_index)
);

-- 2. Create indexes
CREATE INDEX IF NOT EXISTS idx_note_chunks_note_id ON note_chunks(note_id);
CREATE INDEX IF NOT EXISTS idx_note_chunks_user_id ON note_chunks(user_id);
CREATE INDEX IF NOT EXISTS idx_note_chunks_user_tag ON note_chunks(user_id, tag);

-- GIN fulltext indexes for both English and simple configs
CREATE INDEX IF NOT EXISTS idx_note_chunks_fts_english 
    ON note_chunks USING GIN (to_tsvector('english', content));
CREATE INDEX IF NOT EXISTS idx_note_chunks_fts_simple 
    ON note_chunks USING GIN (to_tsvector('simple', content));

-- 3. Create chunk-level fulltext search RPC
-- Same English -> simple fallback logic as search_notes_fulltext (migration 012)
-- but searches note_chunks.content instead of notes.content_markdown
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
    text_rank float
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
        RETURN QUERY
        SELECT 
            nc.note_id,
            nc.chunk_index,
            LEFT(nc.content, 2000) as chunk_content,
            ts_rank_cd(
                to_tsvector('simple', nc.content),
                simple_query
            )::float as text_rank
        FROM note_chunks nc
        WHERE nc.user_id = match_user_id
          AND (match_tag IS NULL OR nc.tag = match_tag)
          AND to_tsvector('simple', nc.content) @@ simple_query
        ORDER BY text_rank DESC
        LIMIT match_limit;
    ELSE
        RETURN QUERY
        SELECT 
            nc.note_id,
            nc.chunk_index,
            LEFT(nc.content, 2000) as chunk_content,
            ts_rank_cd(
                to_tsvector('english', nc.content),
                english_query
            )::float as text_rank
        FROM note_chunks nc
        WHERE nc.user_id = match_user_id
          AND (match_tag IS NULL OR nc.tag = match_tag)
          AND to_tsvector('english', nc.content) @@ english_query
        ORDER BY text_rank DESC
        LIMIT match_limit;
    END IF;
END;
$$;
