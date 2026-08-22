-- 049_drop_ig_enrich_queue.sql
-- ============================================================================
-- Drop the ig_enrich_jobs queue and its RPCs.
--
-- The Instagram Apify enrichment pipeline was retired:
--   * Live IG enrichment now uses fetchInstagramLegalEnrichment (Meta oEmbed).
--   * The every-minute drainer cron + ig-enrich-queue.ts module were deleted.
--   * APIFY_TOKEN secret usage was removed from the Worker.
--
-- This migration removes the now-orphan database objects. Apply via the
-- Supabase SQL Editor.
-- ============================================================================

DROP FUNCTION IF EXISTS public.sweep_stale_ig_enrich_jobs() CASCADE;
DROP FUNCTION IF EXISTS public.claim_ig_enrich_jobs(integer) CASCADE;

DROP TABLE IF EXISTS public.ig_enrich_jobs CASCADE;
