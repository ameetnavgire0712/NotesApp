-- Migration 002: Add HNSW indexes and hybrid search function for Phase 2 RAG
-- Run this in Supabase SQL Editor

-- ============================================================================
-- 1. HNSW INDEXES for faster vector similarity search
-- ============================================================================

-- Drop existing indexes if any (for re-running migration)
DROP INDEX IF EXISTS notes_embedding_hnsw_idx;
DROP INDEX IF EXISTS note_chunks_embedding_hnsw_idx;

-- HNSW index on notes table for document-level search
-- m=16: number of bi-directional links (default 16, good for recall)
-- ef_construction=64: size of dynamic candidate list during build
CREATE INDEX notes_embedding_hnsw_idx ON notes 
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- HNSW index on note_chunks table for chunk-level search
CREATE INDEX note_chunks_embedding_hnsw_idx ON note_chunks 
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- ============================================================================
-- 2. Full-text search indexes using GIN
-- ============================================================================

-- Add tsvector column for full-text search on notes
ALTER TABLE notes ADD COLUMN IF NOT EXISTS content_tsv tsvector
GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(content_markdown, ''))) STORED;

-- GIN index for full-text search
CREATE INDEX IF NOT EXISTS notes_content_tsv_idx ON notes USING GIN (content_tsv);

-- Index on tag for fast tag filtering
CREATE INDEX IF NOT EXISTS notes_tag_idx ON notes (tag) WHERE tag IS NOT NULL;

-- ============================================================================
-- 3. Hybrid search RPC function (combines vector + full-text)
-- ============================================================================

-- Drop existing function if any
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
        ORDER BY n.embedding <=> query_embedding
        LIMIT match_count * 2  -- Get more candidates for re-ranking
    ),
    text_search AS (
        SELECT 
            n.id,
            ts_rank_cd(n.content_tsv, plainto_tsquery('english', query_text)) as rank
        FROM notes n
        WHERE n.user_id = filter_user_id
        AND (filter_tag IS NULL OR n.tag = filter_tag)
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
    AND (vs.id IS NOT NULL OR ts.id IS NOT NULL)
    ORDER BY combined_score DESC
    LIMIT match_count;
END;
$$;

-- ============================================================================
-- 4. Get all unique tags with counts (for fuzzy matching)
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
    GROUP BY n.tag
    ORDER BY count DESC;
$$;

-- ============================================================================
-- 5. Search notes by tag with similarity threshold
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
    ORDER BY n.created_at DESC
    LIMIT match_count;
$$;

-- ============================================================================
-- 6. Enhanced chunk search with parent note info
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
    ORDER BY c.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

-- Grant permissions (adjust role name as needed)
-- GRANT EXECUTE ON FUNCTION hybrid_search_notes TO authenticated;
-- GRANT EXECUTE ON FUNCTION get_tags_with_counts TO authenticated;
-- GRANT EXECUTE ON FUNCTION search_notes_by_tag TO authenticated;
-- GRANT EXECUTE ON FUNCTION search_chunks_with_context TO authenticated;
