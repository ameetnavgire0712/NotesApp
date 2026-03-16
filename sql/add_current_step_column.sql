-- Add current_step column to upload_traces table
-- This tracks which pipeline step the upload is currently on

ALTER TABLE upload_traces 
ADD COLUMN IF NOT EXISTS current_step TEXT DEFAULT 'init';

-- Add step_errors JSONB column to store per-step error information
ALTER TABLE upload_traces 
ADD COLUMN IF NOT EXISTS step_errors JSONB DEFAULT '{}';

-- Update existing traces to have a sensible current_step based on status
UPDATE upload_traces 
SET current_step = CASE 
    WHEN status = 'completed' THEN 'completed'
    WHEN status = 'failed' THEN 'failed'
    WHEN status = 'cancelled' THEN 'cancelled'
    ELSE 'init'
END
WHERE current_step IS NULL;

-- Add comment for documentation
COMMENT ON COLUMN upload_traces.current_step IS 'Current pipeline step: init, blob_upload, tensorlake_parse, tensorlake_poll, html_cleanup, title_gen, chunking, embedding, db_insert, vectorize_upsert, finalize, completed, failed, cancelled';
COMMENT ON COLUMN upload_traces.step_errors IS 'JSON object mapping step names to their error messages, e.g., {"html_cleanup": "LLM rate limit exceeded"}';
