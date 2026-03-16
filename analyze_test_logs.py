"""Analyze the logs from the 100 query test."""
import os
import re
from collections import defaultdict
from datetime import datetime, timedelta
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()
supabase = create_client(os.getenv('SUPABASE_URL'), os.getenv('SUPABASE_SERVICE_KEY') or os.getenv('SUPABASE_KEY'))

# Get logs from the last 10 minutes
ten_min_ago = (datetime.utcnow() - timedelta(minutes=10)).isoformat()

result = supabase.table('application_logs').select('*').gte('timestamp', ten_min_ago).order('timestamp', desc=False).limit(2000).execute()

print(f"Total logs retrieved: {len(result.data)}")
print()

# Analyze errors
errors = [log for log in result.data if log.get('level') in ('ERROR', 'CRITICAL')]
print(f"Errors found: {len(errors)}")
if errors:
    print("\n=== ERRORS ===")
    for e in errors[:20]:
        ts = e.get('timestamp', '')[:19]
        msg = e.get('message', '')[:100]
        print(f"  {ts} | {msg}")

# Analyze timing
print("\n=== TIMING ANALYSIS ===")

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
    print(f"\nCloudflare Worker calls: {len(worker_times)}")
    print(f"  Total Worker Time:")
    print(f"    Min:  {min(worker_times):.0f}ms")
    print(f"    Max:  {max(worker_times):.0f}ms") 
    print(f"    Avg:  {sum(worker_times)/len(worker_times):.0f}ms")
    print(f"  Vectorize Time:")
    print(f"    Min:  {min(vectorize_times):.0f}ms")
    print(f"    Max:  {max(vectorize_times):.0f}ms")
    print(f"    Avg:  {sum(vectorize_times)/len(vectorize_times):.0f}ms")

# Count successful vs failed requests
search_200 = len([log for log in result.data if '200 OK' in log.get('message', '') and '/api/v1/search' in log.get('message', '')])
search_500 = len([log for log in result.data if '500' in log.get('message', '') and '/api/v1/search' in log.get('message', '')])

print(f"\n=== REQUEST SUMMARY ===")
print(f"  200 OK responses: {search_200}")
print(f"  500 errors:       {search_500}")

# Look for vector query errors
vector_errors = [log for log in result.data if 'VECTOR_QUERY_ERROR' in log.get('message', '')]
print(f"  Vectorize errors: {len(vector_errors)}")

# Show some vector errors
if vector_errors:
    print("\n=== VECTORIZE ERRORS ===")
    for e in vector_errors[:5]:
        ts = e.get('timestamp', '')[:19]
        msg = e.get('message', '')[:100]
        print(f"  {ts} | {msg}")
