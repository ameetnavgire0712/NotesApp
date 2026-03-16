"""Check notes without blob_url"""
from dotenv import load_dotenv
import os
from supabase import create_client

load_dotenv()
supabase = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])

# Check notes without blob_url
result = supabase.table('notes').select('id, title, file_type, status, blob_url').is_('blob_url', 'null').execute()

print('Notes without blob_url:')
print('-' * 80)
for note in result.data:
    status = note['status'] or 'null'
    file_type = note['file_type'] or 'unknown'
    title = (note['title'] or 'No title')[:40]
    note_id = note['id'][:8]
    print(f"  [{status:10}] {file_type:12} | {note_id}... | {title}")

print('-' * 80)
print(f'Total notes without blob_url: {len(result.data)}')

# Check which ones should be incomplete (not quick_note)
non_quick = [n for n in result.data if n['file_type'] != 'quick_note']
print(f'Non-quick-notes without blob_url: {len(non_quick)}')

if non_quick:
    print('\nThese should be marked as incomplete:')
    for note in non_quick:
        print(f"  - {note['id']}")
        # Update to incomplete
        supabase.table('notes').update({'status': 'incomplete'}).eq('id', note['id']).execute()
    print(f'\n✓ Updated {len(non_quick)} notes to incomplete')
