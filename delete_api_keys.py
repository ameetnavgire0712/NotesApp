"""Delete all existing API keys from the database."""
from supabase import create_client
import os
from dotenv import load_dotenv

load_dotenv()

supabase = create_client(os.getenv('SUPABASE_URL'), os.getenv('SUPABASE_SERVICE_KEY'))

# Get all keys first
result = supabase.table('user_api_keys').select('id, name, user_id').execute()
print(f'Found {len(result.data)} API keys:')
for key in result.data:
    print(f"  - {key['name']} (user: {key['user_id'][:8]}...)")

# Delete all keys
if result.data:
    delete_result = supabase.table('user_api_keys').delete().neq('id', '00000000-0000-0000-0000-000000000000').execute()
    print(f'Deleted {len(delete_result.data)} API keys')
else:
    print('No keys to delete')
