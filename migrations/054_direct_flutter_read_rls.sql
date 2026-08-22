-- ============================================================================
-- Migration 054: RLS prerequisites for Flutter -> Supabase direct reads
-- ============================================================================
--
-- Flutter now reads selected low-risk data directly with the user's Supabase
-- JWT instead of routing every read through the Worker service key.
--
-- This migration is intentionally idempotent. It makes the direct-read contract
-- explicit:
--   - notes: owner can SELECT only their own rows
--   - plan_limits: authenticated users can read public plan definitions
--   - user_plans / user_monthly_usage / billing_events / usage_events:
--     owner can SELECT only their own rows
--   - user_profiles: authenticated users can read profiles; owner can update
--   - notifications: owner can SELECT / UPDATE their own rows
--   - group read policies from migration 052 remain the source of truth
-- ============================================================================

BEGIN;

-- Notes direct reads.
ALTER TABLE public.notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "owner_select_notes_direct" ON public.notes;
CREATE POLICY "owner_select_notes_direct"
    ON public.notes
    FOR SELECT
    TO authenticated
    USING (auth.uid()::text = user_id);

-- Keep existing service-role behavior for Worker upload/search/admin paths.
GRANT SELECT ON public.notes TO authenticated;
GRANT ALL ON public.notes TO service_role;

-- Billing direct reads. Plan limits are a public catalog for signed-in users.
ALTER TABLE public.plan_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_monthly_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usage_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "auth_read_plan_limits" ON public.plan_limits;
CREATE POLICY "auth_read_plan_limits"
    ON public.plan_limits
    FOR SELECT
    TO authenticated
    USING (true);

DROP POLICY IF EXISTS "owner_read_user_plans" ON public.user_plans;
CREATE POLICY "owner_read_user_plans"
    ON public.user_plans
    FOR SELECT
    TO authenticated
    USING (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "owner_read_user_monthly_usage" ON public.user_monthly_usage;
CREATE POLICY "owner_read_user_monthly_usage"
    ON public.user_monthly_usage
    FOR SELECT
    TO authenticated
    USING (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "owner_read_usage_events" ON public.usage_events;
CREATE POLICY "owner_read_usage_events"
    ON public.usage_events
    FOR SELECT
    TO authenticated
    USING (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "owner_read_billing_events" ON public.billing_events;
CREATE POLICY "owner_read_billing_events"
    ON public.billing_events
    FOR SELECT
    TO authenticated
    USING (auth.uid()::text = user_id);

GRANT SELECT ON public.plan_limits TO authenticated;
GRANT SELECT ON public.user_plans TO authenticated;
GRANT SELECT ON public.user_monthly_usage TO authenticated;
GRANT SELECT ON public.usage_events TO authenticated;
GRANT SELECT ON public.billing_events TO authenticated;

-- Profile and notifications direct reads.
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "auth_read_user_profiles" ON public.user_profiles;
CREATE POLICY "auth_read_user_profiles"
    ON public.user_profiles
    FOR SELECT
    TO authenticated
    USING (true);

DROP POLICY IF EXISTS "owner_update_user_profiles" ON public.user_profiles;
CREATE POLICY "owner_update_user_profiles"
    ON public.user_profiles
    FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "owner_read_notifications" ON public.notifications;
CREATE POLICY "owner_read_notifications"
    ON public.notifications
    FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "owner_update_notifications" ON public.notifications;
CREATE POLICY "owner_update_notifications"
    ON public.notifications
    FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

GRANT SELECT ON public.user_profiles TO authenticated;
GRANT SELECT, UPDATE ON public.notifications TO authenticated;

COMMIT;

-- Verification query to run in Supabase SQL Editor:
-- SELECT schemaname, tablename, policyname, cmd, roles, qual, with_check
-- FROM pg_policies
-- WHERE schemaname = 'public'
--   AND tablename IN (
--     'notes', 'plan_limits', 'user_plans', 'user_monthly_usage',
--     'usage_events', 'billing_events', 'user_profiles', 'notifications'
--   )
-- ORDER BY tablename, policyname;
