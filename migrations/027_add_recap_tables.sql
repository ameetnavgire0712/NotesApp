-- 027: Recap (daily/weekly/monthly slideshow) tables
--
-- Two tables:
--   recap_cache       — pre-generated recap payloads, keyed by (user, period, period_start).
--                       Populated by the Cloudflare Worker cron and on-demand by GET /api/v1/recap.
--                       Acts as a cache so we don't re-run the LLM categorization on every open.
--   recap_collections — recaps the user explicitly *saved* to their profile.

create table if not exists public.recap_cache (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  period        text not null check (period in ('day','week','month')),
  period_start  date not null,
  period_end    date not null,
  total_notes   int  not null default 0,
  payload       jsonb not null,
  generated_at  timestamptz not null default now(),
  unique (user_id, period, period_start)
);

create index if not exists recap_cache_user_idx
  on public.recap_cache (user_id, period, period_start desc);

create table if not exists public.recap_collections (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  period        text not null check (period in ('day','week','month')),
  period_start  date not null,
  period_end    date not null,
  title         text,
  cover_thumb   text,
  total_notes   int  not null default 0,
  payload       jsonb not null,
  saved_at      timestamptz not null default now()
);

create index if not exists recap_collections_user_idx
  on public.recap_collections (user_id, saved_at desc);

-- RLS: users can only read/write their own rows. Worker uses the service-role
-- key so it bypasses RLS anyway, but make the surface safe for any direct
-- PostgREST access from the Flutter client.
alter table public.recap_cache       enable row level security;
alter table public.recap_collections enable row level security;

drop policy if exists recap_cache_owner       on public.recap_cache;
drop policy if exists recap_collections_owner on public.recap_collections;

create policy recap_cache_owner
  on public.recap_cache
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy recap_collections_owner
  on public.recap_collections
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
