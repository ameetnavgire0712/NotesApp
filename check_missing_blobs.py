"""Check which notes are missing blob URLs (would return 'Original file not found')"""
import os
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()

supabase = create_client(
    os.environ['SUPABASE_URL'],
    os.environ['SUPABASE_SERVICE_KEY']
)

# Get all notes with tag=test and check blob_url
result = supabase.table('notes').select('id, title, blob_url, created_at').eq('tag', 'test').order('created_at', desc=True).execute()

print('Notes with tag=test:')
print('=' * 90)
print(f"{'HAS BLOB':<10} | {'NOTE ID':<36} | {'TITLE':<40}")
print('-' * 90)

with_blob = 0
without_blob = 0

for note in result.data:
    has_blob = 'YES' if note.get('blob_url') else 'NO '
    title = (note['title'] or 'No title')[:40]
    note_id = note['id']
    
    if note.get('blob_url'):
        with_blob += 1
    else:
        without_blob += 1
    
    print(f"{has_blob:<10} | {note_id} | {title}")

print('=' * 90)
print(f"\nSummary:")
print(f"  Total notes: {len(result.data)}")
print(f"  With blob_url: {with_blob} (these should work)")
print(f"  Without blob_url: {without_blob} (these return 'Original file not found')")
