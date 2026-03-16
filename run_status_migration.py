"""Run the notes status column migration"""
from dotenv import load_dotenv
import os
from supabase import create_client

load_dotenv()
supabase = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])

print("Running migration to add status column to notes table...")
print("=" * 60)

# Step 1: Check if status column already exists
try:
    result = supabase.table('notes').select('id, status').limit(1).execute()
    status_exists = True
    print("✓ Status column already exists")
except Exception as e:
    if 'does not exist' in str(e):
        status_exists = False
        print("✗ Status column needs to be added")
        print("\n⚠️  Please run this SQL in your Supabase SQL Editor:")
        print("-" * 60)
        sql = """
-- Add status column with default 'active' for existing notes
ALTER TABLE notes ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'active';

-- Add index for filtering by status
CREATE INDEX IF NOT EXISTS idx_notes_status ON notes(status);

-- Composite index for common query pattern (user_id + status)
CREATE INDEX IF NOT EXISTS idx_notes_user_status ON notes(user_id, status);

-- Verify
SELECT status, COUNT(*) as count FROM notes GROUP BY status;
"""
        print(sql)
        print("-" * 60)
        print("\nAfter running the SQL above, run this script again to update incomplete notes.")
        exit(1)
    else:
        raise e

# Step 2: Check current status distribution
print("\nChecking current status distribution...")
try:
    # Count notes by status
    active_result = supabase.table('notes').select('id', count='exact').eq('status', 'active').execute()
    incomplete_result = supabase.table('notes').select('id', count='exact').eq('status', 'incomplete').execute()
    null_result = supabase.table('notes').select('id', count='exact').is_('status', 'null').execute()
    
    print(f"  - active: {active_result.count or 0}")
    print(f"  - incomplete: {incomplete_result.count or 0}")
    print(f"  - null: {null_result.count or 0}")
except Exception as e:
    print(f"  Error checking status: {e}")

# Step 3: Update notes without blob_url to incomplete
print("\nUpdating notes without blob_url to 'incomplete'...")
try:
    # Find notes without blob_url that aren't quick_notes and are active
    notes_to_update = supabase.table('notes').select('id, title, file_type').is_('blob_url', 'null').neq('file_type', 'quick_note').eq('status', 'active').execute()
    
    if notes_to_update.data:
        print(f"Found {len(notes_to_update.data)} notes to mark as incomplete:")
        for note in notes_to_update.data:
            print(f"  - {note['id'][:8]}... | {note['title'][:40] if note['title'] else 'No title'}")
            # Update status
            supabase.table('notes').update({'status': 'incomplete'}).eq('id', note['id']).execute()
        print(f"\n✓ Updated {len(notes_to_update.data)} notes to 'incomplete' status")
    else:
        print("✓ No notes need to be updated")
except Exception as e:
    print(f"  Error updating notes: {e}")

# Step 4: Final verification
print("\n" + "=" * 60)
print("Final status distribution:")
try:
    active_result = supabase.table('notes').select('id', count='exact').eq('status', 'active').execute()
    incomplete_result = supabase.table('notes').select('id', count='exact').eq('status', 'incomplete').execute()
    
    print(f"  - active: {active_result.count or 0}")
    print(f"  - incomplete: {incomplete_result.count or 0}")
except Exception as e:
    print(f"  Error: {e}")

print("\n✅ Migration complete!")
