-- ============================================================================
-- Migration 053: Phase 2 — Append-only audit_log
-- ============================================================================
--
-- Purpose:
--   A single, immutable timeline of security-meaningful events. Helps debug
--   weird user reports ("why was my snap deleted?"), and gives us a real
--   forensic trail if anything ever goes sideways.
--
-- Design choices:
--   - One wide table, JSONB `details` column for event-specific payloads
--   - Append-only enforced by triggers (UPDATE / DELETE always raise)
--   - Owner can read their own entries via RLS; only service_role writes
--   - Indexed on (user_id, created_at DESC) for fast per-user lookup
--   - 90-day retention via a partial index that lets a future cron prune
--     old rows without a sequential scan; until then the table just grows.
--
-- Event types are loose strings (NOT an enum) so we can add new ones from
-- the Worker without a migration. Convention: `<resource>.<verb>`.
--   auth.login                — user logged in (incl. method)
--   auth.session_revoked      — sessions revoked from settings
--   auth.api_key_created      — new API key minted
--   auth.api_key_deleted      — API key deleted
--   note.delete               — note deleted
--   note.bulk_delete          — bulk delete from settings
--   group.invite_sent         — group invite sent
--   group.invite_accepted     — invite accepted
--   group.member_removed      — admin removed a member
--   account.export_started    — user requested data export
--   account.delete_started    — user requested account deletion
--   billing.upgrade           — paid plan started (DEV / Stripe webhook)
--
-- Verification (run in SQL Editor before + after applying):
--   SELECT n.nspname, c.relname, c.relrowsecurity AS rls,
--          (SELECT count(*) FROM pg_policies p WHERE p.schemaname=n.nspname
--             AND p.tablename=c.relname) AS policy_count
--     FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
--    WHERE c.relname='audit_log';
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Table
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_log (
    id            bigserial PRIMARY KEY,
    user_id       uuid,                     -- NULL for system events (cron, webhooks)
    actor_email   text,                     -- For human-readable audits; may be null
    event_type    text NOT NULL,            -- e.g. 'note.delete', 'auth.login'
    resource_type text,                     -- e.g. 'note','group','user','api_key'
    resource_id   text,                     -- string so it works for uuid + bigint ids
    ip_address    inet,                     -- captured from CF-Connecting-IP
    user_agent    text,
    request_id    text,                     -- request_id / correlation_id for joinability
    details       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT audit_log_event_type_nonempty CHECK (length(trim(event_type)) > 0)
);

COMMENT ON TABLE  public.audit_log IS
    'Append-only security/audit timeline. Writes go through service_role only; UPDATE/DELETE blocked by triggers.';
COMMENT ON COLUMN public.audit_log.event_type IS
    'Convention: <resource>.<verb> e.g. note.delete, auth.login, group.invite_sent.';
COMMENT ON COLUMN public.audit_log.details IS
    'Free-form JSON payload — keep payload PII-light (no snap content, no full emails of others, no tokens).';

-- ----------------------------------------------------------------------------
-- 2. Indexes
-- ----------------------------------------------------------------------------
-- Fast per-user lookup ("show me my audit history") and per-user-by-event.
CREATE INDEX IF NOT EXISTS idx_audit_log_user_created
    ON public.audit_log (user_id, created_at DESC)
    WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_audit_log_event_created
    ON public.audit_log (event_type, created_at DESC);

-- Used by the future retention cron:
--   DELETE FROM audit_log WHERE created_at < now() - interval '90 days';
CREATE INDEX IF NOT EXISTS idx_audit_log_created
    ON public.audit_log (created_at);

-- ----------------------------------------------------------------------------
-- 3. Append-only enforcement (defense-in-depth)
-- ----------------------------------------------------------------------------
-- Even service_role accidentally calling UPDATE/DELETE is rejected. The only
-- legitimate cleanup path is the planned retention cron, which we'll add as
-- a SECURITY DEFINER function later (so it can bypass this).
CREATE OR REPLACE FUNCTION public.audit_log_no_modify()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only (got %)', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

DROP TRIGGER IF EXISTS audit_log_block_update ON public.audit_log;
CREATE TRIGGER audit_log_block_update
    BEFORE UPDATE ON public.audit_log
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_log_no_modify();

DROP TRIGGER IF EXISTS audit_log_block_delete ON public.audit_log;
CREATE TRIGGER audit_log_block_delete
    BEFORE DELETE ON public.audit_log
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_log_no_modify();

-- ----------------------------------------------------------------------------
-- 4. RLS — owner-read, service-only-write
-- ----------------------------------------------------------------------------
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "owner_read_audit_log" ON public.audit_log;
CREATE POLICY "owner_read_audit_log"
    ON public.audit_log
    FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);

-- Explicit service_role policy so postgrest exposes writes when called with
-- the service key. (service_role bypasses RLS by default, so this is mostly
-- documentation, but it makes intent obvious.)
DROP POLICY IF EXISTS "service_all_audit_log" ON public.audit_log;
CREATE POLICY "service_all_audit_log"
    ON public.audit_log
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- 5. Helper: log_audit() — convenience for SQL-side callers
--    Worker can also POST directly to /rest/v1/audit_log via PostgREST.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_audit(
    p_event_type    text,
    p_user_id       uuid    DEFAULT NULL,
    p_resource_type text    DEFAULT NULL,
    p_resource_id   text    DEFAULT NULL,
    p_actor_email   text    DEFAULT NULL,
    p_ip_address    inet    DEFAULT NULL,
    p_user_agent    text    DEFAULT NULL,
    p_request_id    text    DEFAULT NULL,
    p_details       jsonb   DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO public.audit_log (
        user_id, actor_email, event_type, resource_type, resource_id,
        ip_address, user_agent, request_id, details
    )
    VALUES (
        p_user_id, p_actor_email, p_event_type, p_resource_type, p_resource_id,
        p_ip_address, p_user_agent, p_request_id, COALESCE(p_details, '{}'::jsonb)
    )
    RETURNING id;
$$;

REVOKE ALL ON FUNCTION public.log_audit(text, uuid, text, text, text, inet, text, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.log_audit(text, uuid, text, text, text, inet, text, text, jsonb)
    TO service_role;

COMMIT;

-- After running:
--   SELECT id, event_type, user_id, created_at, details
--     FROM public.audit_log
--    ORDER BY id DESC
--    LIMIT 10;
-- ...should return 0 rows (table is empty until Worker starts writing).
