"""Look up an API key to find its owner."""
import hashlib
from supabase import create_client
import os
from dotenv import load_dotenv

load_dotenv()

api_key = 'na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU'

# Hash the key (same way the server does)
key_hash = hashlib.sha256(api_key.encode()).hexdigest()
print(f'Key hash: {key_hash}')

supabase = create_client(os.getenv('SUPABASE_URL'), os.getenv('SUPABASE_SERVICE_KEY'))

# Look up by hash (column is 'api_key' not 'key_hash')
result = supabase.table('user_api_keys').select('*').eq('api_key', key_hash).execute()

if result.data:
    key_info = result.data[0]
    print(f'Found key!')
    print(f'  Name: {key_info.get("name")}')
    print(f'  User ID: {key_info.get("user_id")}')
    print(f'  Created: {key_info.get("created_at")}')
    print(f'  Scopes: {key_info.get("scopes")}')
else:
    print('Key not found in database')
