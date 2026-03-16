"""Test that user_activities table is being populated."""
import httpx
import time
from app.core.config import get_settings
from supabase import create_client

def main():
    settings = get_settings()
    supabase = create_client(settings.supabase_url, settings.supabase_service_key)
    
    # Get count before
    before = supabase.table("user_activities").select("*", count="exact").gte("created_at", "2026-01-22T00:00:00+00:00").execute()
    print(f"Entries since Jan 22 BEFORE test: {before.count}")
    
    # Make a search request
    print("\nMaking test search request...")
    try:
        response = httpx.post(
            "http://127.0.0.1:8000/api/v1/search",
            json={"query": "test search for user activity logging"},
            timeout=120.0
        )
        print(f"Search response status: {response.status_code}")
        if response.status_code == 200:
            data = response.json()
            print(f"Documents found: {len(data.get('documents', []))}")
    except Exception as e:
        print(f"Error making request: {e}")
        return
    
    # Wait a moment for logging to complete
    time.sleep(2)
    
    # Get count after
    after = supabase.table("user_activities").select("*", count="exact").gte("created_at", "2026-01-22T00:00:00+00:00").execute()
    print(f"\nEntries since Jan 22 AFTER test: {after.count}")
    
    if after.count > before.count:
        print(f"✅ SUCCESS: {after.count - before.count} new activity(ies) logged!")
        # Show latest entry
        latest = supabase.table("user_activities").select("*").order("created_at", desc=True).limit(1).execute()
        if latest.data:
            print(f"Latest entry: {latest.data[0]}")
    else:
        print("❌ FAILED: No new activities were logged")

if __name__ == "__main__":
    main()
