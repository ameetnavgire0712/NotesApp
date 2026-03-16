-- Migration: Enable Row Level Security on all user tables
-- Run this migration using: psql or Supabase SQL editor
-- IMPORTANT: Run AFTER 001_user_api_keys.sql

-- ============================================================================
-- NOTES TABLE
-- ============================================================================
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;

-- Users can only see their own notes
CREATE POLICY "Users can view own notes" ON notes
    FOR SELECT
    USING (auth.uid()::text = user_id);

-- Users can create notes for themselves
CREATE POLICY "Users can create own notes" ON notes
    FOR INSERT
    WITH CHECK (auth.uid()::text = user_id);

-- Users can update their own notes
CREATE POLICY "Users can update own notes" ON notes
    FOR UPDATE
    USING (auth.uid()::text = user_id);

-- Users can delete their own notes
CREATE POLICY "Users can delete own notes" ON notes
    FOR DELETE
    USING (auth.uid()::text = user_id);

-- ============================================================================
-- NOTE_CHUNKS TABLE
-- ============================================================================
ALTER TABLE note_chunks ENABLE ROW LEVEL SECURITY;

-- Users can view chunks of their own notes (via join to notes table)
CREATE POLICY "Users can view own note chunks" ON note_chunks
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM notes 
            WHERE notes.id = note_chunks.note_id 
            AND notes.user_id = auth.uid()::text
        )
    );

-- Users can create chunks for their own notes
CREATE POLICY "Users can create own note chunks" ON note_chunks
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM notes 
            WHERE notes.id = note_chunks.note_id 
            AND notes.user_id = auth.uid()::text
        )
    );

-- Users can update chunks of their own notes
CREATE POLICY "Users can update own note chunks" ON note_chunks
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM notes 
            WHERE notes.id = note_chunks.note_id 
            AND notes.user_id = auth.uid()::text
        )
    );

-- Users can delete chunks of their own notes
CREATE POLICY "Users can delete own note chunks" ON note_chunks
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM notes 
            WHERE notes.id = note_chunks.note_id 
            AND notes.user_id = auth.uid()::text
        )
    );

-- ============================================================================
-- USER_ACTIVITIES TABLE
-- ============================================================================
ALTER TABLE user_activities ENABLE ROW LEVEL SECURITY;

-- Users can view their own activities
CREATE POLICY "Users can view own activities" ON user_activities
    FOR SELECT
    USING (auth.uid()::text = user_id);

-- Users can create their own activity logs
CREATE POLICY "Users can create own activities" ON user_activities
    FOR INSERT
    WITH CHECK (auth.uid()::text = user_id);

-- ============================================================================
-- RAG_EVALUATION_LOGS TABLE (if exists)
-- ============================================================================
DO $$ 
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'rag_evaluation_logs') THEN
        EXECUTE 'ALTER TABLE rag_evaluation_logs ENABLE ROW LEVEL SECURITY';
        
        -- Users can view their own evaluation logs
        EXECUTE '
            CREATE POLICY "Users can view own evaluation logs" ON rag_evaluation_logs
            FOR SELECT
            USING (auth.uid()::text = user_id)
        ';
        
        -- Users can create their own evaluation logs
        EXECUTE '
            CREATE POLICY "Users can create own evaluation logs" ON rag_evaluation_logs
            FOR INSERT
            WITH CHECK (auth.uid()::text = user_id)
        ';
    END IF;
END $$;

-- ============================================================================
-- ERROR_LOGS TABLE
-- ============================================================================
DO $$ 
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'error_logs') THEN
        EXECUTE 'ALTER TABLE error_logs ENABLE ROW LEVEL SECURITY';
        
        -- Only admins can view error logs (via service role)
        -- No policies = only service_role can access
    END IF;
END $$;

-- ============================================================================
-- SERVICE ROLE ACCESS (for backend operations)
-- ============================================================================
-- The service_role bypasses RLS, so our backend can still access all data
-- when authenticated with the service key. This is important for:
-- 1. API key validation (lookup by hashed key)
-- 2. Admin operations
-- 3. Background jobs

-- Grant service role access to all tables
GRANT ALL ON notes TO service_role;
GRANT ALL ON note_chunks TO service_role;
GRANT ALL ON user_activities TO service_role;
GRANT ALL ON user_api_keys TO service_role;

-- ============================================================================
-- NOTES FOR DEVELOPERS
-- ============================================================================
-- 
-- RLS policies use auth.uid() which comes from the JWT token.
-- Our backend uses the service_key which bypasses RLS.
-- 
-- For the backend to enforce user isolation, we:
-- 1. Extract user_id from JWT or API key in our auth middleware
-- 2. Pass user_id to all database queries as a filter
-- 3. RLS provides a second layer of protection if we ever switch to anon key
--
-- The service_role key should NEVER be exposed to the client!
