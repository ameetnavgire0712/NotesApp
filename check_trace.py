"""Check single trace"""
import requests

SUPABASE_URL = 'https://vnpqsmiuismvwsynpmfu.supabase.co'
SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8'
h = {'apikey': SUPABASE_KEY, 'Authorization': f'Bearer {SUPABASE_KEY}'}

import sys
trace_id = sys.argv[1] if len(sys.argv) > 1 else 'ut_1771588214563_3tghcxq'

r = requests.get(f'{SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.{trace_id}&select=*', headers=h)
t = r.json()[0]
for k, v in sorted(t.items()):
    if v is not None:
        print(f'{k}: {str(v)[:100]}')
