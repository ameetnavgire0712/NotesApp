create or replace function public._app_bootstrap_tags(p_user_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as '
  select coalesce(jsonb_agg(tag_value order by lower(tag_value)), ''[]''::jsonb)
  from (
    select distinct btrim(tag) as tag_value
    from notes
    where user_id = p_user_id::text
      and status in (''active'', ''incomplete'')
      and tag is not null
      and btrim(tag) <> ''''
  ) t;
';

create or replace function public._app_bootstrap_billing(p_user_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as '
  select public.get_billing_status(p_user_id::text);
';

create or replace function public._app_bootstrap_groups(p_user_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as '
  select coalesce(jsonb_agg(group_json order by latest_at desc), ''[]''::jsonb)
  from (
    select
      coalesce(latest.shared_at, g.updated_at, g.created_at) as latest_at,
      to_jsonb(g)
      || jsonb_build_object(
        ''role'', gm.role,
        ''status'', gm.status,
        ''member_count'', coalesce(mc.member_count, 0),
        ''unread_count'', case when gm.status = ''active'' then coalesce(uc.unread_count, 0) else 0 end,
        ''latest_activity_at'', latest.shared_at,
        ''latest_activity_type'', case when latest.id is null then ''group_created'' else ''snap_shared'' end,
        ''latest_activity_user_id'', latest.shared_by,
        ''latest_activity_title'', latest.title_snapshot,
        ''latest_activity_description'', latest.description_snapshot,
        ''latest_activity_file_type'', latest.file_type_snapshot,
        ''invited_by_profile'', invited.profile,
        ''latest_activity_actor_profile'', actor.profile
      ) as group_json
    from group_members gm
    join groups g on g.id = gm.group_id
    left join (
      select group_id, count(*)::integer as member_count
      from group_members
      where status in (''active'', ''pending'')
      group by group_id
    ) mc on mc.group_id = gm.group_id
    left join (
      select gm2.group_id, count(gs.id)::integer as unread_count
      from group_members gm2
      left join group_snaps gs
        on gs.group_id = gm2.group_id
       and gs.shared_by <> p_user_id
       and gs.shared_at > coalesce(gm2.last_seen_at, ''1970-01-01''::timestamptz)
      where gm2.user_id = p_user_id
        and gm2.status = ''active''
      group by gm2.group_id
    ) uc on uc.group_id = gm.group_id
    left join lateral (
      select *
      from group_snaps gs
      where gs.group_id = gm.group_id
      order by gs.shared_at desc
      limit 1
    ) latest on true
    left join lateral (
      select jsonb_build_object(
        ''user_id'', up.user_id,
        ''email'', up.email,
        ''display_name'', up.display_name,
        ''avatar_url'', up.avatar_url
      ) as profile
      from user_profiles up
      where up.user_id::text = gm.invited_by::text
      limit 1
    ) invited on true
    left join lateral (
      select jsonb_build_object(
        ''user_id'', up.user_id,
        ''email'', up.email,
        ''display_name'', up.display_name,
        ''avatar_url'', up.avatar_url
      ) as profile
      from user_profiles up
      where up.user_id::text = latest.shared_by::text
      limit 1
    ) actor on true
    where gm.user_id = p_user_id
      and gm.status in (''active'', ''pending'')
  ) shaped;
';

create or replace function public._app_bootstrap_notes(
  p_user_id uuid,
  p_notes_limit integer default 20
)
returns jsonb
language sql
security definer
set search_path = public
as '
  select coalesce(jsonb_agg(
    to_jsonb(n) || jsonb_build_object(
      ''thumbnail_url'', coalesce(
        nullif(n.metadata->>''thumbnail_url'', ''''),
        case
          when n.file_type in (''screenshot'', ''image'') then nullif(n.blob_url, '''')
          when n.file_type = ''uploaded_file''
           and lower(coalesce(n.original_filename, '''')) ~ ''\.(jpg|jpeg|png|gif|webp|heic|bmp|svg)$''
          then nullif(n.blob_url, '''')
          else null
        end
      ),
      ''content_preview'', coalesce(
        nullif(n.description, ''''),
        nullif(n.metadata->>''content_preview'', ''''),
        nullif(n.metadata->>''excerpt'', '''')
      )
    )
    order by n.created_at desc
  ), ''[]''::jsonb)
  from (
    select *
    from notes
    where user_id = p_user_id::text
      and status in (''active'', ''incomplete'')
    order by created_at desc
    limit greatest(0, least(coalesce(p_notes_limit, 20), 200))
  ) n;
';

create or replace function public.get_app_bootstrap(
  p_user_id uuid,
  p_notes_limit integer default 20
)
returns jsonb
language sql
security definer
set search_path = public
as '
  with payload as (
    select
      public._app_bootstrap_tags(p_user_id) as tags,
      public._app_bootstrap_billing(p_user_id) as billing,
      public._app_bootstrap_groups(p_user_id) as groups,
      public._app_bootstrap_notes(p_user_id, p_notes_limit) as notes,
      greatest(0, least(coalesce(p_notes_limit, 20), 200)) as note_limit
  )
  select jsonb_build_object(
    ''tags'', tags,
    ''billing'', billing,
    ''groups'', groups,
    ''notification_counts'', jsonb_build_object(
      ''group_unread_count'',
        coalesce((select sum((item->>''unread_count'')::integer) from jsonb_array_elements(groups) item), 0),
      ''pending_group_invites'',
        coalesce((select count(*) from jsonb_array_elements(groups) item where item->>''status'' = ''pending''), 0),
      ''total_group_badge_count'',
        coalesce((select sum((item->>''unread_count'')::integer) from jsonb_array_elements(groups) item), 0)
        + coalesce((select count(*) from jsonb_array_elements(groups) item where item->>''status'' = ''pending''), 0)
    ),
    ''recent_notes'', notes,
    ''recent_notes_has_more'', jsonb_array_length(notes) >= note_limit and note_limit > 0,
    ''generated_at'', now()
  )
  from payload;
';

grant execute on function public._app_bootstrap_tags(uuid) to authenticated;
grant execute on function public._app_bootstrap_billing(uuid) to authenticated;
grant execute on function public._app_bootstrap_groups(uuid) to authenticated;
grant execute on function public._app_bootstrap_notes(uuid, integer) to authenticated;
grant execute on function public.get_app_bootstrap(uuid, integer) to authenticated;

grant execute on function public._app_bootstrap_tags(uuid) to service_role;
grant execute on function public._app_bootstrap_billing(uuid) to service_role;
grant execute on function public._app_bootstrap_groups(uuid) to service_role;
grant execute on function public._app_bootstrap_notes(uuid, integer) to service_role;
grant execute on function public.get_app_bootstrap(uuid, integer) to service_role;
