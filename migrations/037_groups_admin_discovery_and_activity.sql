alter table public.groups
  add column if not exists latest_activity_at timestamptz not null default now(),
  add column if not exists latest_activity_type text not null default 'group_created',
  add column if not exists latest_activity_user_id uuid,
  add column if not exists latest_activity_title text,
  add column if not exists latest_activity_description text,
  add column if not exists latest_activity_file_type text;

alter table public.group_members
  drop constraint if exists group_members_role_check;

alter table public.group_members
  add constraint group_members_role_check
  check (role in ('admin', 'member'));

alter table public.group_members
  drop constraint if exists group_members_status_check;

alter table public.group_members
  add constraint group_members_status_check
  check (status in ('active', 'pending', 'requested', 'declined', 'left'));

update public.group_members
set role = 'admin'
where role = 'owner';

create unique index if not exists idx_group_members_single_admin
  on public.group_members(group_id)
  where role = 'admin' and status = 'active';

update public.groups g
set
  latest_activity_at = coalesce(gs.shared_at, g.updated_at, g.created_at, now()),
  latest_activity_type = case when gs.id is null then 'group_created' else 'group_snap' end,
  latest_activity_user_id = coalesce(gs.shared_by, g.created_by),
  latest_activity_title = gs.title_snapshot,
  latest_activity_description = gs.description_snapshot,
  latest_activity_file_type = gs.file_type_snapshot
from lateral (
  select id, shared_at, shared_by, title_snapshot, description_snapshot, file_type_snapshot
  from public.group_snaps
  where group_id = g.id
  order by shared_at desc
  limit 1
) gs
where true;

create index if not exists idx_groups_latest_activity_at
  on public.groups(latest_activity_at desc);