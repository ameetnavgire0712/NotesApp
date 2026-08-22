-- Adds a short display title column for notes cards.
-- Safe to run multiple times.

ALTER TABLE public.notes
ADD COLUMN IF NOT EXISTS short_title text;
