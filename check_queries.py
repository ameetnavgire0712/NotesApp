import os
import json
from dotenv import load_dotenv
from supabase import create_client, Client

load_dotenv()
url = os.getenv('SUPABASE_URL')
key = os.getenv('SUPABASE_SERVICE_KEY')
supabase: Client = create_client(url, key)

# Check query status
queries = supabase.table('rag_evaluation_logs').select('id,query,evaluated,answer').execute()
print(f"Total queries: {len(queries.data)}")
evaluated = sum(1 for x in queries.data if x['evaluated'])
with_answers = sum(1 for x in queries.data if x['answer'] and x['answer'] not in [None, '', 'None'])
print(f"Evaluated: {evaluated}")
print(f"With answers: {with_answers}")
print("-" * 80)
for row in queries.data:
    has_answer = row['answer'] not in [None, '', 'None'] if row['answer'] else False
    print(f"Eval: {row['evaluated']}, Answer: {has_answer}, Query: {row['query'][:50]}...")
