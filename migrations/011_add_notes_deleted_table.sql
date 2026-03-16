-- Migration: Create notes_deleted table for soft deletes
-- This table mirrors the notes table schema but stores deleted notes
-- Deleted notes can be restored if needed, and blob storage is preserved

-- Create notes_deleted table with same schema as notes
CREATE TABLE IF NOT EXISTS notes_deleted (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    original_note_id UUID NOT NULL,  -- The original note ID before deletion
    user_id TEXT NOT NULL,
    title TEXT,
    content_markdown TEXT,
    tag TEXT DEFAULT 'General',
    file_type TEXT NOT NULL CHECK (file_type IN ('screenshot', 'quick_note', 'uploaded_file')),
    original_filename TEXT,
    blob_url TEXT,
    embedding vector(1024),  -- Match the notes table embedding dimension
    status TEXT DEFAULT 'deleted',
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    deleted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for common queries
CREATE INDEX IF NOT EXISTS idx_notes_deleted_user_id ON notes_deleted(user_id);
CREATE INDEX IF NOT EXISTS idx_notes_deleted_original_note_id ON notes_deleted(original_note_id);
CREATE INDEX IF NOT EXISTS idx_notes_deleted_deleted_at ON notes_deleted(deleted_at DESC);

-- Enable RLS
ALTER TABLE notes_deleted ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Users can only view their own deleted notes
CREATE POLICY "Users can view own deleted notes"
    ON notes_deleted
    FOR SELECT
    USING (auth.uid()::text = user_id);

-- RLS Policy: Users can insert their own deleted notes (via service key in worker)
CREATE POLICY "Service can insert deleted notes"
    ON notes_deleted
    FOR INSERT
    WITH CHECK (true);  -- Worker uses service key, bypasses RLS

-- RLS Policy: Users can delete their own deleted notes (permanent delete)
CREATE POLICY "Users can delete own deleted notes"
    ON notes_deleted
    FOR DELETE
    USING (auth.uid()::text = user_id);

-- Comment on table
COMMENT ON TABLE notes_deleted IS 'Soft-deleted notes for recovery. Blob storage is preserved.';
COMMENT ON COLUMN notes_deleted.original_note_id IS 'The UUID of the note before it was deleted from notes table';
COMMENT ON COLUMN notes_deleted.deleted_at IS 'Timestamp when the note was deleted';
