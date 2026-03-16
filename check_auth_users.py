"""Check auth.users access via Supabase admin API"""
import os
import requests
from dotenv import load_dotenv
from datetime import datetime, timedelta

load_dotenv()

SUPABASE_URL = os.environ['SUPABASE_URL']
SUPABASE_SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY']

url = f"{SUPABASE_URL}/auth/v1/admin/users"
headers = {
    'apikey': SUPABASE_SERVICE_KEY,
    'Authorization': f'Bearer {SUPABASE_SERVICE_KEY}'
}

r = requests.get(url, headers=headers, params={'page': 1, 'per_page': 1000})
if r.ok:
    data = r.json()
    users = data.get('users', [])
    print(f"Total users in auth.users: {len(users)}")
    
    # Analyze by created_at
    now = datetime.utcnow()
    day_ago = now - timedelta(days=1)
    week_ago = now - timedelta(days=7)
    month_ago = now - timedelta(days=30)
    
    new_24h = 0
    new_7d = 0
    new_30d = 0
    
    for u in users:
        created = u.get('created_at', '')
        if created:
            # Parse ISO format
            created_dt = datetime.fromisoformat(created.replace('Z', '+00:00').replace('+00:00', ''))
            if created_dt > day_ago:
                new_24h += 1
            if created_dt > week_ago:
                new_7d += 1
            if created_dt > month_ago:
                new_30d += 1
    
    print(f"\nNew users:")
    print(f"  Last 24h: {new_24h}")
    print(f"  Last 7d: {new_7d}")
    print(f"  Last 30d: {new_30d}")
    
    print(f"\nSample users:")
    for u in users[:5]:
        uid = u.get('id', '')[:8]
        email = u.get('email', 'no-email')
        created = u.get('created_at', '')[:19]
        print(f"  {uid}... | {email} | {created}")
else:
    print(f"Error: {r.status_code}")
    print(r.text[:500])
