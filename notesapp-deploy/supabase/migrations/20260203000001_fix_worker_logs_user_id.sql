-- =============================================================================
-- Fix worker_logs.user_id column type
-- 
-- Change from UUID to TEXT to support string user IDs from the Worker
-- =============================================================================

ALTER TABLE public.worker_logs 
    ALTER COLUMN user_id TYPE TEXT;

-- Add comment
COMMENT ON COLUMN public.worker_logs.user_id IS 'User ID from request (string, not UUID)';
