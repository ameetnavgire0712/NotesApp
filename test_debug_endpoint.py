"""Test debug endpoint"""
import requests
import json

url = "https://notesapp-vector-search.monocle0712.workers.dev/api/v1/upload/debug-tensorlake"
resp = requests.get(url)
print(f"Status: {resp.status_code}")
data = resp.json()
print(json.dumps(data, indent=2))
