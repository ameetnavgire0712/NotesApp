alter table public.groups
  add column if not exists avatar_url text;

create table if not exists public.group_snap_reactions (
  id uuid primary key default gen_random_uuid(),
  group_snap_id uuid not null references public.group_snaps(id) on delete cascade,
  user_id uuid not null,
  emoji text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(group_snap_id, user_id)
);

create index if not exists idx_group_snap_reactions_snap
  on public.group_snap_reactions(group_snap_id);

alter table public.group_snap_reactions enable row level security;
grant all on public.group_snap_reactions to service_role;
