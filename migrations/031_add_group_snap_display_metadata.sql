-- Adds richer snapshots for group-shared snaps.

alter table public.group_snaps
  add column if not exists description_snapshot text,
  add column if not exists source_url_snapshot text,
  add column if not exists original_filename_snapshot text,
  add column if not exists blob_url_snapshot text,
  add column if not exists content_preview_snapshot text;
