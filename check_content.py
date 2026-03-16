"""Check Aadhaar document content for key terms"""
from app.services.notes_db import get_notes_db_service

db = get_notes_db_service()

# Get the Identification Document  
result = db.client.from_("notes").select("title, content_markdown").ilike("title", "%Identification%").limit(1).execute()
if result.data:
    doc = result.data[0]
    content = doc["content_markdown"]
    title = doc["title"]
    
    print(f"Title: {title[:80]}")
    print(f"Content length: {len(content)} chars")
    print()
    
    # Search for key terms
    terms = ["aadhar", "aadhaar", "name", "amit", "navgire", "card", "permanent"]
    for term in terms:
        pos = content.lower().find(term)
        print(f"  '{term}': position {pos}")
    
    print()
    print("First 500 chars:")
    print(content[:500])
    print()
    print("Last 500 chars:")
    print(content[-500:])
