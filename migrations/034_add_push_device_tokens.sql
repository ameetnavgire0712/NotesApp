-- Stores Firebase Cloud Messaging tokens for push notifications.

create table if not exists public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null,
  platform text not null default 'android',
  app_version text,
  device_id text,
  enabled boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists idx_device_tokens_user_token
  on public.device_tokens(user_id, token);

create index if not exists idx_device_tokens_user_enabled
  on public.device_tokens(user_id, enabled)
  where enabled = true;

alter table public.device_tokens enable row level security;

grant all on public.device_tokens to service_role;
