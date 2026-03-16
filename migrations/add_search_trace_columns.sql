-- Migration to add new columns to search_traces table
-- Run this in Supabase SQL Editor

-- Add new timing columns
ALTER TABLE search_traces 
ADD COLUMN IF NOT EXISTS timing_spell_check_ms INTEGER,
ADD COLUMN IF NOT EXISTS timing_tags_fetch_ms INTEGER,
ADD COLUMN IF NOT EXISTS timing_relevance_check_ms INTEGER,
ADD COLUMN IF NOT EXISTS timing_synthesis_ms INTEGER;

-- Add new cache status columns
ALTER TABLE search_traces 
ADD COLUMN IF NOT EXISTS tags_cached BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS synthesis_cached BOOLEAN DEFAULT false;

-- Add relevance verification columns
ALTER TABLE search_traces 
ADD COLUMN IF NOT EXISTS relevance_verified_candidates JSONB,
ADD COLUMN IF NOT EXISTS relevance_verified_count INTEGER;

-- Add chunk grouping columns (top 3 per doc)
ALTER TABLE search_traces 
ADD COLUMN IF NOT EXISTS chunks_before_grouping INTEGER,
ADD COLUMN IF NOT EXISTS chunks_after_grouping INTEGER,
ADD COLUMN IF NOT EXISTS unique_documents INTEGER,
ADD COLUMN IF NOT EXISTS chunks_per_doc_limit INTEGER;

-- Add dedup after LLM verification columns
ALTER TABLE search_traces 
ADD COLUMN IF NOT EXISTS dedup_before_count INTEGER,
ADD COLUMN IF NOT EXISTS dedup_after_count INTEGER,
ADD COLUMN IF NOT EXISTS dedup_removed INTEGER;

-- Add Chrome extension timing columns
ALTER TABLE search_traces 
ADD COLUMN IF NOT EXISTS extension_total_flow_ms INTEGER,
ADD COLUMN IF NOT EXISTS extension_settings_check_ms INTEGER,
ADD COLUMN IF NOT EXISTS extension_backend_search_ms INTEGER,
ADD COLUMN IF NOT EXISTS extension_notification_ms INTEGER,
ADD COLUMN IF NOT EXISTS extension_delay_ms INTEGER,
ADD COLUMN IF NOT EXISTS extension_source TEXT;

-- Verify columns exist
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_name = 'search_traces' 
ORDER BY ordinal_position;
