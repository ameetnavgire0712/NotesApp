import requests

SB_KEY='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8'
r=requests.get('https://vnpqsmiuismvwsynpmfu.supabase.co/rest/v1/upload_traces?select=*&limit=1', headers={'apikey':SB_KEY, 'Authorization':f'Bearer {SB_KEY}'})
if r.json():
    print("Columns in upload_traces:")
    for k in sorted(r.json()[0].keys()):
        print(f"  - {k}")
else:
    print('empty')
