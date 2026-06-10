-- ============================================================================
-- Migration 052: Phase 1 — Owner-policies for tables with RLS-on / no rules
-- ============================================================================
--
-- Context:
--   Migrations 029 (billing) and 030 (groups/profile) enabled RLS but only
--   added `service_role` policies. The Cloudflare Worker uses the service
--   key today, so this migration is pure DEFENSE-IN-DEPTH: a safety net
--   that ensures if anything ever calls Supabase with a user JWT (anon key
--   + access token), users can only ever see their own rows.
--
-- Safety:
--   - All new policies are restricted to the `authenticated` role
--   - The existing `service_role` policies (which bypass RLS) are untouched
--   - All statements use DROP POLICY IF EXISTS / CREATE POLICY → idempotent
--   - No Worker code paths change. Existing service_key calls still work.
--
-- Column-type cheat-sheet (verified from 029/030):
--   public.user_plans.user_id            text   → auth.uid()::text = user_id
--   public.user_monthly_usage.user_id    text
--   public.usage_events.user_id          text
--   public.billing_events.user_id        text
--   public.plan_limits                   (public catalog — readable by all auth users)
--   public.user_profiles.user_id         uuid   → auth.uid() = user_id
--   public.notifications.user_id         uuid
--   public.groups.created_by             uuid
--   public.group_members.user_id         uuid
--   public.group_invites.email           text   → auth.jwt()->>'email'
--   public.group_snaps                   group-scoped (via is_group_member helper)
--
-- VERIFY BEFORE applying (run in SQL Editor → confirm rls_enabled / policy_count):
--
--   SELECT n.nspname AS schema,
--          c.relname AS table_name,
--          c.relrowsecurity AS rls_enabled,
--          (SELECT count(*) FROM pg_policies p
--             WHERE p.schemaname = n.nspname AND p.tablename = c.relname) AS policy_count
--     FROM pg_class c
--     JOIN pg_namespace n ON n.oid = c.relnamespace
--    WHERE n.nspname = 'public'
--      AND c.relkind = 'r'
--    ORDER BY c.relrowsecurity DESC, policy_count, table_name;
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Helper: is_group_member()
-- SECURITY DEFINER lets group_members / group_snaps policies check membership
-- without triggering RLS recursion on the same table.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_group_member(p_group_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM public.group_members
         WHERE group_id = p_group_id
           AND user_id  = p_user_id
    );
$$;

REVOKE ALL ON FUNCTION public.is_group_member(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.is_group_member(uuid, uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.is_group_member(uuid, uuid) IS
  'Phase 1 RLS helper: returns true iff the given user_id is a member of the given group. SECURITY DEFINER prevents RLS recursion on group_members policies.';


-- ============================================================================
-- BILLING TABLES (migration 029) — owner SELECT policies
-- ============================================================================

-- plan_limits is a public catalog (Free / Premium tier definitions). Any
-- signed-in user may read it; writes remain service-only.
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


-- ============================================================================
-- PROFILE / NOTIFICATIONS (migration 030) — owner policies
-- ============================================================================

-- user_profiles: any authenticated user may look up profiles (needed for
-- group-member display names / avatars). Only the owner may UPDATE.
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

-- notifications: owner-only SELECT / UPDATE (marking read). Writes via service.
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


-- ============================================================================
-- GROUPS / GROUP_MEMBERS / GROUP_INVITES / GROUP_SNAPS (migration 030)
-- ============================================================================

-- groups: any member can read; only creator can update group metadata.
DROP POLICY IF EXISTS "member_read_groups" ON public.groups;
CREATE POLICY "member_read_groups"
    ON public.groups
    FOR SELECT
    TO authenticated
    USING (
        created_by = auth.uid()
        OR public.is_group_member(id, auth.uid())
    );

DROP POLICY IF EXISTS "creator_update_groups" ON public.groups;
CREATE POLICY "creator_update_groups"
    ON public.groups
    FOR UPDATE
    TO authenticated
    USING (created_by = auth.uid())
    WITH CHECK (created_by = auth.uid());

-- group_members: members of the same group can see each other; users can
-- always see their own membership rows (covers the bootstrap case).
DROP POLICY IF EXISTS "member_read_group_members" ON public.group_members;
CREATE POLICY "member_read_group_members"
    ON public.group_members
    FOR SELECT
    TO authenticated
    USING (
        user_id = auth.uid()
        OR public.is_group_member(group_id, auth.uid())
    );

-- group_invites: invitee (matched by email in JWT) can see their pending
-- invites; group members can see invites for groups they belong to.
DROP POLICY IF EXISTS "invitee_read_group_invites" ON public.group_invites;
CREATE POLICY "invitee_read_group_invites"
    ON public.group_invites
    FOR SELECT
    TO authenticated
    USING (
        lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
        OR public.is_group_member(group_id, auth.uid())
    );

-- group_snaps: any member of the group can see snaps shared into it.
DROP POLICY IF EXISTS "member_read_group_snaps" ON public.group_snaps;
CREATE POLICY "member_read_group_snaps"
    ON public.group_snaps
    FOR SELECT
    TO authenticated
    USING (public.is_group_member(group_id, auth.uid()));


-- ============================================================================
-- DONE
-- ============================================================================
-- Re-run the verify query above. Expected: every public table with
-- relrowsecurity = true now has at least one row in pg_policies. The Worker
-- continues to use service_role, which bypasses all of these policies.
-- ============================================================================

COMMIT;
