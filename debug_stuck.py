"""Debug: check the full trace details of the stuck upload"""
import requests, json

SB_URL = "https://vnpqsmiuismvwsynpmfu.supabase.co"
SB_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Nzk0Mzc5NSwiZXhwIjoyMDgzNTE5Nzk1fQ.wfpixwiRQJQX3-rQkAzNTzprefsc_I8pGV6LB-d4fv8"

# Get the latest trace (the stuck one)
r = requests.get(
    f"{SB_URL}/rest/v1/upload_traces?order=created_at.desc&limit=1&select=*",
    headers={"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}"}
)
trace = r.json()[0]
print(json.dumps(trace, indent=2, default=str))
