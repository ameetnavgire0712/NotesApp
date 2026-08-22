-- Migration 012: Fix fulltext search for alphanumeric tokens like "B12"
-- The English text search config discards alphanumeric tokens like "B12"
-- producing an empty tsquery. This fix falls back to 'simple' config
-- which preserves all tokens without stemming or stop-word filtering.
-- Run this in Supabase SQL Editor

DROP FUNCTION IF EXISTS search_notes_fulltext(text, text, text, int);

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
            n.id,
            n.title,
            n.tag,
            ts_rank_cd(
                to_tsvector('simple', COALESCE(n.title, '') || ' ' || COALESCE(n.content_markdown, '')),
                simple_query
            )::float as text_rank
        FROM notes n
        WHERE n.user_id = match_user_id
          AND (match_tag IS NULL OR n.tag = match_tag)
          AND n.status = 'active'
          AND to_tsvector('simple', COALESCE(n.title, '') || ' ' || COALESCE(n.content_markdown, ''))
              @@ simple_query
        ORDER BY text_rank DESC
        LIMIT match_limit;
    ELSE
        RETURN QUERY
        SELECT 
            n.id,
            n.title,
            n.tag,
            ts_rank_cd(
                to_tsvector('english', COALESCE(n.title, '') || ' ' || COALESCE(n.content_markdown, '')),
                english_query
            )::float as text_rank
        FROM notes n
        WHERE n.user_id = match_user_id
          AND (match_tag IS NULL OR n.tag = match_tag)
          AND n.status = 'active'
          AND to_tsvector('english', COALESCE(n.title, '') || ' ' || COALESCE(n.content_markdown, ''))
              @@ english_query
        ORDER BY text_rank DESC
        LIMIT match_limit;
    END IF;
END;
$$;
