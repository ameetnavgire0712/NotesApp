"""
Quick test script for logging framework.
Run this after starting the server with: uvicorn app.main:app --port 8000
"""
import requests
import time

BASE_URL = "http://localhost:8000"

def test_health():
    """Test health endpoint"""
    print("\n=== Testing Health Endpoint ===")
    response = requests.get(f"{BASE_URL}/health")
    print(f"Status: {response.status_code}")
    print(f"Response: {response.json()}")
    return response.json()

def test_list_notes():
    """Test list notes - should generate activity log"""
    print("\n=== Testing List Notes ===")
    response = requests.get(f"{BASE_URL}/api/v1/notes/")
    print(f"Status: {response.status_code}")
    data = response.json()
    print(f"Notes count: {len(data)}")
    return data

def test_get_all_tags():
    """Test get all tags - should generate activity log"""
    print("\n=== Testing Get All Tags ===")
    response = requests.get(f"{BASE_URL}/api/v1/notes/tags/all")
    print(f"Status: {response.status_code}")
    data = response.json()
    print(f"Tags: {data}")
    return data

def test_search_notes():
    """Test search notes - should generate activity log"""
    print("\n=== Testing Search Notes ===")
    response = requests.post(
        f"{BASE_URL}/api/v1/notes/search",
        json={"query": "test", "limit": 5}
    )
    print(f"Status: {response.status_code}")
    data = response.json()
    print(f"Results count: {len(data.get('results', []))}")
    return data

def test_dashboard():
    """Test dashboard endpoint"""
    print("\n=== Testing Dashboard ===")
    response = requests.get(f"{BASE_URL}/api/v1/dashboard/")
    print(f"Status: {response.status_code}")
    if response.status_code == 200:
        data = response.json()
        print(f"Dashboard data: {data}")
        return data
    else:
        print(f"Error: {response.text}")
        return None

def test_recent_activities():
    """Test recent activities from logs endpoint"""
    print("\n=== Testing Recent Activities ===")
    response = requests.get(f"{BASE_URL}/api/v1/logs/activities")
    print(f"Status: {response.status_code}")
    if response.status_code == 200:
        data = response.json()
        if isinstance(data, list):
            print(f"Activities count: {len(data)}")
            if data:
                print(f"First activity: {data[0]}")
        else:
            print(f"Response: {data}")
        return data
    else:
        print(f"Error: {response.text}")
        return None

if __name__ == "__main__":
    print("=" * 60)
    print("Logging Framework End-to-End Test")
    print("=" * 60)
    
    # Run tests
    test_health()
    time.sleep(0.5)
    
    test_list_notes()
    time.sleep(0.5)
    
    test_get_all_tags()
    time.sleep(0.5)
    
    test_search_notes()
    time.sleep(1)  # Give time for logs to be written
    
    # Check if logs were captured
    test_recent_activities()
    time.sleep(0.5)
    
    test_dashboard()
    
    print("\n" + "=" * 60)
    print("Testing Complete!")
    print("=" * 60)
