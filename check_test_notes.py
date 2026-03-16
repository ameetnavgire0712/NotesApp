import os
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()

c = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])

# Check failed upload traces
print("=== Failed Upload Traces ===")
r = c.table('upload_traces').select('trace_id,status,note_id,original_filename,error_message').eq('status', 'failed').execute()
print(f'Failed uploads: {len(r.data)}')
for t in r.data:
    print(f"  {t['trace_id']}: {t.get('original_filename', 'unknown')}")
    print(f"    note_id={t.get('note_id')}")
    print(f"    error={t.get('error_message', '')[:100]}")
print()

# Check notes with tag=test
print("=== Notes with tag=test ===")
r = c.table('notes').select('id,title,blob_url').eq('tag', 'test').execute()
print(f'Notes with tag=test: {len(r.data)}')
print()

for n in r.data:
    blob_status = 'has blob_url' if n.get('blob_url') else 'NO blob_url'
    print(f"{n['id'][:8]}... {n['title'][:50]}... [{blob_status}]")
