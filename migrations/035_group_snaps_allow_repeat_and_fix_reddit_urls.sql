-- Allow the same snap to be shared into a group more than once.
-- Group chat entries are message-like events, so group_id + note_id should not
-- be unique.
drop index if exists public.idx_group_snaps_group_note;

-- Older Reddit group shares may contain a short /s/ URL that does not embed
-- reliably. Backfill snapshots to the canonical post URL when metadata has
-- subreddit + post id.
update public.group_snaps gs
set source_url_snapshot =
  'https://www.reddit.com/r/' ||
  (n.metadata->'social'->>'subreddit') ||
  '/comments/' ||
  (n.metadata->'social'->>'post_id') ||
  '/'
from public.notes n
where gs.note_id = n.id
  and (
    gs.file_type_snapshot = 'reddit'
    or gs.source_url_snapshot ilike '%reddit.com%'
    or gs.source_url_snapshot ilike '%redd.it%'
  )
  and n.metadata->'social'->>'post_id' is not null
  and n.metadata->'social'->>'subreddit' is not null;
