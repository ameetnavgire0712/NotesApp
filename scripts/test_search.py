"""Test search to see what's happening"""
import requests
import json
import logging

# Enable debug logging
logging.basicConfig(level=logging.DEBUG)

r = requests.post('http://127.0.0.1:8000/api/v1/search', json={
    'query': 'msc software', 
    'max_results': 20
})
data = r.json()

print(f"\n{'='*60}")
print(f"Documents returned: {len(data.get('documents', []))}")
print(f"Reasoning: {data.get('metadata', {}).get('reasoning', 'None')}")

print("\n=== Response Keys ===")
for key in data:
    print(f"  {key}: {type(data[key])}")

print("\n=== Agent Steps ===")
for step in data.get('agent_steps', []):
    print(f"Step {step['step_number']}: {step.get('tool_name', 'N/A')} - {step.get('action', 'N/A')} ({step['duration_ms']}ms)")

print("\n=== Final Documents ===")
for x in data.get('documents', []):
    print(f"  {x['note_id'][:8]}: {x.get('similarity_score', 0):.3f} - {x.get('tag', 'N/A')} - {x.get('title', 'N/A')[:50]}")
