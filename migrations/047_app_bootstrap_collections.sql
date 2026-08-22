-- Adds tag + type collection aggregates to the app bootstrap payload so the
-- home screen can render every collection card with the correct total count
-- and a cover thumbnail without having to load every note client-side.
--
-- Type classification mirrors `_collectionTypeLabel` in
-- infosnap_app/lib/features/home/home_screen.dart:
--   socialSource (instagram / reddit / youtube / twitter / facebook / linkedin)
--     → Initcap(socialSource)
--   else file_type:
--     quick_note            → Note
--     webpage / article     → Webpage
--     image / screenshot    → Image
--     uploaded_file / pdf   → File
--     '' (legacy)           → Snap
--     other                 → initcap(file_type)
create or replace function public._app_bootstrap_collections(p_user_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  with src as (
    select
      n.id,
      n.created_at,
      btrim(coalesce(n.tag, '')) as tag_value,
      lower(coalesce(n.file_type, '')) as ft,
      lower(coalesce(n.metadata->'social'->>'source', '')) as social,
      -- Mirrors the fallback chain used by group_snaps in
      -- cloudflare-worker/src/groups.ts so social shares (Instagram, Reddit,
      -- TikTok, etc.) reliably surface a cover image even when the top-level
      -- metadata.thumbnail_url has not been promoted yet.
      coalesce(
        nullif(n.metadata->>'thumbnail_url', ''),
        nullif(n.metadata->>'preview_image_url', ''),
        nullif(n.metadata->>'thumbnail_blob_url', ''),
        nullif(n.metadata->>'screenshot_url', ''),
        nullif(n.metadata->'social'->>'thumbnail_url', ''),
        case
          when n.file_type in ('screenshot', 'image') then nullif(n.blob_url, '')
          when n.file_type = 'uploaded_file'
           and lower(coalesce(n.original_filename, '')) ~ '\.(jpg|jpeg|png|gif|webp|heic|bmp|svg)$'
          then nullif(n.blob_url, '')
          else null
        end
      ) as thumb
    from notes n
    where n.user_id = p_user_id::text
      and n.status in ('active', 'incomplete')
  ),
  classified as (
    select
      id,
      created_at,
      tag_value,
      thumb,
      case
        when social <> '' then initcap(social)
        when ft = 'quick_note' then 'Note'
        when ft in ('webpage', 'article') then 'Webpage'
        when ft in ('image', 'screenshot') then 'Image'
        when ft in ('uploaded_file', 'pdf') then 'File'
        when ft = '' then 'Snap'
        else initcap(ft)
      end as type_label
    from src
  ),
  tag_agg as (
    select
      tag_value as value,
      count(*)::integer as count,
      (array_agg(thumb order by (thumb is null), created_at desc))[1] as cover
    from classified
    where tag_value <> ''
    group by tag_value
  ),
  type_agg as (
    select
      type_label as value,
      count(*)::integer as count,
      (array_agg(thumb order by (thumb is null), created_at desc))[1] as cover
    from classified
    group by type_label
  )
  select jsonb_build_object(
    'tags', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'value', value,
          'count', count,
          'cover_thumb_url', cover
        )
        order by lower(value)
      )
      from tag_agg
    ), '[]'::jsonb),
    'types', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'value', value,
          'count', count,
          'cover_thumb_url', cover
        )
        order by lower(value)
      )
      from type_agg
    ), '[]'::jsonb)
  );
$$;

-- Replace get_app_bootstrap to include the collections payload.
create or replace function public.get_app_bootstrap(
  p_user_id uuid,
  p_notes_limit integer default 20
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  with payload as (
    select
      public._app_bootstrap_tags(p_user_id) as tags,
      public._app_bootstrap_billing(p_user_id) as billing,
      public._app_bootstrap_groups(p_user_id) as groups,
      public._app_bootstrap_notes(p_user_id, p_notes_limit) as notes,
      public._app_bootstrap_collections(p_user_id) as collections,
      greatest(0, least(coalesce(p_notes_limit, 20), 200)) as note_limit
  )
  select jsonb_build_object(
    'tags', tags,
    'billing', billing,
    'groups', groups,
    'notification_counts', jsonb_build_object(
      'group_unread_count',
        coalesce((select sum((item->>'unread_count')::integer) from jsonb_array_elements(groups) item), 0),
      'pending_group_invites',
        coalesce((select count(*) from jsonb_array_elements(groups) item where item->>'status' = 'pending'), 0),
      'total_group_badge_count',
        coalesce((select sum((item->>'unread_count')::integer) from jsonb_array_elements(groups) item), 0)
        + coalesce((select count(*) from jsonb_array_elements(groups) item where item->>'status' = 'pending'), 0)
    ),
    'recent_notes', notes,
    'recent_notes_has_more', jsonb_array_length(notes) >= note_limit and note_limit > 0,
    'collections', collections,
    'generated_at', now()
  )
  from payload;
$$;

grant execute on function public._app_bootstrap_collections(uuid) to authenticated;
grant execute on function public._app_bootstrap_collections(uuid) to service_role;

-- User profile aggregate so the app can restore the persistent avatar_url
-- from user_profiles after a reinstall (Google sign-in re-overwrites
-- auth.users.raw_user_meta_data.avatar_url with the Google picture on every
-- login, so we cannot rely on Supabase user_metadata for the custom avatar).
create or replace function public._app_bootstrap_profile(p_user_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'user_id', p_user_id,
    'email', up.email,
    'display_name', up.display_name,
    'avatar_url', nullif(up.avatar_url, '')
  )
  from user_profiles up
  where up.user_id = p_user_id
  limit 1;
$$;

grant execute on function public._app_bootstrap_profile(uuid) to authenticated;
grant execute on function public._app_bootstrap_profile(uuid) to service_role;

-- Re-issue get_app_bootstrap one more time to also include the profile.
create or replace function public.get_app_bootstrap(
  p_user_id uuid,
  p_notes_limit integer default 20
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  with payload as (
    select
      public._app_bootstrap_tags(p_user_id) as tags,
      public._app_bootstrap_billing(p_user_id) as billing,
      public._app_bootstrap_groups(p_user_id) as groups,
      public._app_bootstrap_notes(p_user_id, p_notes_limit) as notes,
      public._app_bootstrap_collections(p_user_id) as collections,
      public._app_bootstrap_profile(p_user_id) as profile,
      greatest(0, least(coalesce(p_notes_limit, 20), 200)) as note_limit
  )
  select jsonb_build_object(
    'tags', tags,
    'billing', billing,
    'groups', groups,
    'notification_counts', jsonb_build_object(
      'group_unread_count',
        coalesce((select sum((item->>'unread_count')::integer) from jsonb_array_elements(groups) item), 0),
      'pending_group_invites',
        coalesce((select count(*) from jsonb_array_elements(groups) item where item->>'status' = 'pending'), 0),
      'total_group_badge_count',
        coalesce((select sum((item->>'unread_count')::integer) from jsonb_array_elements(groups) item), 0)
        + coalesce((select count(*) from jsonb_array_elements(groups) item where item->>'status' = 'pending'), 0)
    ),
    'recent_notes', notes,
    'recent_notes_has_more', jsonb_array_length(notes) >= note_limit and note_limit > 0,
    'collections', collections,
    'profile', profile,
    'generated_at', now()
  )
  from payload;
$$;
