-- Migration: Change embedding dimensions from 1536 (OpenAI) to 768 (BGE)
-- 
-- Run this in Supabase SQL Editor BEFORE running the Python migration script.
-- 
-- WARNING: This will invalidate all existing embeddings!
-- Run the Python migration script immediately after to re-embed all documents.

-- Step 1: Drop existing indexes (they reference the old dimension)
DROP INDEX IF EXISTS notes_embedding_idx;
DROP INDEX IF EXISTS note_chunks_embedding_idx;

-- Step 2: Clear existing embeddings (pgvector can't convert dimensions)
UPDATE notes SET embedding = NULL;
UPDATE note_chunks SET embedding = NULL;

-- Step 3: Alter the embedding columns to new dimensions
ALTER TABLE notes 
    ALTER COLUMN embedding TYPE vector(768);

ALTER TABLE note_chunks 
    ALTER COLUMN embedding TYPE vector(768);

-- Step 3: Recreate the indexes with new dimensions
-- Using HNSW index for better performance
CREATE INDEX notes_embedding_idx ON notes 
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

CREATE INDEX note_chunks_embedding_idx ON note_chunks 
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Step 4: Update the match_notes function to use correct dimensions
CREATE OR REPLACE FUNCTION match_notes(
    query_embedding vector(768),
    match_user_id text,
    match_tag text DEFAULT NULL,
    match_limit int DEFAULT 10
)
RETURNS TABLE (
    id uuid,
    title text,
    content_markdown text,
    tag text,
    file_type text,
    blob_url text,
    original_filename text,
    created_at timestamptz,
    similarity float
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        n.id,
        n.title,
        n.content_markdown,
        n.tag,
        n.file_type,
        n.blob_url,
        n.original_filename,
        n.created_at,
        1 - (n.embedding <=> query_embedding) as similarity
    FROM notes n
    WHERE n.user_id = match_user_id
      AND (match_tag IS NULL OR n.tag = match_tag)
      AND n.embedding IS NOT NULL
    ORDER BY n.embedding <=> query_embedding
    LIMIT match_limit;
END;
$$;

-- Step 5: Update hybrid_search_notes function
CREATE OR REPLACE FUNCTION hybrid_search_notes(
    query_embedding vector(768),
    query_text text,
    match_user_id text,
    match_tag text DEFAULT NULL,
    match_limit int DEFAULT 10,
    vector_weight float DEFAULT 0.7,
    text_weight float DEFAULT 0.3
)
RETURNS TABLE (
    id uuid,
    title text,
    content_markdown text,
    tag text,
    file_type text,
    blob_url text,
    original_filename text,
    created_at timestamptz,
    vector_similarity float,
    text_rank float,
    combined_score float
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        n.id,
        n.title,
        n.content_markdown,
        n.tag,
        n.file_type,
        n.blob_url,
        n.original_filename,
        n.created_at,
        (1 - (n.embedding <=> query_embedding))::float as vector_similarity,
        COALESCE(ts_rank(
            to_tsvector('english', COALESCE(n.title, '') || ' ' || COALESCE(n.content_markdown, '')),
            plainto_tsquery('english', query_text)
        ), 0)::float as text_rank,
        (
            vector_weight * (1 - (n.embedding <=> query_embedding)) +
            text_weight * COALESCE(ts_rank(
                to_tsvector('english', COALESCE(n.title, '') || ' ' || COALESCE(n.content_markdown, '')),
                plainto_tsquery('english', query_text)
            ), 0)
        )::float as combined_score
    FROM notes n
    WHERE n.user_id = match_user_id
      AND (match_tag IS NULL OR n.tag = match_tag)
      AND n.embedding IS NOT NULL
    ORDER BY combined_score DESC
    LIMIT match_limit;
END;
$$;

-- Step 6: Update search_chunks_with_context function
CREATE OR REPLACE FUNCTION search_chunks_with_context(
    query_embedding vector(768),
    match_user_id text,
    match_tag text DEFAULT NULL,
    match_limit int DEFAULT 10
)
RETURNS TABLE (
    chunk_id uuid,
    note_id uuid,
    chunk_index int,
    content text,
    title text,
    tag text,
    file_type text,
    blob_url text,
    similarity float
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        nc.id as chunk_id,
        nc.note_id,
        nc.chunk_index,
        nc.content,
        n.title,
        n.tag,
        n.file_type,
        n.blob_url,
        (1 - (nc.embedding <=> query_embedding))::float as similarity
    FROM note_chunks nc
    JOIN notes n ON nc.note_id = n.id
    WHERE n.user_id = match_user_id
      AND (match_tag IS NULL OR n.tag = match_tag)
      AND nc.embedding IS NOT NULL
    ORDER BY nc.embedding <=> query_embedding
    LIMIT match_limit;
END;
$$;

-- Notify PostgREST to reload schema
NOTIFY pgrst, 'reload schema';

-- Done! Now run the Python migration script:
-- python scripts/migrate_to_local_embeddings.py
