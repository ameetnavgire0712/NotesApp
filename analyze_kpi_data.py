"""Analyze what data is available for KPI dashboard"""
from supabase import create_client
import os
from dotenv import load_dotenv
from datetime import datetime, timedelta
from collections import Counter

load_dotenv()
c = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])

print("=" * 60)
print("KPI DATA ANALYSIS")
print("=" * 60)

# 1. Search Traces Analysis
print("\n=== SEARCH TRACES ===")
r = c.table('search_traces').select('user_id,client_source,timing_total_ms,created_at').execute()
searches = r.data

# Client source distribution
sources = Counter(x.get('client_source') or 'unknown' for x in searches)
print(f"Total searches: {len(searches)}")
print("By client_source:")
for src, cnt in sources.most_common():
    print(f"  {src}: {cnt}")

# Unique users
users = set(x.get('user_id') for x in searches if x.get('user_id'))
print(f"\nUnique users (search): {len(users)}")

# Time-based analysis
now = datetime.utcnow()
day_ago = (now - timedelta(days=1)).isoformat()
week_ago = (now - timedelta(days=7)).isoformat()
month_ago = (now - timedelta(days=30)).isoformat()

last_24h = [x for x in searches if x.get('created_at', '') > day_ago]
last_week = [x for x in searches if x.get('created_at', '') > week_ago]
last_month = [x for x in searches if x.get('created_at', '') > month_ago]

print(f"\nSearches last 24h: {len(last_24h)}")
print(f"Searches last 7d: {len(last_week)}")
print(f"Searches last 30d: {len(last_month)}")

# Latency stats
latencies = [x.get('timing_total_ms') for x in searches if x.get('timing_total_ms')]
if latencies:
    print(f"\nLatency stats (ms):")
    print(f"  Avg: {sum(latencies)/len(latencies):.1f}")
    print(f"  Min: {min(latencies):.1f}")
    print(f"  Max: {max(latencies):.1f}")

# 2. Upload Traces Analysis
print("\n=== UPLOAD TRACES ===")
r = c.table('upload_traces').select('user_id,status,created_at').execute()
uploads = r.data
print(f"Total uploads: {len(uploads)}")

# 3. Notes Analysis
print("\n=== NOTES ===")
r = c.table('notes').select('user_id,created_at').execute()
notes = r.data
print(f"Total notes: {len(notes)}")
note_users = set(x.get('user_id') for x in notes if x.get('user_id'))
print(f"Unique users (notes): {len(note_users)}")

# New notes by time
notes_24h = [x for x in notes if x.get('created_at', '') > day_ago]
notes_week = [x for x in notes if x.get('created_at', '') > week_ago]
notes_month = [x for x in notes if x.get('created_at', '') > month_ago]
print(f"\nNotes last 24h: {len(notes_24h)}")
print(f"Notes last 7d: {len(notes_week)}")
print(f"Notes last 30d: {len(notes_month)}")

# 4. API Keys (proxy for users)
print("\n=== USER API KEYS ===")
r = c.table('user_api_keys').select('user_id,created_at').execute()
keys = r.data
key_users = set(x.get('user_id') for x in keys if x.get('user_id'))
print(f"Total API keys: {len(keys)}")
print(f"Unique users with API keys: {len(key_users)}")

# 5. All unique users
all_users = users | note_users | key_users
print("\n=== TOTAL UNIQUE USERS ===")
print(f"Total unique users across all tables: {len(all_users)}")

print("\n" + "=" * 60)
print("RECOMMENDED KPIs:")
print("=" * 60)
print("""
1. Total Users: Count distinct user_ids from notes + search_traces
2. New Users: Check notes.created_at for first note per user
3. Search Volume: Count from search_traces with time grouping
4. Google vs Dashboard: Group by client_source
5. Avg Latency: AVG(timing_total_ms) from search_traces
6. Upload Success Rate: status='completed' / total from upload_traces
7. Notes Created: Count from notes table
8. Active Users: Users with searches in last 24h/7d
""")
