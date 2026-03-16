# NotesApp Production Deployment

This project contains the deployment configuration for running NotesApp in a distributed production environment.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              FRONTEND                                        │
│                         (Vercel Pages)                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
                    ▼                               ▼
┌─────────────────────────────────┐   ┌─────────────────────────────────┐
│     SEARCH SERVICE (Fly.io)     │   │     UPLOAD SERVICE (Fly.io)     │
│                                 │   │                                 │
│  • Multi-region (iad, fra, sin) │   │  • Single region (iad)          │
│  • 512MB RAM (no ML models)     │   │  • 2GB RAM (with ML models)     │
│  • Auto-scale 1-10 machines     │   │  • Auto-scale 1-3 machines      │
│                                 │   │                                 │
│  Endpoints:                     │   │  Endpoints:                     │
│  - /api/v1/notes/search         │   │  - /api/v1/upload/*             │
│  - /api/v1/search/*             │   │  - /api/v1/notes (mutations)    │
│  - /api/v1/chat/*               │   │  - /api/v1/admin/*              │
│  - /api/v1/dashboard/*          │   │                                 │
└─────────────────────────────────┘   └─────────────────────────────────┘
                    │                               │
                    │                               │
                    ▼                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    CLOUDFLARE WORKER (Edge)                                  │
│                                                                              │
│  • Workers AI (BGE embeddings)     • Vectorize (vector search)              │
│  • Jina API (reranking)            • Global edge deployment                 │
│                                                                              │
│  Endpoints: /search, /search-rerank, /embed, /upsert, /delete               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         DATA LAYER                                           │
│                                                                              │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐          │
│  │    Supabase      │  │   Azure Blob     │  │   Cloudflare     │          │
│  │   PostgreSQL     │  │    Storage       │  │   Vectorize      │          │
│  │                  │  │                  │  │                  │          │
│  │  • Notes         │  │  • Files         │  │  • Embeddings    │          │
│  │  • Chunks        │  │  • Documents     │  │  • Fast search   │          │
│  │  • Logs          │  │  • Screenshots   │  │                  │          │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘          │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Project Structure

```
notesapp-deploy/
├── README.md                          # This file
├── fly-search.toml                    # Fly.io config for search service
├── fly-upload.toml                    # Fly.io config for upload service
├── Dockerfile.search                  # Lightweight image (~200MB)
├── Dockerfile.upload                  # Full image (~2GB with ML)
├── app-wrapper/
│   ├── main_search.py                 # Search service FastAPI wrapper
│   ├── main_upload.py                 # Upload service FastAPI wrapper
│   ├── requirements-search.txt        # Dependencies (no ML)
│   ├── requirements-upload.txt        # Dependencies (with ML)
│   └── services/
│       ├── supabase_logger.py         # Centralized logging to Supabase
│       └── worker_client.py           # HTTP client for Cloudflare Worker
├── cloudflare-worker/
│   ├── src/index.ts                   # Worker with Jina reranking
│   ├── wrangler.toml                  # Worker config
│   ├── package.json                   # Node dependencies
│   └── tsconfig.json                  # TypeScript config
├── supabase/
│   └── migrations/
│       └── 20260201000000_application_logs.sql
└── scripts/
    ├── set-secrets.sh / .ps1          # Configure Fly.io secrets
    ├── deploy-worker.sh               # Deploy Cloudflare Worker
    ├── deploy-search.sh               # Deploy search service
    ├── deploy-upload.sh               # Deploy upload service
    └── deploy-all.sh / .ps1           # Full deployment
```

## Quick Start

### Prerequisites

1. **Fly.io CLI**: `curl -L https://fly.io/install.sh | sh`
2. **Wrangler CLI**: `npm install -g wrangler`
3. **Logged in**: `fly auth login` and `wrangler login`

### Deployment Steps

```bash
# 1. Set secrets for Fly.io
./scripts/set-secrets.sh

# 2. Run Supabase migration
cd supabase && supabase db push

# 3. Deploy everything
./scripts/deploy-all.sh
```

Or on Windows PowerShell:
```powershell
.\scripts\set-secrets.ps1
.\scripts\deploy-all.ps1
```

## Service Details

### Search Service

- **URL**: `https://notesapp-search.fly.dev` (or `search-api.notesapp.com`)
- **Regions**: iad (Virginia), fra (Frankfurt), sin (Singapore)
- **Memory**: 512MB (no ML models loaded)
- **Endpoints**:
  - `POST /api/v1/notes/search` - Semantic search
  - `POST /api/v1/search/*` - RAG search
  - `POST /api/v1/chat/*` - Chat agent
  - `GET /api/v1/dashboard/*` - Analytics
  - `GET /api/v1/logs/*` - Log viewing

### Upload Service

- **URL**: `https://notesapp-upload.fly.dev` (or `upload-api.notesapp.com`)
- **Region**: iad (Virginia) only
- **Memory**: 2GB (sentence-transformers model)
- **Endpoints**:
  - `POST /api/v1/upload/*` - File upload
  - `POST/PUT/DELETE /api/v1/notes/*` - Note mutations
  - `POST /api/v1/admin/*` - Admin operations

### Cloudflare Worker

- **URL**: `https://notesapp-vector-search.YOUR_SUBDOMAIN.workers.dev`
- **Features**:
  - Workers AI (BGE embeddings)
  - Vectorize (vector search)
  - Jina API (reranking)
- **Endpoints**:
  - `POST /search` - Vector search only
  - `POST /search-rerank` - Search + rerank (recommended)
  - `POST /embed` - Single embedding
  - `POST /embed-batch` - Batch embeddings
  - `POST /upsert` - Upsert vectors
  - `POST /delete` - Delete vectors

## Environment Variables

### Search Service (Fly.io secrets)
```
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_SERVICE_KEY=eyJ...
SUPABASE_JWT_SECRET=xxx
GROQ_API_KEY=gsk_...
WORKER_URL=https://notesapp-vector-search.xxx.workers.dev
WORKER_API_KEY=xxx
```

### Upload Service (Fly.io secrets)
```
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_SERVICE_KEY=eyJ...
SUPABASE_JWT_SECRET=xxx
AZURE_STORAGE_CONNECTION_STRING=DefaultEndpointsProtocol=https;...
TENSORLAKE_API_KEY=xxx
WORKER_URL=https://notesapp-vector-search.xxx.workers.dev
WORKER_API_KEY=xxx
```

### Cloudflare Worker (wrangler secrets)
```
WORKER_API_KEY=xxx
JINA_API_KEY=jina_xxx
```

## Cost Estimates

| Service | Free Tier | Estimated Cost |
|---------|-----------|----------------|
| Fly.io Search | 3 shared VMs | ~$5/month |
| Fly.io Upload | 1 VM (2GB) | ~$15/month |
| Cloudflare Worker | 100k req/day | Free |
| Cloudflare Vectorize | 30M queries/mo | Free (beta) |
| Workers AI | 10k neurons/day | Free |
| Jina Reranker | - | ~$0.02/1k pairs |
| Supabase | 500MB, 50k MAU | Free |
| **Total** | | **~$20-25/month** |

## Monitoring

```bash
# Fly.io logs
fly logs --app notesapp-search
fly logs --app notesapp-upload

# Worker logs
wrangler tail

# Supabase logs
# Query application_logs table in Supabase dashboard
SELECT * FROM application_logs 
WHERE timestamp > NOW() - INTERVAL '1 hour'
ORDER BY timestamp DESC
LIMIT 100;
```

## Custom Domains

```bash
# Add custom domain to Fly.io
fly certs create search-api.notesapp.com --app notesapp-search
fly certs create upload-api.notesapp.com --app notesapp-upload

# Configure DNS (add CNAME records pointing to .fly.dev)
```
