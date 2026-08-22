-- Migration: Create pro_waitlist table for collecting email addresses
-- for users interested in the Pro plan

-- Create the pro_waitlist table
CREATE TABLE IF NOT EXISTS pro_waitlist (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    source TEXT DEFAULT 'landing_page',
    ip_address TEXT,
    user_agent TEXT,
    is_subscribed BOOLEAN DEFAULT TRUE,
    CONSTRAINT pro_waitlist_email_unique UNIQUE (email)
);

-- Create index on email for fast lookups
CREATE INDEX IF NOT EXISTS idx_pro_waitlist_email ON pro_waitlist(email);

-- Create index on created_at for sorting/filtering
CREATE INDEX IF NOT EXISTS idx_pro_waitlist_created_at ON pro_waitlist(created_at DESC);

-- Add comment to table
COMMENT ON TABLE pro_waitlist IS 'Email waitlist for users interested in the Pro plan';

-- Enable RLS (Row Level Security)
ALTER TABLE pro_waitlist ENABLE ROW LEVEL SECURITY;

-- Allow service role to insert (for the worker)
CREATE POLICY "Service role can insert to pro_waitlist" ON pro_waitlist
    FOR INSERT
    WITH CHECK (true);

-- Allow service role to read (for admin purposes)
CREATE POLICY "Service role can read pro_waitlist" ON pro_waitlist
    FOR SELECT
    USING (true);
