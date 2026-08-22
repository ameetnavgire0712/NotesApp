-- ============================================================================
-- Migration: extend notes.file_type CHECK constraint for social-share sources
-- ============================================================================
-- The /api/v1/upload/shared-url endpoint persists notes with file_type set to
-- the platform name (e.g. 'youtube') so search and filters can group results
-- by source. The CHECK constraint must be widened before the worker is
-- allowed to insert such rows.
--
-- v1 scope: 'youtube'.
-- v2: + 'instagram'.
-- v3: + 'linkedin'.
-- v4: + 'twitter', 'reddit', 'facebook'.
--
-- Safe to re-run.

ALTER TABLE public.notes DROP CONSTRAINT IF EXISTS notes_file_type_check;
ALTER TABLE public.notes ADD CONSTRAINT notes_file_type_check
  CHECK (file_type IN (
    'uploaded_file',
    'screenshot',
    'quick_note',
    'image',
    'webpage',
    'youtube',
    'instagram',
    'facebook',
    'linkedin',
    'twitter',
    'reddit'
    -- future: 'pinterest', 'tiktok'
  ));

-- Sanity check
-- SELECT file_type, COUNT(*) FROM public.notes GROUP BY file_type ORDER BY 1;
