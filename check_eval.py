"""Check latest evaluation log entry."""
from app.core.config import get_settings
from supabase import create_client

s = get_settings()
c = create_client(s.supabase_url, s.supabase_service_key)

r = c.table('rag_evaluation_logs').select('*').order('created_at', desc=True).limit(1).execute()
if r.data:
    d = r.data[0]
    print("=" * 60)
    print("LATEST EVALUATION LOG ENTRY")
    print("=" * 60)
    print(f"Query: {d.get('query')}")
    print(f"Answer: {(d.get('answer') or 'None')[:150]}...")
    print()
    print("SCORES:")
    print(f"  context_precision: {d.get('context_precision_score')}")
    print(f"  context_recall: {d.get('context_recall_score')}")
    print(f"  faithfulness: {d.get('faithfulness_score')}")
    print(f"  answer_relevancy: {d.get('answer_relevancy_score')}")
    print()
    print("REASONS:")
    print(f"  context_precision_reason: {d.get('context_precision_reason')}")
    print(f"  context_recall_reason: {d.get('context_recall_reason')}")
    print(f"  faithfulness_reason: {d.get('faithfulness_reason')}")
    print(f"  answer_relevancy_reason: {d.get('answer_relevancy_reason')}")
    print()
    print("RETRIEVED CONTEXTS:")
    contexts = d.get('retrieved_contexts', [])
    print(f"  Count: {len(contexts)}")
    for i, ctx in enumerate(contexts):
        title = ctx.get('title', 'No title')
        content = ctx.get('content', '')[:100]
        print(f"  [{i+1}] {title}")
        print(f"      Content: {content}...")
else:
    print("No data found")
