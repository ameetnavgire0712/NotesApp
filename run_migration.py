import os
import requests
from dotenv import load_dotenv

load_dotenv()

url = os.environ['SUPABASE_URL']
key = os.environ['SUPABASE_SERVICE_KEY']

sql = """
ALTER TABLE upload_traces ADD COLUMN IF NOT EXISTS current_step TEXT DEFAULT 'init';
ALTER TABLE upload_traces ADD COLUMN IF NOT EXISTS step_errors JSONB DEFAULT '{}';
"""

# Try using the rpc endpoint with a custom function
response = requests.post(
    f'{url}/rest/v1/rpc/exec_sql',
    headers={
        'apikey': key,
        'Authorization': f'Bearer {key}',
        'Content-Type': 'application/json'
    },
    json={'sql': sql}
)
print(f'Status: {response.status_code}')
print(f'Response: {response.text[:500]}')
