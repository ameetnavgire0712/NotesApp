"""Check if HNSW indexes exist in Supabase."""

from supabase import create_client
from app.core.config import get_settings

settings = get_settings()
supabase = create_client(settings.supabase_url, settings.supabase_service_key)

# Query pg_indexes directly via SQL
result = supabase.rpc('exec_sql', {
    'sql': """
        SELECT indexname, indexdef 
        FROM pg_indexes 
        WHERE schemaname = 'public' 
        AND tablename IN ('notes', 'note_chunks')
        AND indexdef LIKE '%hnsw%';
    """
}).execute()

print("=== HNSW INDEXES ===")
if result.data:
    for row in result.data:
        print(row)
else:
    print("No HNSW indexes found or exec_sql not available")
    print()
    print("Checking via information_schema...")
    
    # Alternative: Check via stats
    result2 = supabase.rpc('exec_sql', {
        'sql': """
            SELECT 
                indexrelid::regclass as index_name,
                reltuples as estimated_rows
            FROM pg_stat_user_indexes
            WHERE schemaname = 'public'
            AND relname IN ('notes', 'note_chunks');
        """
    }).execute()
    print(result2.data)
