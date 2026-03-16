"""Check evaluation logs in database."""
import os
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()

url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY')

print(f'URL: {url[:30] if url else None}...')
print(f'Key exists: {bool(key)}')

if url and key:
    client = create_client(url, key)
    
    # Get unevaluated logs with full details
    result = client.table('rag_evaluation_logs').select('id, query, answer, retrieved_contexts, evaluated').eq('evaluated', False).order('created_at', desc=True).execute()
    
    print(f'\n=== Unevaluated queries: {len(result.data)} ===')
    for r in result.data:
        query = r.get('query', '')[:50]
        answer = str(r.get('answer', ''))[:60]
        ctx = r.get('retrieved_contexts', [])
        ctx_count = len(ctx) if isinstance(ctx, list) else 0
        
        print(f'Query: {query}')
        print(f'  Answer: {answer}')
        print(f'  Contexts: {ctx_count} items')
        if ctx and isinstance(ctx, list) and len(ctx) > 0:
            print(f'    First context: {str(ctx[0])[:80]}...')
        print()
else:
    print('Missing SUPABASE_URL or key!')
