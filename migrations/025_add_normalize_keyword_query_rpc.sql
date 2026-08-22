-- Migration 025: Add RPC to normalize keyword query even when no matches are returned
-- This allows Activity Logs to display true Postgres normalization regardless of hit count.

CREATE OR REPLACE FUNCTION public.normalize_keyword_query(query_text text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    english_query tsquery;
    simple_query tsquery;
BEGIN
    english_query := plainto_tsquery('english', query_text);

    IF english_query::text = '' THEN
        simple_query := plainto_tsquery('simple', query_text);
        RETURN simple_query::text;
    END IF;

    RETURN english_query::text;
END;
$$;

GRANT EXECUTE ON FUNCTION public.normalize_keyword_query(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_keyword_query(text) TO service_role;
