-- Backfill semantic file_type values on legacy notes that all landed as
-- 'uploaded_file'. Run once in the Supabase SQL editor after deploying the
-- updated upload pipeline.
--
-- New buckets:
--   'webpage'  - any uploaded_file with a metadata.source_url, or a .html/.htm filename
--   'image'    - any uploaded_file whose original_filename is a known image extension
--   'uploaded_file' (unchanged) - residual files (pdf, docx, csv, txt, ...)
--   'screenshot' / 'quick_note' - never touched
--
-- Safe to re-run. WHERE clauses guarantee idempotency.

-- 0) Expand the CHECK constraint to allow the new file_type values.
--    The previous constraint only allowed ('uploaded_file','screenshot','quick_note').
ALTER TABLE public.notes DROP CONSTRAINT IF EXISTS notes_file_type_check;
ALTER TABLE public.notes ADD CONSTRAINT notes_file_type_check
  CHECK (file_type IN ('uploaded_file', 'screenshot', 'quick_note', 'image', 'webpage'));

-- 1) Webpages: source_url present OR .html/.htm filename
UPDATE public.notes
SET file_type = 'webpage', updated_at = NOW()
WHERE file_type = 'uploaded_file'
  AND (
    (metadata ->> 'source_url') IS NOT NULL
    OR LOWER(original_filename) LIKE '%.html'
    OR LOWER(original_filename) LIKE '%.htm'
  );

-- 2) Images: extension-based detection
UPDATE public.notes
SET file_type = 'image', updated_at = NOW()
WHERE file_type = 'uploaded_file'
  AND (
    LOWER(original_filename) LIKE '%.jpg'
    OR LOWER(original_filename) LIKE '%.jpeg'
    OR LOWER(original_filename) LIKE '%.png'
    OR LOWER(original_filename) LIKE '%.gif'
    OR LOWER(original_filename) LIKE '%.webp'
    OR LOWER(original_filename) LIKE '%.heic'
    OR LOWER(original_filename) LIKE '%.bmp'
    OR LOWER(original_filename) LIKE '%.svg'
  );

-- Verify the new distribution
SELECT file_type, COUNT(*) AS n
FROM public.notes
WHERE status <> 'deleted'
GROUP BY file_type
ORDER BY n DESC;
