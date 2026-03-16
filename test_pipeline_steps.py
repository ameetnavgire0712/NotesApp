import os
import requests
import time
import json
from dotenv import load_dotenv

load_dotenv()

WORKER_URL = 'https://notesapp-vector-search.monocle0712.workers.dev/api/v1'
API_KEY = 'na_LREWZTzX4YSDXpLISUhrAIfb46i_14lW'

# Create a small test file
test_content = 'This is a test document for verifying pipeline step tracking. Created at ' + time.strftime('%Y-%m-%d %H:%M:%S')

# Upload quick note
print('Uploading quick note...')
response = requests.post(
    f'{WORKER_URL}/upload/quick-note',
    headers={
        'X-API-Key': API_KEY,
        'Content-Type': 'application/json'
    },
    json={
        'content': test_content,
        'tag': 'test'
    },
    timeout=30
)
print(f'Status: {response.status_code}')
result = response.json()
print(f'Result: {json.dumps(result, indent=2)}')

trace_id = result.get('trace_id')
if trace_id:
    # Poll for status
    for i in range(15):
        time.sleep(2)
        status_response = requests.get(
            f'{WORKER_URL}/upload/status/{trace_id}',
            headers={'X-API-Key': API_KEY},
            timeout=10
        )
        status_data = status_response.json()
        current_step = status_data.get('current_step', 'unknown')
        status = status_data.get('status', 'unknown')
        print(f'Poll {i+1}: status={status}, current_step={current_step}')
        
        if status in ['completed', 'failed']:
            print(f'\nFinal result:')
            print(f'  current_step: {status_data.get("current_step")}')
            print(f'  status: {status_data.get("status")}')
            print(f'  note_id: {status_data.get("note_id")}')
            print(f'  timing_total_ms: {status_data.get("timing_total_ms")}')
            break
