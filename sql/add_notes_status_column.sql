-- =============================================================================
-- Migration: Add status column to notes table
-- This allows marking notes as incomplete when upload pipeline fails
-- =============================================================================

-- Add status column with default 'active' for existing notes
ALTER TABLE notes ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'active';

-- Add index for filtering by status
CREATE INDEX IF NOT EXISTS idx_notes_status ON notes(status);

-- Composite index for common query pattern (user_id + status)
CREATE INDEX IF NOT EXISTS idx_notes_user_status ON notes(user_id, status);

-- Update existing notes without blob_url to 'incomplete' 
-- (except quick_notes which intentionally have no file)
UPDATE notes 
SET status = 'incomplete' 
WHERE blob_url IS NULL 
  AND file_type NOT IN ('quick_note')
  AND status = 'active';

-- Add comment
COMMENT ON COLUMN notes.status IS 'Note status: active (searchable), incomplete (upload failed), deleted (soft-deleted)';

-- Verify the update
SELECT 
  status, 
  COUNT(*) as count 
FROM notes 
GROUP BY status 
ORDER BY status;
