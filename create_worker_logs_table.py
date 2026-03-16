"""Create the worker_logs table in Supabase."""

import os
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()

url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY')
supabase = create_client(url, key)

print(f"Connected to Supabase: {url}")

# Try to insert a test row to check if table exists
try:
    result = supabase.table("worker_logs").select("id").limit(1).execute()
    print(f"Table already exists! Found {len(result.data)} rows")
except Exception as e:
    print(f"Table doesn't exist or error: {e}")
    print("\nPlease run this SQL in Supabase Dashboard SQL Editor:")
    print("-" * 60)
    sql = """
CREATE TABLE IF NOT EXISTS public.worker_logs (
    id BIGSERIAL PRIMARY KEY,
    request_id VARCHAR(50) NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    endpoint VARCHAR(50) NOT NULL,
    method VARCHAR(10) NOT NULL,
    user_id UUID,
    query TEXT,
    timing_total_ms INTEGER,
    timing_embedding_ms INTEGER,
    timing_vectorize_ms INTEGER,
    timing_rerank_ms INTEGER,
    timing_parse_ms INTEGER,
    timing_transform_ms INTEGER,
    result_match_count INTEGER,
    result_rerank_count INTEGER,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE public.worker_logs ENABLE ROW LEVEL SECURITY;

-- Policy for service role
CREATE POLICY "Service role full access to worker_logs"
    ON public.worker_logs FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_worker_logs_timestamp ON public.worker_logs (timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_worker_logs_endpoint ON public.worker_logs (endpoint);
"""
    print(sql)
    print("-" * 60)
