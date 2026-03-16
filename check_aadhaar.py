"""Find where Aadhaar appears in content"""
from app.services.notes_db import get_notes_db_service

db = get_notes_db_service()
notes = db.client.from_('notes').select('id, title, content_markdown').eq('user_id', 'default_user').ilike('title', '%Identification%').execute()

for n in notes.data[:1]:
    content = n.get('content_markdown', '')
    title = n.get('title', '')
    
    # Find where 'Aadhaar' or 'aadhar' appears
    lower_content = content.lower()
    idx_aadhaar = lower_content.find('aadhaar')
    idx_name = lower_content.find('amit')
    
    print(f"TITLE: {title}")
    print(f"Content length: {len(content)} chars")
    print(f"Position of 'Aadhaar': {idx_aadhaar}")
    print(f"Position of 'Amit': {idx_name}")
    
    if idx_aadhaar > 0:
        start = max(0, idx_aadhaar - 50)
        end = min(len(content), idx_aadhaar + 150)
        print(f"\nContext around 'Aadhaar':")
        print(f"...{content[start:end]}...")
    
    if idx_name > 0:
        start = max(0, idx_name - 50)
        end = min(len(content), idx_name + 150)
        print(f"\nContext around 'Amit':")
        print(f"...{content[start:end]}...")
    
    print(f"\nFirst 500 chars (what reranker sees):")
    print(content[:500])
