-- Cleans up notes stuck in 'incomplete' status where the upload pipeline
-- never completed. Run this once in the Supabase SQL editor.

-- 1. Mark as 'active' any incomplete notes that actually have content
--    (pipeline completed the content steps but never finalized status)
UPDATE public.notes
SET status = 'active', updated_at = NOW()
WHERE status = 'incomplete'
  AND content_markdown IS NOT NULL
  AND LENGTH(TRIM(content_markdown)) > 0;

-- 2. Mark as 'deleted' any incomplete notes with no content
--    (pure placeholder rows where upload died early)
UPDATE public.notes
SET status = 'deleted', updated_at = NOW()
WHERE status = 'incomplete'
  AND (content_markdown IS NULL OR LENGTH(TRIM(content_markdown)) = 0);

-- Verify: should return 0 rows after running
SELECT id, title, status, created_at
FROM public.notes
WHERE status = 'incomplete'
ORDER BY created_at DESC;
