-- Migration: Create user_api_keys table for MCP server and external tool authentication
-- Run this migration using: psql or Supabase SQL editor

-- Create user_api_keys table
CREATE TABLE IF NOT EXISTS user_api_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,  -- Supabase auth user id (UUID type to match auth.users.id)
    api_key TEXT NOT NULL UNIQUE,  -- The actual API key (hashed)
    key_prefix TEXT NOT NULL,  -- First 8 chars for identification (e.g., "na_abc123")
    name TEXT NOT NULL,  -- User-friendly name (e.g., "MCP Server", "CLI Tool")
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_used_at TIMESTAMP WITH TIME ZONE,
    expires_at TIMESTAMP WITH TIME ZONE,  -- NULL means never expires
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Metadata
    scopes TEXT[] DEFAULT ARRAY['read', 'write'],  -- Permissions: read, write, admin
    
    CONSTRAINT fk_user_api_keys_user_id 
        FOREIGN KEY (user_id) 
        REFERENCES auth.users(id) 
        ON DELETE CASCADE
);

-- Create index for fast API key lookups
CREATE INDEX IF NOT EXISTS idx_user_api_keys_api_key ON user_api_keys(api_key);
CREATE INDEX IF NOT EXISTS idx_user_api_keys_user_id ON user_api_keys(user_id);
CREATE INDEX IF NOT EXISTS idx_user_api_keys_key_prefix ON user_api_keys(key_prefix);

-- Enable RLS on user_api_keys
ALTER TABLE user_api_keys ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only see their own API keys
CREATE POLICY "Users can view own API keys" ON user_api_keys
    FOR SELECT
    USING (auth.uid() = user_id);

-- Policy: Users can create their own API keys
CREATE POLICY "Users can create own API keys" ON user_api_keys
    FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Policy: Users can delete their own API keys
CREATE POLICY "Users can delete own API keys" ON user_api_keys
    FOR DELETE
    USING (auth.uid() = user_id);

-- Policy: Users can update their own API keys (e.g., deactivate)
CREATE POLICY "Users can update own API keys" ON user_api_keys
    FOR UPDATE
    USING (auth.uid() = user_id);

-- Grant access to service role for server-side operations
GRANT ALL ON user_api_keys TO service_role;
GRANT SELECT ON user_api_keys TO authenticated;

-- Comment for documentation
COMMENT ON TABLE user_api_keys IS 'Stores API keys for MCP server and external tool authentication';
COMMENT ON COLUMN user_api_keys.api_key IS 'SHA-256 hashed API key';
COMMENT ON COLUMN user_api_keys.key_prefix IS 'Unhashed prefix for key identification (first 8 chars)';
COMMENT ON COLUMN user_api_keys.scopes IS 'Permissions: read (view notes), write (create/edit), admin (manage users)';
