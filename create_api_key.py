import os
import secrets
import hashlib
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()

c = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])

# Generate a new API key
random_part = secrets.token_urlsafe(24)
api_key = f'na_{random_part}'
key_prefix = api_key[:12]  # na_ + 8 chars
hashed_key = hashlib.sha256(api_key.encode()).hexdigest()

# Get a user ID from user_api_keys table (since users table is not accessible via REST)
keys = c.table('user_api_keys').select('user_id').limit(1).execute()
user_id = keys.data[0]['user_id']

# Insert new key
result = c.table('user_api_keys').insert({
    'user_id': user_id,
    'api_key': hashed_key,
    'key_prefix': key_prefix,
    'name': 'test_pipeline',
    'scopes': ['read', 'write']
}).execute()

print(f'Created API key: {api_key}')
print(f'User ID: {user_id}')
