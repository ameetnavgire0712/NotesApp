"""Query Supabase logs to show start/end time, query, and errors for each request."""

import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv
from supabase import create_client

# Output to file
output_file = "c:\\Users\\ameet\\Documents\\NotesApp\\query_analysis_output.txt"
sys.stdout = open(output_file, 'w', encoding='utf-8')

load_dotenv()

url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY') or os.getenv('SUPABASE_KEY')

print("Connecting to Supabase...")
supabase = create_client(url, key)

# Get all logs from the last 2 hours
two_hours_ago = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()

print(f"Querying logs since {two_hours_ago}...")
result = supabase.table('application_logs').select('*').gte('timestamp', two_hours_ago).order('timestamp', desc=False).limit(2000).execute()

print(f"Total logs: {len(result.data)}")

# Group by correlation_id
requests = defaultdict(list)
for log in result.data:
    cid = log.get('correlation_id')
    if cid and cid != 'system':
        requests[cid].append(log)

print(f"Unique requests: {len(requests)}")
print()

# Format header
header = f"{'#':>3} | {'Start Time':<12} | {'End Time':<12} | {'Dur':>6} | {'Query':<35} | {'Status':<6} | Error"
print(header)
print("-" * len(header) + "-" * 40)

request_list = []
for cid, logs in requests.items():
    logs.sort(key=lambda x: x['timestamp'])
    
    first = logs[0]
    last = logs[-1]
    
    # Parse timestamps
    try:
        start_ts = datetime.fromisoformat(first['timestamp'].replace('Z', '+00:00'))
        end_ts = datetime.fromisoformat(last['timestamp'].replace('Z', '+00:00'))
        duration = (end_ts - start_ts).total_seconds()
    except:
        start_ts = None
        end_ts = None
        duration = 0
    
    # Find query text from log messages
    query = None
    for log in logs:
        msg = log.get('message', '')
        # Look for query patterns like "query='...'"
        if "query='" in msg:
            match = re.search(r"query='([^']+)'", msg)
            if match:
                query = match.group(1)[:35]
                break
        # Look for "Search request:" or similar
        elif 'Search request:' in msg:
            # Extract the query from the message
            match = re.search(r"query['\"]?\s*[:=]\s*['\"]?([^'\"]+)", msg)
            if match:
                query = match.group(1)[:35]
                break
    
    # Check for errors
    has_error = any(log['level'] in ('ERROR', 'CRITICAL') for log in logs)
    error_msg = None
    if has_error:
        for log in logs:
            if log['level'] in ('ERROR', 'CRITICAL'):
                # Extract just the error description
                msg = log.get('message', '')
                # Remove timestamp prefix if present
                if ' | ' in msg:
                    parts = msg.split(' | ')
                    if len(parts) > 4:
                        msg = parts[-1]  # Get the actual message part
                error_msg = msg[:40]
                break
    
    request_list.append({
        'cid': cid,
        'start': start_ts,
        'end': end_ts,
        'duration': duration,
        'query': query or 'N/A',
        'has_error': has_error,
        'error_msg': error_msg,
    })

# Sort by start time
request_list.sort(key=lambda x: x['start'] if x['start'] else datetime.min.replace(tzinfo=timezone.utc))

# Print each request
for i, r in enumerate(request_list[:100], 1):
    start_str = r['start'].strftime('%H:%M:%S.%f')[:12] if r['start'] else 'N/A'
    end_str = r['end'].strftime('%H:%M:%S.%f')[:12] if r['end'] else 'N/A'
    status = 'ERROR' if r['has_error'] else 'OK'
    error = r['error_msg'] if r['error_msg'] else ''
    query = r['query'][:35] if r['query'] else 'N/A'
    dur = f"{r['duration']:.1f}s"
    
    print(f"{i:>3} | {start_str:<12} | {end_str:<12} | {dur:>6} | {query:<35} | {status:<6} | {error}")

# Summary
print()
print("=" * 80)
print("SUMMARY")
print("=" * 80)

total = len(request_list[:100])
errors = sum(1 for r in request_list[:100] if r['has_error'])
success = total - errors
durations = [r['duration'] for r in request_list[:100] if r['duration'] > 0]

print(f"Total requests: {total}")
print(f"Successful: {success}")
print(f"Errors: {errors}")

if durations:
    print(f"\nDuration stats:")
    print(f"  Min: {min(durations):.2f}s")
    print(f"  Max: {max(durations):.2f}s")
    print(f"  Avg: {sum(durations)/len(durations):.2f}s")

sys.stdout.close()
print(f"Output written to {output_file}", file=sys.__stdout__)
