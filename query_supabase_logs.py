"""Query application_logs table in Supabase to analyze search request performance."""

import os
from collections import defaultdict
from datetime import datetime, timedelta
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()

url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY') or os.getenv('SUPABASE_KEY')

print(f"Connecting to Supabase...")
supabase = create_client(url, key)

# Query recent logs from the last 2 hours
two_hours_ago = (datetime.utcnow() - timedelta(hours=2)).isoformat()

print(f"Querying logs since {two_hours_ago}...")
result = supabase.table('application_logs').select('*').gte('timestamp', two_hours_ago).order('timestamp', desc=True).limit(500).execute()

print(f"Total logs retrieved: {len(result.data)}")
print()

if not result.data:
    print("No logs found in application_logs table")
    print("\nPossible reasons:")
    print("1. The migration hasn't been run yet")
    print("2. SUPABASE_SERVICE_KEY is not set on Fly.io")
    print("3. Logs are being written but with errors")
    exit(0)

# Group by correlation_id to see per-request timing
requests = defaultdict(list)
for log in result.data:
    cid = log.get('correlation_id')
    if cid and cid != 'system':
        requests[cid].append(log)

print(f"Unique requests (by correlation_id): {len(requests)}")
print()

# Analyze each request
print("=" * 100)
print("REQUEST TIMING ANALYSIS")
print("=" * 100)

request_timings = []

for cid, logs in requests.items():
    # Sort logs by timestamp
    logs.sort(key=lambda x: x['timestamp'])
    
    first_log = logs[0]
    last_log = logs[-1]
    
    # Parse timestamps
    try:
        start = datetime.fromisoformat(first_log['timestamp'].replace('Z', '+00:00'))
        end = datetime.fromisoformat(last_log['timestamp'].replace('Z', '+00:00'))
        duration = (end - start).total_seconds()
    except:
        duration = 0
    
    # Look for rerank timing in messages
    rerank_time = None
    query_text = None
    for log in logs:
        msg = log.get('message', '')
        if 'Reranking' in msg or 'rerank' in msg.lower():
            # Try to extract timing
            if 'in' in msg and 's' in msg:
                try:
                    # Pattern: "Reranked X documents in Y.Zs"
                    parts = msg.split('in ')
                    if len(parts) > 1:
                        time_str = parts[-1].split('s')[0].strip()
                        rerank_time = float(time_str)
                except:
                    pass
        if 'query' in msg.lower() and query_text is None:
            query_text = msg[:50]
    
    request_timings.append({
        'correlation_id': cid,
        'start': first_log['timestamp'],
        'duration': duration,
        'rerank_time': rerank_time,
        'log_count': len(logs),
        'levels': list(set(log['level'] for log in logs)),
        'machine_id': first_log.get('machine_id', 'unknown'),
        'region': first_log.get('region', 'unknown'),
    })

# Sort by start time
request_timings.sort(key=lambda x: x['start'], reverse=True)

# Print summary
print(f"\n{'Correlation ID':<40} {'Duration':<10} {'Rerank':<10} {'Logs':<6} {'Machine':<15} {'Region':<8} {'Levels'}")
print("-" * 120)

for rt in request_timings[:50]:
    rerank_str = f"{rt['rerank_time']:.2f}s" if rt['rerank_time'] else "N/A"
    levels = ','.join(rt['levels'])
    print(f"{rt['correlation_id']:<40} {rt['duration']:.2f}s     {rerank_str:<10} {rt['log_count']:<6} {rt['machine_id']:<15} {rt['region']:<8} {levels}")

# Statistics
print("\n" + "=" * 100)
print("STATISTICS")
print("=" * 100)

durations = [rt['duration'] for rt in request_timings if rt['duration'] > 0]
rerank_times = [rt['rerank_time'] for rt in request_timings if rt['rerank_time']]

if durations:
    print(f"\nTotal Request Duration:")
    print(f"  Min: {min(durations):.2f}s")
    print(f"  Max: {max(durations):.2f}s")
    print(f"  Avg: {sum(durations)/len(durations):.2f}s")

if rerank_times:
    print(f"\nRerank Times:")
    print(f"  Min: {min(rerank_times):.2f}s")
    print(f"  Max: {max(rerank_times):.2f}s")
    print(f"  Avg: {sum(rerank_times)/len(rerank_times):.2f}s")

# Check for errors
error_logs = [log for log in result.data if log['level'] in ('ERROR', 'CRITICAL')]
if error_logs:
    print(f"\n" + "=" * 100)
    print(f"ERRORS ({len(error_logs)} found)")
    print("=" * 100)
    for log in error_logs[:10]:
        print(f"\n{log['timestamp']} | {log['correlation_id']}")
        print(f"  {log['message'][:200]}")
