import os
from supabase import create_client
from dotenv import load_dotenv

load_dotenv()
sb = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])

r = sb.table('search_traces').select(
    'query,path_taken,vector_count,reranked_count,final_count,error_type,error_message'
).order('created_at', desc=True).limit(10).execute()

print("Latest Search Traces:")
print("-" * 100)
for row in r.data:
    q = row['query'][:35].ljust(35)
    path = str(row['path_taken']).ljust(12)
    vec = str(row['vector_count']).rjust(3)
    reranked = str(row['reranked_count']).rjust(3)
    final = str(row['final_count']).rjust(3)
    err = row.get('error_type') or '-'
    print(f"Q: {q} path: {path} vec: {vec}  reranked: {reranked}  final: {final}  err: {err}")
    if row.get('error_message'):
        print(f"   Error: {row['error_message'][:80]}")
