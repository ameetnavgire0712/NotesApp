-- Migration: Add status='active' filter to all search RPC functions
-- This ensures incomplete/deleted notes are excluded from search results
-- Run this in Supabase SQL Editor

-- ============================================================================
-- 1. Update get_tags_with_counts to only count active notes
-- ============================================================================

DROP FUNCTION IF EXISTS get_tags_with_counts(text);

CREATE OR REPLACE FUNCTION get_tags_with_counts(
    filter_user_id text DEFAULT 'default_user'
)
RETURNS TABLE (
    tag text,
    count bigint
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        n.tag,
        COUNT(*) as count
    FROM notes n
    WHERE n.user_id = filter_user_id
    AND n.tag IS NOT NULL
    AND n.status = 'active'  -- Only count active notes
    GROUP BY n.tag
    ORDER BY count DESC;
$$;

-- ============================================================================
-- 2. Update search_notes_by_tag to only return active notes
-- ============================================================================

DROP FUNCTION IF EXISTS search_notes_by_tag(text, integer, text);

CREATE OR REPLACE FUNCTION search_notes_by_tag(
    search_tag text,
    match_count integer DEFAULT 10,
    filter_user_id text DEFAULT 'default_user'
)
RETURNS TABLE (
    id uuid,
    user_id text,
    title text,
    content_markdown text,
    tag text,
    file_type text,
    original_filename text,
    blob_url text,
    created_at timestamptz,
    updated_at timestamptz,
    metadata jsonb
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        n.id,
        n.user_id,
        n.title,
        n.content_markdown,
        n.tag,
        n.file_type,
        n.original_filename,
        n.blob_url,
        n.created_at,
        n.updated_at,
        n.metadata
    FROM notes n
    WHERE n.user_id = filter_user_id
    AND n.tag = search_tag
    AND n.status = 'active'  -- Only return active notes
    ORDER BY n.created_at DESC
    LIMIT match_count;
$$;

-- ============================================================================
-- 3. Update hybrid_search_notes to only search active notes
-- ============================================================================

DROP FUNCTION IF EXISTS hybrid_search_notes(vector(1536), text, integer, text, text, float, float);

CREATE OR REPLACE FUNCTION hybrid_search_notes(
    query_embedding vector(1536),
    query_text text,
    match_count integer DEFAULT 10,
    filter_user_id text DEFAULT 'default_user',
    filter_tag text DEFAULT NULL,
    vector_weight float DEFAULT 0.7,
    text_weight float DEFAULT 0.3
)
RETURNS TABLE (
    id uuid,
    user_id text,
    title text,
    content_markdown text,
    tag text,
    file_type text,
    original_filename text,
    blob_url text,
    created_at timestamptz,
    updated_at timestamptz,
    metadata jsonb,
    vector_similarity float,
    text_rank float,
    combined_score float
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH vector_search AS (
        SELECT 
            n.id,
            1 - (n.embedding <=> query_embedding) as similarity
        FROM notes n
        WHERE n.user_id = filter_user_id
        AND (filter_tag IS NULL OR n.tag = filter_tag)
        AND n.status = 'active'  -- Only search active notes
        ORDER BY n.embedding <=> query_embedding
        LIMIT match_count * 2
    ),
    text_search AS (
        SELECT 
            n.id,
            ts_rank_cd(n.content_tsv, plainto_tsquery('english', query_text)) as rank
        FROM notes n
        WHERE n.user_id = filter_user_id
        AND (filter_tag IS NULL OR n.tag = filter_tag)
        AND n.status = 'active'  -- Only search active notes
        AND n.content_tsv @@ plainto_tsquery('english', query_text)
    )
    SELECT 
        n.id,
        n.user_id,
        n.title,
        n.content_markdown,
        n.tag,
        n.file_type,
        n.original_filename,
        n.blob_url,
        n.created_at,
        n.updated_at,
        n.metadata,
        COALESCE(vs.similarity, 0)::float as vector_similarity,
        COALESCE(ts.rank, 0)::float as text_rank,
        (
            COALESCE(vs.similarity, 0) * vector_weight + 
            COALESCE(ts.rank, 0) * text_weight
        )::float as combined_score
    FROM notes n
    LEFT JOIN vector_search vs ON n.id = vs.id
    LEFT JOIN text_search ts ON n.id = ts.id
    WHERE n.user_id = filter_user_id
    AND (filter_tag IS NULL OR n.tag = filter_tag)
    AND n.status = 'active'  -- Only return active notes
    AND (vs.id IS NOT NULL OR ts.id IS NOT NULL)
    ORDER BY combined_score DESC
    LIMIT match_count;
END;
$$;

-- ============================================================================
-- 4. Update search_notes_fulltext to only search active notes
-- ============================================================================

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
      AND n.status = 'active'  -- Only search active notes
      AND to_tsvector('english', COALESCE(n.title, '') || ' ' || COALESCE(n.content_markdown, ''))
          @@ plainto_tsquery('english', query_text)
    ORDER BY text_rank DESC
    LIMIT match_limit;
END;
$$;

-- ============================================================================
-- 5. Update search_chunks_with_context to only search active notes
-- ============================================================================

DROP FUNCTION IF EXISTS search_chunks_with_context(vector(1536), integer, text);

CREATE OR REPLACE FUNCTION search_chunks_with_context(
    query_embedding vector(1536),
    match_count integer DEFAULT 10,
    filter_user_id text DEFAULT 'default_user'
)
RETURNS TABLE (
    chunk_id uuid,
    chunk_index integer,
    chunk_content text,
    chunk_similarity float,
    note_id uuid,
    note_title text,
    note_tag text,
    note_blob_url text,
    note_file_type text,
    note_content_markdown text
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        c.id as chunk_id,
        c.chunk_index,
        c.content as chunk_content,
        (1 - (c.embedding <=> query_embedding))::float as chunk_similarity,
        n.id as note_id,
        n.title as note_title,
        n.tag as note_tag,
        n.blob_url as note_blob_url,
        n.file_type as note_file_type,
        n.content_markdown as note_content_markdown
    FROM note_chunks c
    JOIN notes n ON c.note_id = n.id
    WHERE n.user_id = filter_user_id
    AND n.status = 'active'  -- Only search active notes
    ORDER BY c.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

-- ============================================================================
-- Add index on status column for faster filtering
-- ============================================================================

CREATE INDEX IF NOT EXISTS notes_status_idx ON notes (status) WHERE status = 'active';

-- Composite index for common query pattern
CREATE INDEX IF NOT EXISTS notes_user_status_idx ON notes (user_id, status) WHERE status = 'active';

-- ============================================================================
-- Verification queries (uncomment to test)
-- ============================================================================
-- SELECT COUNT(*) FROM notes WHERE status = 'active';
-- SELECT COUNT(*) FROM notes WHERE status != 'active' OR status IS NULL;
-- SELECT * FROM get_tags_with_counts('default_user');
