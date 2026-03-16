"""Analyze the logs from the 100 query test - detailed timing."""
import os
import re
from collections import defaultdict, Counter
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()
supabase = create_client(os.getenv('SUPABASE_URL'), os.getenv('SUPABASE_SERVICE_KEY') or os.getenv('SUPABASE_KEY'))

# Test ran at 17:52:57 to 17:55:37 IST = 12:22:57 to 12:25:37 UTC
# But let's get logs from around that time
start_time = "2026-02-03T12:22:00"
end_time = "2026-02-03T12:26:00"

# Get all logs from the test period
result = supabase.table('application_logs').select('*').gte('timestamp', start_time).lte('timestamp', end_time).order('timestamp', desc=False).limit(2000).execute()

print(f"Total logs in test window: {len(result.data)}")
print()

# Analyze timing
print("=== TIMING ANALYSIS ===")

# Find rerank times
rerank_times = []
for log in result.data:
    msg = log.get('message', '')
    if 'Reranked' in msg and 'in' in msg:
        # Extract time: "Reranked 15 candidates via Voyage AI in 33.727s"
        match = re.search(r'in (\d+\.?\d*)s', msg)
        if match:
            rerank_times.append(float(match.group(1)))

if rerank_times:
    print(f"\nRerank API calls: {len(rerank_times)}")
    print(f"  Min time:  {min(rerank_times):.2f}s")
    print(f"  Max time:  {max(rerank_times):.2f}s")
    print(f"  Avg time:  {sum(rerank_times)/len(rerank_times):.2f}s")
    print(f"\nDistribution:")
    print(f"  <5s:   {sum(1 for t in rerank_times if t < 5)}")
    print(f"  5-10s: {sum(1 for t in rerank_times if 5 <= t < 10)}")
    print(f"  10-20s: {sum(1 for t in rerank_times if 10 <= t < 20)}")
    print(f"  20-30s: {sum(1 for t in rerank_times if 20 <= t < 30)}")
    print(f"  30-60s: {sum(1 for t in rerank_times if 30 <= t < 60)}")
    print(f"  >60s:  {sum(1 for t in rerank_times if t >= 60)}")

# Find worker search times
worker_times = []
vectorize_times = []
for log in result.data:
    msg = log.get('message', '')
    if 'Worker search:' in msg:
        # Extract times: "Worker search: 50 results in 13043.8ms (vectorize=316ms)"
        match = re.search(r'in (\d+\.?\d*)ms.*vectorize=(\d+)ms', msg)
        if match:
            worker_times.append(float(match.group(1)))
            vectorize_times.append(float(match.group(2)))

if worker_times:
    print(f"\n=== CLOUDFLARE WORKER CALLS ===")
    print(f"  Total calls: {len(worker_times)}")
    print(f"\n  Total Worker Response Time:")
    print(f"    Min:  {min(worker_times):.0f}ms ({min(worker_times)/1000:.1f}s)")
    print(f"    Max:  {max(worker_times):.0f}ms ({max(worker_times)/1000:.1f}s)") 
    print(f"    Avg:  {sum(worker_times)/len(worker_times):.0f}ms ({sum(worker_times)/len(worker_times)/1000:.1f}s)")
    print(f"\n  Vectorize-only Time:")
    print(f"    Min:  {min(vectorize_times):.0f}ms")
    print(f"    Max:  {max(vectorize_times):.0f}ms")
    print(f"    Avg:  {sum(vectorize_times)/len(vectorize_times):.0f}ms")
    
    # The difference is Workers AI embedding time
    embed_times = [w - v for w, v in zip(worker_times, vectorize_times)]
    print(f"\n  Workers AI Embedding Time (derived):")
    print(f"    Min:  {min(embed_times):.0f}ms ({min(embed_times)/1000:.1f}s)")
    print(f"    Max:  {max(embed_times):.0f}ms ({max(embed_times)/1000:.1f}s)") 
    print(f"    Avg:  {sum(embed_times)/len(embed_times):.0f}ms ({sum(embed_times)/len(embed_times)/1000:.1f}s)")

# Look for errors
errors = [log for log in result.data if log.get('level') == 'ERROR']
print(f"\n=== ERRORS ===")
print(f"Total errors: {len(errors)}")

# Group by type
error_types = Counter()
for e in errors:
    msg = e.get('message', '')
    filename = e.get('filename', '')
    if 'Worker embedding failed' in msg:
        error_types['Worker embedding failed'] += 1
    elif 'Voyage AI rerank failed' in msg:
        error_types['Voyage AI rerank failed'] += 1
    elif 'VECTOR_QUERY_ERROR' in msg:
        error_types['VECTOR_QUERY_ERROR'] += 1
    elif "'<' not supported" in msg:
        error_types['Type comparison error'] += 1
    elif 'timeout' in msg.lower():
        error_types['Timeout'] += 1
    else:
        error_types[f'Other ({filename})'] += 1

for etype, count in error_types.most_common():
    print(f"  {etype}: {count}")

# Show sample errors
if errors:
    print("\n=== SAMPLE ERRORS ===")
    for e in errors[:5]:
        msg = e.get('message', '')
        # Find actual error message after the pipe separators
        parts = msg.split(' | ')
        if len(parts) > 1:
            actual_msg = parts[-1]
        else:
            actual_msg = msg
        print(f"  - {actual_msg[:200]}")
