-- 028: add stored note category for upload-time classification

alter table public.notes
  add column if not exists category text;

create index if not exists notes_user_category_idx
  on public.notes (user_id, category);