-- =====================================================================
-- 048_notes_listing_perf.sql
-- Performance fixes for the My Snaps listing endpoint.
--
-- Two problems being fixed:
--
-- 1) Tags view fetched up to 10,000 rows on every page load, sorted
--    them in the worker by lower(tag), then sliced. The reason was that
--    Supabase's REST `order=` parameter cannot express LOWER(tag), so
--    the worker had to do it. This migration adds an RPC that does the
--    sort + paginate inside Postgres in one round trip.
--
-- 2) The existing index notes_user_id_created_idx covers (user_id,
--    created_at) but not the status filter. Every listing query also
--    filters status IN ('active','incomplete'), so Postgres has to
--    fetch each candidate row and recheck status. Add a partial index
--    that only contains the rows the listing query actually wants.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Partial index for the default (date-sorted) listing path.
-- Date and Type views both go through this query.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_notes_user_active_created
  ON public.notes (user_id, created_at DESC)
  WHERE status IN ('active', 'incomplete');

-- ---------------------------------------------------------------------
-- Partial index for the tag-sorted listing path.
-- Indexed expression matches the RPC's ORDER BY exactly so Postgres
-- can satisfy ORDER BY + LIMIT directly from the index.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_notes_user_active_tag_lower_created
  ON public.notes (user_id, (lower(coalesce(tag, ''))), created_at DESC)
  WHERE status IN ('active', 'incomplete');

-- ---------------------------------------------------------------------
-- RPC: list notes sorted case-insensitively by tag, paginated in DB.
--
-- Returns SETOF notes so PostgREST callers can use ?select=... to
-- pick the columns they need (matches handleListNotes' baseSelectFields
-- and fallbackSelectFields contracts).
--
-- p_limit is hard-clamped to [0, 200] so a misuse cannot dump the table.
-- p_offset is clamped to >= 0.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_notes_sorted_by_tag(
  p_user_id text,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS SETOF public.notes
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT *
  FROM public.notes
  WHERE user_id = p_user_id
    AND status IN ('active', 'incomplete')
  ORDER BY lower(coalesce(tag, '')) ASC, created_at DESC
  LIMIT GREATEST(LEAST(coalesce(p_limit, 20), 200), 0)
  OFFSET GREATEST(coalesce(p_offset, 0), 0);
$$;

GRANT EXECUTE ON FUNCTION public.list_notes_sorted_by_tag(text, integer, integer)
  TO anon, authenticated, service_role;
