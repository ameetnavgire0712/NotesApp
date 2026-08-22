-- Billing and monthly usage quotas for InfoSnap.
-- Free users get limited access to the same feature surface; premium can be
-- toggled manually until a payment gateway is connected.

create table if not exists public.plan_limits (
  plan_code text not null,
  metric text not null check (metric in ('upload', 'snapbot_search', 'google_search')),
  monthly_limit integer not null check (monthly_limit >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (plan_code, metric)
);

insert into public.plan_limits (plan_code, metric, monthly_limit)
values
  ('free', 'upload', 30),
  ('free', 'snapbot_search', 100),
  ('free', 'google_search', 10),
  ('premium', 'upload', 200),
  ('premium', 'snapbot_search', 1000),
  ('premium', 'google_search', 50)
on conflict (plan_code, metric) do update
set monthly_limit = excluded.monthly_limit,
    updated_at = now();

create table if not exists public.user_plans (
  user_id text primary key,
  plan_code text not null default 'free' check (plan_code in ('free', 'premium')),
  status text not null default 'active' check (status in ('active', 'trialing', 'cancelled', 'expired')),
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  provider text not null default 'manual',
  provider_customer_id text,
  provider_subscription_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.user_monthly_usage (
  user_id text not null,
  metric text not null check (metric in ('upload', 'snapbot_search', 'google_search')),
  period_start date not null,
  used_count integer not null default 0 check (used_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, metric, period_start)
);

create table if not exists public.usage_events (
  id uuid primary key default gen_random_uuid(),
  user_id text not null,
  metric text not null check (metric in ('upload', 'snapbot_search', 'google_search')),
  period_start date not null,
  amount integer not null check (amount > 0),
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create unique index if not exists usage_events_unique_idempotency
on public.usage_events (user_id, metric, period_start, idempotency_key)
where idempotency_key is not null;

create index if not exists usage_events_user_created_idx
on public.usage_events (user_id, created_at desc);

create table if not exists public.billing_events (
  id uuid primary key default gen_random_uuid(),
  user_id text not null,
  event_type text not null,
  provider text not null default 'manual',
  provider_event_id text,
  amount_cents integer,
  currency text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists billing_events_user_created_idx
on public.billing_events (user_id, created_at desc);

create or replace function public.ensure_user_plan(p_user_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.user_plans (
    user_id,
    plan_code,
    status,
    current_period_start,
    current_period_end,
    provider
  )
  values (
    p_user_id,
    'free',
    'active',
    date_trunc('month', now()),
    date_trunc('month', now()) + interval '1 month',
    'manual'
  )
  on conflict (user_id) do nothing;
end;
$$;

create or replace function public.effective_plan_code(
  p_plan_code text,
  p_status text,
  p_current_period_end timestamptz
)
returns text
language sql
stable
as $$
  select case
    when p_plan_code = 'premium'
      and p_status in ('active', 'trialing', 'cancelled')
      and (p_current_period_end is null or p_current_period_end > now())
    then 'premium'
    else 'free'
  end;
$$;

create or replace function public.get_billing_status(p_user_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_period_start date := date_trunc('month', v_now)::date;
  v_reset_at timestamptz := date_trunc('month', v_now) + interval '1 month';
  v_plan public.user_plans%rowtype;
  v_effective_plan text;
  v_usage jsonb;
begin
  perform public.ensure_user_plan(p_user_id);

  select * into v_plan
  from public.user_plans
  where user_id = p_user_id;

  v_effective_plan := public.effective_plan_code(
    v_plan.plan_code,
    v_plan.status,
    v_plan.current_period_end
  );

  with metrics as (
    select metric, monthly_limit
    from public.plan_limits
    where plan_code = v_effective_plan
  )
  select coalesce(
    jsonb_object_agg(
      metrics.metric,
      jsonb_build_object(
        'used', coalesce(usage.used_count, 0),
        'limit', metrics.monthly_limit,
        'remaining', greatest(metrics.monthly_limit - coalesce(usage.used_count, 0), 0)
      )
    ),
    '{}'::jsonb
  )
  into v_usage
  from metrics
  left join public.user_monthly_usage usage
    on usage.user_id = p_user_id
   and usage.metric = metrics.metric
   and usage.period_start = v_period_start;

  return jsonb_build_object(
    'user_id', p_user_id,
    'plan_code', v_plan.plan_code,
    'effective_plan_code', v_effective_plan,
    'status', v_plan.status,
    'current_period_start', v_plan.current_period_start,
    'current_period_end', v_plan.current_period_end,
    'cancel_at_period_end', v_plan.cancel_at_period_end,
    'provider', v_plan.provider,
    'period_start', v_period_start,
    'reset_at', v_reset_at,
    'usage', v_usage
  );
end;
$$;

create or replace function public.consume_monthly_quota(
  p_user_id text,
  p_metric text,
  p_amount integer default 1,
  p_idempotency_key text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_period_start date := date_trunc('month', v_now)::date;
  v_reset_at timestamptz := date_trunc('month', v_now) + interval '1 month';
  v_plan public.user_plans%rowtype;
  v_effective_plan text;
  v_limit integer;
  v_used integer;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'p_amount must be positive';
  end if;

  if p_metric not in ('upload', 'snapbot_search', 'google_search') then
    raise exception 'Unsupported quota metric: %', p_metric;
  end if;

  perform public.ensure_user_plan(p_user_id);

  select * into v_plan
  from public.user_plans
  where user_id = p_user_id
  for update;

  v_effective_plan := public.effective_plan_code(
    v_plan.plan_code,
    v_plan.status,
    v_plan.current_period_end
  );

  select monthly_limit into v_limit
  from public.plan_limits
  where plan_code = v_effective_plan
    and metric = p_metric;

  if v_limit is null then
    raise exception 'Missing plan limit for plan %, metric %', v_effective_plan, p_metric;
  end if;

  insert into public.user_monthly_usage (user_id, metric, period_start, used_count)
  values (p_user_id, p_metric, v_period_start, 0)
  on conflict (user_id, metric, period_start) do nothing;

  select used_count into v_used
  from public.user_monthly_usage
  where user_id = p_user_id
    and metric = p_metric
    and period_start = v_period_start
  for update;

  if p_idempotency_key is not null and exists (
    select 1
    from public.usage_events
    where user_id = p_user_id
      and metric = p_metric
      and period_start = v_period_start
      and idempotency_key = p_idempotency_key
  ) then
    return jsonb_build_object(
      'allowed', true,
      'code', 'ALREADY_COUNTED',
      'metric', p_metric,
      'used', v_used,
      'limit', v_limit,
      'remaining', greatest(v_limit - v_used, 0),
      'plan_code', v_plan.plan_code,
      'effective_plan_code', v_effective_plan,
      'period_start', v_period_start,
      'reset_at', v_reset_at
    );
  end if;

  if v_used + p_amount > v_limit then
    return jsonb_build_object(
      'allowed', false,
      'code', 'MONTHLY_QUOTA_REACHED',
      'metric', p_metric,
      'used', v_used,
      'limit', v_limit,
      'remaining', 0,
      'plan_code', v_plan.plan_code,
      'effective_plan_code', v_effective_plan,
      'period_start', v_period_start,
      'reset_at', v_reset_at
    );
  end if;

  update public.user_monthly_usage
  set used_count = used_count + p_amount,
      updated_at = now()
  where user_id = p_user_id
    and metric = p_metric
    and period_start = v_period_start
  returning used_count into v_used;

  insert into public.usage_events (
    user_id,
    metric,
    period_start,
    amount,
    idempotency_key,
    metadata
  )
  values (
    p_user_id,
    p_metric,
    v_period_start,
    p_amount,
    p_idempotency_key,
    coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict do nothing;

  return jsonb_build_object(
    'allowed', true,
    'code', 'OK',
    'metric', p_metric,
    'used', v_used,
    'limit', v_limit,
    'remaining', greatest(v_limit - v_used, 0),
    'plan_code', v_plan.plan_code,
    'effective_plan_code', v_effective_plan,
    'period_start', v_period_start,
    'reset_at', v_reset_at
  );
end;
$$;

alter table public.plan_limits enable row level security;
alter table public.user_plans enable row level security;
alter table public.user_monthly_usage enable row level security;
alter table public.usage_events enable row level security;
alter table public.billing_events enable row level security;

drop policy if exists "service_role_plan_limits" on public.plan_limits;
create policy "service_role_plan_limits"
on public.plan_limits for all
to service_role
using (true)
with check (true);

drop policy if exists "service_role_user_plans" on public.user_plans;
create policy "service_role_user_plans"
on public.user_plans for all
to service_role
using (true)
with check (true);

drop policy if exists "service_role_user_monthly_usage" on public.user_monthly_usage;
create policy "service_role_user_monthly_usage"
on public.user_monthly_usage for all
to service_role
using (true)
with check (true);

drop policy if exists "service_role_usage_events" on public.usage_events;
create policy "service_role_usage_events"
on public.usage_events for all
to service_role
using (true)
with check (true);

drop policy if exists "service_role_billing_events" on public.billing_events;
create policy "service_role_billing_events"
on public.billing_events for all
to service_role
using (true)
with check (true);

grant execute on function public.ensure_user_plan(text) to service_role;
grant execute on function public.get_billing_status(text) to service_role;
grant execute on function public.consume_monthly_quota(text, text, integer, text, jsonb) to service_role;
