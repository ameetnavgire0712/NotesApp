-- Migration 030: Groups collaboration layer
-- Adds group membership, group snap sharing, notifications, and profile search.

create table if not exists public.user_profiles (
  user_id uuid primary key,
  email text not null unique,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid references public.user_profiles(user_id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  status text not null default 'pending' check (status in ('active', 'pending', 'declined', 'left')),
  invited_by uuid,
  invited_email text,
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_members_user_or_email check (user_id is not null or invited_email is not null)
);

create unique index if not exists idx_group_members_group_user
  on public.group_members(group_id, user_id)
  where user_id is not null;

create unique index if not exists idx_group_members_group_email_pending
  on public.group_members(group_id, lower(invited_email))
  where invited_email is not null and status in ('pending');

create table if not exists public.group_invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  email text not null,
  invited_by uuid not null,
  status text not null default 'pending_signup' check (status in ('pending_signup', 'accepted', 'cancelled')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz
);

create unique index if not exists idx_group_invites_group_email_pending
  on public.group_invites(group_id, lower(email))
  where status = 'pending_signup';

create table if not exists public.group_snaps (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  note_id uuid not null references public.notes(id) on delete cascade,
  shared_by uuid not null,
  shared_at timestamptz not null default now(),
  title_snapshot text,
  file_type_snapshot text,
  tag_snapshot text,
  thumbnail_url_snapshot text
);

create unique index if not exists idx_group_snaps_group_note
  on public.group_snaps(group_id, note_id);

create index if not exists idx_group_snaps_group_shared_at
  on public.group_snaps(group_id, shared_at desc);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  type text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_notifications_user_created
  on public.notifications(user_id, created_at desc);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_user_profiles_updated_at on public.user_profiles;
create trigger trg_user_profiles_updated_at
before update on public.user_profiles
for each row execute function public.touch_updated_at();

drop trigger if exists trg_groups_updated_at on public.groups;
create trigger trg_groups_updated_at
before update on public.groups
for each row execute function public.touch_updated_at();

drop trigger if exists trg_group_members_updated_at on public.group_members;
create trigger trg_group_members_updated_at
before update on public.group_members
for each row execute function public.touch_updated_at();

create or replace function public.enforce_group_member_limit()
returns trigger
language plpgsql
as $$
declare
  v_count integer;
begin
  if new.status not in ('active', 'pending') then
    return new;
  end if;

  select count(*) into v_count
  from public.group_members
  where group_id = new.group_id
    and status in ('active', 'pending')
    and id is distinct from new.id;

  if v_count >= 10 then
    raise exception 'A group can have at most 10 active or pending members';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_group_member_limit on public.group_members;
create trigger trg_group_member_limit
before insert or update on public.group_members
for each row execute function public.enforce_group_member_limit();

alter table public.user_profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_invites enable row level security;
alter table public.group_snaps enable row level security;
alter table public.notifications enable row level security;

grant all on public.user_profiles to service_role;
grant all on public.groups to service_role;
grant all on public.group_members to service_role;
grant all on public.group_invites to service_role;
grant all on public.group_snaps to service_role;
grant all on public.notifications to service_role;
