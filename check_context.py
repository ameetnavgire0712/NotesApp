import os
from dotenv import load_dotenv
from supabase import create_client, Client

load_dotenv()
url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY')
supabase: Client = create_client(url, key)

# Check queries with answers - look at retrieved_contexts
result = supabase.table('rag_evaluation_logs').select('query,answer,retrieved_contexts').not_.is_('answer', 'null').limit(3).execute()
print(f"Queries with answers: {len(result.data)}")
print("=" * 80)
for row in result.data:
    print(f"Query: {row['query']}")
    print(f"Answer (first 100 chars): {str(row['answer'])[:100]}...")
    contexts = row.get('retrieved_contexts')
    if contexts:
        print(f"Contexts type: {type(contexts)}")
        if isinstance(contexts, list):
            print(f"Number of contexts: {len(contexts)}")
            for i, ctx in enumerate(contexts[:2]):
                print(f"  Context {i}: {str(ctx)[:200]}...")
        else:
            print(f"Contexts (first 300 chars): {str(contexts)[:300]}...")
    else:
        print("Contexts: None")
    print("-" * 80)
