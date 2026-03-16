"""Quick test: check stats, run search, run evaluation"""
import requests
import json
import time

BASE = "http://127.0.0.1:8000"

print("=== 1. Current Stats ===")
r = requests.get(f"{BASE}/api/v1/evaluation/stats", timeout=30)
print(json.dumps(r.json(), indent=2))

print("\n=== 2. Current Config ===")
r = requests.get(f"{BASE}/api/v1/evaluation/config", timeout=30)
print(json.dumps(r.json(), indent=2))

print("\n=== 3. Running a new search query ===")
r = requests.post(f"{BASE}/api/v1/search", json={"query": "show me my driving license"}, timeout=60)
print(f"Query: show me my driving license")
print(f"Documents found: {len(r.json().get('documents', []))}")
print(f"Answer: {r.json().get('answer', 'None')[:100] if r.json().get('answer') else 'None'}...")

print("\n=== 4. Stats after search ===")
time.sleep(1)
r = requests.get(f"{BASE}/api/v1/evaluation/stats", timeout=30)
stats = r.json()
print(json.dumps(stats, indent=2))

if stats.get("unevaluated_queries", 0) > 0:
    print("\n=== 5. Running Evaluation ===")
    r = requests.post(f"{BASE}/api/v1/evaluation/run", json={"max_samples": 10}, timeout=300)
    print(json.dumps(r.json(), indent=2))
    
    print("\n=== 6. Getting Run Details ===")
    run_id = r.json().get("run_id")
    if run_id:
        r = requests.get(f"{BASE}/api/v1/evaluation/history/{run_id}", timeout=30)
        print(json.dumps(r.json(), indent=2))
else:
    print("\n⚠️ No unevaluated queries! The search may not be logging to evaluation table.")
