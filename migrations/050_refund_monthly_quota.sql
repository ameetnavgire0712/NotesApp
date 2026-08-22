-- 050_refund_monthly_quota.sql
-- ============================================================================
-- Refund a previously-consumed monthly quota credit (Suggestion 4).
--
-- When an upload pipeline fails or a stuck upload is swept by the cron, we
-- want to give the user their credit back. This RPC:
--   1. Looks up the usage_event row recorded by consume_monthly_quota for
--      the same idempotency_key (= upload trace_id) in the current period.
--   2. If found, decrements user_monthly_usage.used_count by the event's
--      amount (clamped at 0) and deletes the event row.
--   3. Returns a JSON payload describing what happened.
--
-- Idempotent: refunding the same trace_id twice is a no-op because the
-- event row is removed on the first call.
--
-- Apply via the Supabase SQL Editor.
-- ============================================================================

create or replace function public.refund_monthly_quota(
  p_user_id text,
  p_metric text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.usage_events%rowtype;
  v_used integer;
begin
  if p_idempotency_key is null or p_idempotency_key = '' then
    return jsonb_build_object('refunded', false, 'reason', 'missing_idempotency_key');
  end if;

  -- Locate the event recorded by consume_monthly_quota for this user/metric/key.
  select * into v_event
  from public.usage_events
  where user_id = p_user_id
    and metric = p_metric
    and idempotency_key = p_idempotency_key
  order by created_at desc
  limit 1;

  if not found then
    return jsonb_build_object('refunded', false, 'reason', 'no_event_found');
  end if;

  -- Decrement the period counter (never goes below zero).
  update public.user_monthly_usage
  set used_count = greatest(used_count - v_event.amount, 0),
      updated_at = now()
  where user_id = v_event.user_id
    and metric = v_event.metric
    and period_start = v_event.period_start
  returning used_count into v_used;

  -- Drop the event so the same idempotency key is never double-refunded
  -- (and so a retry that re-uses the same trace_id can re-consume cleanly).
  delete from public.usage_events where id = v_event.id;

  return jsonb_build_object(
    'refunded', true,
    'user_id', v_event.user_id,
    'metric', v_event.metric,
    'period_start', v_event.period_start,
    'amount', v_event.amount,
    'used', coalesce(v_used, 0)
  );
end;
$$;

grant execute on function public.refund_monthly_quota(text, text, text) to service_role;
