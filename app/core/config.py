from pydantic_settings import BaseSettings
from functools import lru_cache
import os


class Settings(BaseSettings):
    # Azure Blob Storage
    azure_storage_connection_string: str
    azure_storage_container: str

    # Supabase
    supabase_url: str
    supabase_service_key: str
    supabase_anon_key: str = ""  # For client-side auth flows
    supabase_jwt_secret: str = ""  # For JWT verification
    
    # Auth settings
    admin_user_id: str = "default_user"  # Admin user (has access to admin endpoints)

    # Tensorlake
    tensorlake_api_key: str

    # OpenAI
    openai_api_key: str

    # Groq (fast inference)
    groq_api_key: str = ""
    
    # Frontend URL (for generating clickable links)
    frontend_url: str = "http://localhost:3000"
    
    # Backend API URL (for direct document access)
    api_base_url: str = "http://localhost:8000"
    
    # CORS allowed origins (comma-separated list for production)
    # Example: "https://secondbrain.pages.dev,https://app.secondbrain.com"
    cors_origins: str = "*"
    
    # Local embeddings (BGE) - faster than OpenAI API
    use_local_embeddings: bool = True  # Set to False to use OpenAI embeddings
    
    # Worker embeddings - use Cloudflare Workers AI for embeddings (scales better for high concurrency)
    use_worker_embeddings: bool = True  # Set to True to use Workers AI instead of local model
    
    # Semantic chunking (Docling) - preserves document structure
    use_semantic_chunking: bool = True  # Set to False to use simple word-based chunking
    
    # Reranking
    use_reranker: bool = True  # Enable cross-encoder reranking for best quality
    
    # Cloudflare Vectorize Worker - Production vector search
    vectorize_worker_url: str = ""  # e.g., https://notesapp-vector-search.your-subdomain.workers.dev
    vectorize_worker_api_key: str = ""  # API key to authenticate with Worker
    vectorize_index_name: str = "notesapp-vectors"  # Name of your Vectorize index
    
    # Worker shared secret - used by Worker to authenticate proxy requests to Fly.io
    worker_api_key: str = ""  # Set via WORKER_API_KEY env var

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        case_sensitive = False
        extra = "ignore"


# Settings instance - recreated when module reloads
_settings = None

def get_settings() -> Settings:
    global _settings
    if _settings is None:
        _settings = Settings()
    return _settings
