"""Check status of notes with tag=test"""
import os
from supabase import create_client

SUPABASE_URL = os.environ.get('SUPABASE_URL', 'https://waxbogxpmxtbsckwbtxj.supabase.co')
SUPABASE_KEY = os.environ.get('SUPABASE_SERVICE_KEY', '')

# Load from .env if needed
if not SUPABASE_KEY:
    try:
        with open('.env', 'r') as f:
            for line in f:
                if line.startswith('SUPABASE_SERVICE_KEY='):
                    SUPABASE_KEY = line.strip().split('=', 1)[1].strip('"\'')
    except:
        pass

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)

print("Checking notes with tag='test'...")
print("=" * 60)

# Get all notes with tag=test
result = supabase.table('notes').select('id,title,tag,status,blob_url,file_type,created_at').eq('tag', 'test').execute()

print(f"Found {len(result.data)} notes with tag='test'")
print()

for note in result.data:
    has_blob = "✓" if note.get('blob_url') else "✗"
    status = note.get('status', 'NULL')
    file_type = note.get('file_type', 'unknown')
    title = (note.get('title') or 'Untitled')[:50]
    print(f"  {status:12} | blob:{has_blob} | {file_type:12} | {title}")

print()
print("=" * 60)
print("Status summary:")
status_counts = {}
for note in result.data:
    s = note.get('status', 'NULL')
    status_counts[s] = status_counts.get(s, 0) + 1
for status, count in sorted(status_counts.items()):
    print(f"  {status}: {count}")
