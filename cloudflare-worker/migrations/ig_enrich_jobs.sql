-- =====================================================================
-- ig_enrich_jobs : durable work queue for Apify-backed IG enrichment
-- =====================================================================
-- Lifecycle:
--   pending    -> claimed by processor
--   processing -> Apify call in flight
--   enriched   -> Apify returned item; downstream fan-out (Whisper/OCR)
--   failed     -> exhausted retries
-- Idempotency: (user_id, shortcode) unique while not failed/enriched
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.ig_enrich_jobs (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NULL,
  note_id       uuid        NULL,
  url           text        NOT NULL,
  shortcode     text        NOT NULL,
  status        text        NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','processing','enriched','failed')),
  attempts      integer     NOT NULL DEFAULT 0,
  apify_run_id  text        NULL,
  result_json   jsonb       NULL,
  error         text        NULL,
  enqueued_at   timestamptz NOT NULL DEFAULT now(),
  started_at    timestamptz NULL,
  finished_at   timestamptz NULL
);

CREATE INDEX IF NOT EXISTS idx_ig_enrich_pending
  ON public.ig_enrich_jobs (status, enqueued_at)
  WHERE status IN ('pending','processing');

CREATE INDEX IF NOT EXISTS idx_ig_enrich_shortcode
  ON public.ig_enrich_jobs (shortcode);

CREATE INDEX IF NOT EXISTS idx_ig_enrich_user
  ON public.ig_enrich_jobs (user_id, enqueued_at DESC);

-- Atomic claim function: returns up to `limit_n` pending rows and marks them
-- as 'processing' in a single statement. Uses SKIP LOCKED so concurrent
-- cron fires don't double-process.
CREATE OR REPLACE FUNCTION public.claim_ig_enrich_jobs(limit_n integer)
RETURNS SETOF public.ig_enrich_jobs
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  WITH picked AS (
    SELECT id
    FROM public.ig_enrich_jobs
    WHERE status = 'pending'
    ORDER BY enqueued_at
    LIMIT limit_n
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.ig_enrich_jobs j
     SET status     = 'processing',
         started_at = now(),
         attempts   = attempts + 1
    FROM picked
   WHERE j.id = picked.id
  RETURNING j.*;
END $$;

-- Crash-recovery sweeper: jobs stuck in 'processing' beyond 10 minutes
-- (worker died / cron killed) are returned to 'pending' for retry.
CREATE OR REPLACE FUNCTION public.sweep_stale_ig_enrich_jobs()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  swept integer;
BEGIN
  UPDATE public.ig_enrich_jobs
     SET status = 'pending'
   WHERE status = 'processing'
     AND started_at < now() - interval '10 minutes';
  GET DIAGNOSTICS swept = ROW_COUNT;
  RETURN swept;
END $$;
