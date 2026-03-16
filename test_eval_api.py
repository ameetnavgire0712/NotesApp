"""Test the evaluation API endpoints"""
import requests
import json

BASE_URL = "http://127.0.0.1:8000"

def test_history():
    """Test the /history endpoint"""
    print("Testing /api/v1/evaluation/history...")
    r = requests.get(f"{BASE_URL}/api/v1/evaluation/history", timeout=10)
    print(f"Status: {r.status_code}")
    data = r.json()
    print(json.dumps(data, indent=2, default=str))
    return data

def test_run_details(run_id: str):
    """Test the /history/{run_id} endpoint"""
    print(f"\nTesting /api/v1/evaluation/history/{run_id}...")
    r = requests.get(f"{BASE_URL}/api/v1/evaluation/history/{run_id}", timeout=10)
    print(f"Status: {r.status_code}")
    data = r.json()
    print(json.dumps(data, indent=2, default=str))
    return data

if __name__ == "__main__":
    history = test_history()
    
    if history:
        run_id = history[0].get("run_id")
        if run_id:
            test_run_details(run_id)
        else:
            print("No run_id found in history")
    else:
        print("No evaluation history found")
