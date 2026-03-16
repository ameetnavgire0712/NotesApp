-- Migration 007: Add full-text search RPC for hybrid search keyword matching
-- Run this in Supabase SQL Editor

-- ============================================================================
-- Full-text search function for keyword matching
-- Used by hybrid_search to find documents containing exact query keywords
-- ============================================================================

CREATE OR REPLACE FUNCTION search_notes_fulltext(
    query_text text,
    match_user_id text,
    match_tag text DEFAULT NULL,
    match_limit int DEFAULT 20
)
RETURNS TABLE (
    id uuid,
    title text,
    tag text,
    text_rank float
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        n.id,
        n.title,
        n.tag,
        ts_rank_cd(
            to_tsvector('english', COALESCE(n.title, '') || ' ' || COALESCE(n.content_markdown, '')),
            plainto_tsquery('english', query_text)
        )::float as text_rank
    FROM notes n
    WHERE n.user_id = match_user_id
      AND (match_tag IS NULL OR n.tag = match_tag)
      AND to_tsvector('english', COALESCE(n.title, '') || ' ' || COALESCE(n.content_markdown, ''))
          @@ plainto_tsquery('english', query_text)
    ORDER BY text_rank DESC
    LIMIT match_limit;
END;
$$;

-- Grant execute permission
-- GRANT EXECUTE ON FUNCTION search_notes_fulltext TO authenticated;

-- ============================================================================
-- Verify function was created
-- ============================================================================
-- SELECT proname FROM pg_proc WHERE proname = 'search_notes_fulltext';
