"""Apply migration to add reasoning columns to rag_evaluation_logs table."""
from app.core.config import get_settings
from supabase import create_client

s = get_settings()
c = create_client(s.supabase_url, s.supabase_service_key)

# Add reasoning columns using postgrest raw SQL
columns = [
    'faithfulness_reason',
    'context_precision_reason', 
    'context_recall_reason',
    'answer_relevancy_reason'
]

print("Adding reasoning columns to rag_evaluation_logs...")

for col in columns:
    try:
        # Use raw SQL via postgrest
        result = c.postgrest.rpc('exec_sql', {
            'sql': f'ALTER TABLE rag_evaluation_logs ADD COLUMN IF NOT EXISTS {col} TEXT'
        }).execute()
        print(f"  Added: {col}")
    except Exception as e:
        if 'does not exist' in str(e).lower() or '42883' in str(e):
            # exec_sql function doesn't exist, try direct table check
            print(f"  Note: exec_sql not available, checking column exists...")
            break
        print(f"  {col}: {e}")

# Verify columns by checking table schema
try:
    result = c.table('rag_evaluation_logs').select('*').limit(0).execute()
    print("\nMigration check complete. Run the SQL directly in Supabase SQL Editor if columns missing.")
except Exception as e:
    print(f"Error checking table: {e}")

print("\nTo add columns manually, run this SQL in Supabase SQL Editor:")
print("-" * 60)
print("""
ALTER TABLE rag_evaluation_logs 
ADD COLUMN IF NOT EXISTS faithfulness_reason TEXT,
ADD COLUMN IF NOT EXISTS context_precision_reason TEXT,
ADD COLUMN IF NOT EXISTS context_recall_reason TEXT,
ADD COLUMN IF NOT EXISTS answer_relevancy_reason TEXT;
""")
