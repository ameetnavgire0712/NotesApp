-- Migration 014: Add keyword_only_injected column to search_traces
-- Tracks how many keyword-only results were injected (no vector match)
-- Run this in Supabase SQL Editor

ALTER TABLE search_traces ADD COLUMN IF NOT EXISTS keyword_only_injected INTEGER;
