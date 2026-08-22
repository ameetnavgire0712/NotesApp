-- Migration 024: Add normalized_query output to search_chunks_fulltext RPC
-- Exposes the tsquery text after Postgres parsing/fallback so activity logs can show it.

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
    match_source text,
    normalized_query text
)
LANGUAGE plpgsql
AS $$
DECLARE
    english_query tsquery;
    simple_query tsquery;
    use_simple boolean := false;
    normalized_query_text text;
BEGIN
    english_query := plainto_tsquery('english', query_text);

    IF english_query::text = '' THEN
        simple_query := plainto_tsquery('simple', query_text);
        use_simple := true;
        normalized_query_text := simple_query::text;
    ELSE
        normalized_query_text := english_query::text;
    END IF;

    IF use_simple THEN
        RETURN QUERY
        WITH chunk_matches AS (
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
            SELECT
                n.id as note_id,
                -1 as chunk_index,
                n.title as chunk_content,
                ts_rank_cd(to_tsvector('simple', COALESCE(n.title, '')), simple_query)::float * 1.5 as text_rank,
                'title'::text as match_source
            FROM notes n
            WHERE n.user_id = match_user_id
              AND (match_tag IS NULL OR n.tag = match_tag)
              AND to_tsvector('simple', COALESCE(n.title, '')) @@ simple_query
        ),
        description_matches AS (
            SELECT
                n.id as note_id,
                -2 as chunk_index,
                n.description as chunk_content,
                ts_rank_cd(to_tsvector('simple', COALESCE(n.description, '')), simple_query)::float * 1.2 as text_rank,
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
            am.match_source,
            normalized_query_text
        FROM all_matches am
        ORDER BY am.text_rank DESC
        LIMIT match_limit;
    ELSE
        RETURN QUERY
        WITH chunk_matches AS (
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
            SELECT
                n.id as note_id,
                -1 as chunk_index,
                n.title as chunk_content,
                ts_rank_cd(to_tsvector('english', COALESCE(n.title, '')), english_query)::float * 1.5 as text_rank,
                'title'::text as match_source
            FROM notes n
            WHERE n.user_id = match_user_id
              AND (match_tag IS NULL OR n.tag = match_tag)
              AND to_tsvector('english', COALESCE(n.title, '')) @@ english_query
        ),
        description_matches AS (
            SELECT
                n.id as note_id,
                -2 as chunk_index,
                n.description as chunk_content,
                ts_rank_cd(to_tsvector('english', COALESCE(n.description, '')), english_query)::float * 1.2 as text_rank,
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
            am.match_source,
            normalized_query_text
        FROM all_matches am
        ORDER BY am.text_rank DESC
        LIMIT match_limit;
    END IF;
END;
$$;
