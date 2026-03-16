"""Find and analyze Aadhaar document"""
from app.services.notes_db import get_notes_db_service

db = get_notes_db_service()

# Get the Identification Document by ID
doc_id = "326a435e-23fc-46ec-b9d6-620c7538e44d"
result = db.client.from_("notes").select("title, content_markdown").eq("id", doc_id).execute()

if result.data:
    doc = result.data[0]
    content = doc["content_markdown"]
    title = doc["title"]
    
    print(f"Title: {title}")
    print(f"Content length: {len(content)} chars")
    print()
    
    # Search for key terms
    terms = ["aadhar", "aadhaar", "name", "amit", "navgire", "card", "permanent", "identity"]
    for term in terms:
        pos = content.lower().find(term)
        print(f"  '{term}': position {pos}")
    
    print()
    print("=== First 800 chars ===")
    print(content[:800])
    print()
    print("=== Last 500 chars ===")
    print(content[-500:])
else:
    print("Document not found")
