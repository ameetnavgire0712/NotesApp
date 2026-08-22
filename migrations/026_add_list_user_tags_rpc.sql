-- =====================================================================
-- 026_add_list_user_tags_rpc.sql
-- Server-side DISTINCT tag query for the home-screen tag chips.
--
-- Why this exists:
-- The old endpoint (`GET /api/v1/notes/tags/all`) was implemented as
-- `SELECT tag FROM notes WHERE user_id = ? AND status = 'active'` and
-- then deduped in worker JS. For users with hundreds/thousands of
-- active notes that meant pulling the entire tag column over the
-- network every time the home screen mounted -- often hundreds of KB
-- of JSON for what should be a handful of distinct strings.
--
-- This function returns just the distinct, non-null, non-empty tag
-- values for a given user in a single round trip. PostgREST exposes
-- it at `POST /rest/v1/rpc/list_user_tags`.
-- =====================================================================

-- NOTE: notes.user_id is stored as text (auth provider's subject string),
-- not uuid, so the parameter type must match or PostgREST will fail with
-- "operator does not exist: text = uuid".
CREATE OR REPLACE FUNCTION public.list_user_tags(p_user_id text)
RETURNS TABLE (tag text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT n.tag
  FROM public.notes n
  WHERE n.user_id = p_user_id
    AND n.status = 'active'
    AND n.tag IS NOT NULL
    AND length(trim(n.tag)) > 0
  ORDER BY n.tag;
$$;

-- Backing index so the DISTINCT scan stays cheap as note counts grow.
-- Partial index keeps it tiny: only active rows with a non-null tag.
CREATE INDEX IF NOT EXISTS idx_notes_user_active_tag
  ON public.notes (user_id, tag)
  WHERE status = 'active' AND tag IS NOT NULL;

GRANT EXECUTE ON FUNCTION public.list_user_tags(text) TO anon, authenticated, service_role;
