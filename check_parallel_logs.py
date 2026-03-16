#!/usr/bin/env python3
"""Check logs for parallel test queries"""

import os
from supabase import create_client

url = 'https://fvacgkxvpsxesxyeddls.supabase.co'
key = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ2YWNna3h2cHN4ZXN4eWVkZGxzIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTczNjYyNjgxMiwiZXhwIjoyMDUyMjAyODEyfQ.JjJJfJbjgvCEuDefEVrODJX1E1NfALsLaBuXZcaPlz0'

client = create_client(url, key)

# Get logs for the specific test
result = client.table('user_activities').select('created_at, query, total_time_ms').ilike('query', '%parallel_201755%').order('created_at').execute()

print('START TIME ANALYSIS for parallel_201755 (10 parallel queries):')
print('='*80)
print(f'{"TIMESTAMP":<30} | {"DURATION":<10} | QUERY')
print('='*80)

for row in result.data:
    ts = row['created_at']
    dur = row.get('total_time_ms', 'N/A')
    q = row['query']
    print(f"{ts:<30} | {dur:>6}ms   | {q}")

print('='*80)
print(f'Total queries found: {len(result.data)}')

if len(result.data) >= 2:
    # Parse timestamps to analyze spread
    from datetime import datetime
    times = []
    for row in result.data:
        ts = row['created_at']
        # Parse ISO format
        dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        times.append(dt)
    
    first = min(times)
    last = max(times)
    spread = (last - first).total_seconds()
    
    print(f'\nTIME ANALYSIS:')
    print(f'  First query completed at: {first}')
    print(f'  Last query completed at:  {last}')
    print(f'  Completion spread:        {spread:.2f} seconds')
    
    if spread < 1:
        print(f'  ✅ PARALLEL - all completed within 1 second')
    elif spread < 3:
        print(f'  ⚠️  PARTIALLY PARALLEL - {spread:.1f}s spread')
    else:
        print(f'  ❌ SEQUENTIAL - {spread:.1f}s spread indicates queuing')
