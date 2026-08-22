-- Add Facebook as a first-class social file_type for shared URLs.
-- Keep all currently supported file types in the CHECK constraint.
alter table public.notes drop constraint if exists notes_file_type_check;

alter table public.notes add constraint notes_file_type_check
  check (file_type in (
    'uploaded_file',
    'screenshot',
    'quick_note',
    'image',
    'webpage',
    'youtube',
    'instagram',
    'facebook',
    'linkedin',
    'twitter',
    'reddit'
  ));
