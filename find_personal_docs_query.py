"""Find the real user who searched for 'personal docs'."""
import requests, json

WORKER_URL = "https://notesapp-vector-search.monocle0712.workers.dev"
LOGS_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

# Get all recent users
r = requests.get(f'{WORKER_URL}/api/v1/logs/dashboard/users',
    headers={'X-API-Key': LOGS_KEY},
    params={'hours': '24'},
    timeout=15)
print(f"Status: {r.status_code}")
data = r.json()
users = data.get('users', [])
print(f"Found {len(users)} users in last 24h\n")

for u in users:
    uid = u.get('user_id', '?')
    print(f"  User: {uid}")
    print(f"  Last: {u.get('last_activity', '?')}")
    print(f"  Count: {u.get('activity_count', '?')}")
    print()

    # Get recent activities for this user
    r2 = requests.get(f'{WORKER_URL}/api/v1/logs/dashboard/activities',
        headers={'X-API-Key': LOGS_KEY},
        params={'user_id': uid, 'hours': '24', 'limit': '10'},
        timeout=15)
    acts = r2.json().get('activities', [])
    for a in acts[:5]:
        meta = a.get('metadata', {})
        td = a.get('trace_data', {})
        query = meta.get('query', '')
        intent = td.get('intent_classification', '')
        tool = td.get('tool_invoked', '')
        final_count = td.get('final_count', '?')
        print(f"    [{intent}] q=\"{query[:60]}\" -> {tool} ({final_count} results)")
    print()
