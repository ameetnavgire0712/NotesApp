"""Check stats only"""
import requests
import json

BASE = "http://127.0.0.1:8000"

try:
    print("=== Stats ===")
    r = requests.get(f"{BASE}/api/v1/evaluation/stats", timeout=10)
    print(json.dumps(r.json(), indent=2))
    
    print("\n=== Config ===")
    r = requests.get(f"{BASE}/api/v1/evaluation/config", timeout=10)
    print(json.dumps(r.json(), indent=2))
    
except Exception as e:
    print(f"Error: {e}")
