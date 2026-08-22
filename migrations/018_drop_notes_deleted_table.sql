-- Migration: Drop notes_deleted table
-- We're no longer archiving deleted notes - hard delete only
-- Date: 2026-04-14

-- Drop the indexes first
DROP INDEX IF EXISTS idx_notes_deleted_user_id;
DROP INDEX IF EXISTS idx_notes_deleted_original_note_id;
DROP INDEX IF EXISTS idx_notes_deleted_deleted_at;

-- Drop the table
DROP TABLE IF EXISTS notes_deleted;
