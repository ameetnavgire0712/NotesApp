"""Test TensorLake API directly to see response format"""
import requests
import time

API_KEY = "tl_apiKey_n9tNzWL8dnfDDHdFwhDbP_e_H8F1wGbSYBq_wr1C3VI6ERdeoMlR"
BASE = "https://api.tensorlake.ai/documents/v2"

# Use a public URL for testing
test_url = "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"

# Step 1: Start parse
print("Starting parse with file_url...")
resp = requests.post(
    f"{BASE}/read",
    headers={
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    },
    json={"file_url": test_url}
)
print(f"POST /read: {resp.status_code}")
print(f"Response: {resp.text[:500]}")

if resp.status_code != 200:
    print("Failed to start parse")
    exit(1)

data = resp.json()
parse_id = data.get("parse_id") or data.get("task_id")
print(f"Parse ID: {parse_id}")

# Step 2: Poll
print("\nPolling for results...")
for i in range(30):
    time.sleep(1)
    poll = requests.get(
        f"{BASE}/parse/{parse_id}",
        headers={"Authorization": f"Bearer {API_KEY}"}
    )
    print(f"  [{i+1}] HTTP {poll.status_code}")
    
    if poll.status_code == 202:
        print("       Still processing...")
        continue
    
    if poll.status_code == 200:
        pdata = poll.json()
        print(f"       Response keys: {list(pdata.keys())}")
        print(f"       status field: '{pdata.get('status', '(not present)')}'")
        print(f"       has result: {bool(pdata.get('result'))}")
        if pdata.get('result'):
            print(f"       result keys: {list(pdata['result'].keys())}")
        # Print first 500 chars of response
        print(f"       Raw: {str(pdata)[:500]}")
        break
    else:
        print(f"       ERROR: {poll.text[:200]}")
        break
