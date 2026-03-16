# Cloudflare Worker Deployment Guide

This Worker runs at the Cloudflare edge (Mumbai for you) and provides low-latency vector search/upsert operations.

## Prerequisites

1. **Node.js 18+** installed
2. **Cloudflare account** with Vectorize enabled
3. **Wrangler CLI** (installed via npm)

## Step 1: Install Dependencies

```bash
cd cloudflare-worker
npm install
```

## Step 2: Login to Cloudflare

```bash
npx wrangler login
```

This opens a browser for authentication.

## Step 3: Verify Vectorize Index Exists

```bash
npx wrangler vectorize list
```

You should see `notesapp-vectors` in the list. If not, create it:

```bash
npx wrangler vectorize create notesapp-vectors --dimensions=768 --metric=cosine
```

## Step 4: Set the Worker API Key Secret

Generate a strong API key and set it as a secret:

```bash
# Generate a random key (or use your own)
# PowerShell: [System.Guid]::NewGuid().ToString() + [System.Guid]::NewGuid().ToString()

npx wrangler secret put WORKER_API_KEY
# Enter your API key when prompted
```

**Save this key!** You'll need it for the FastAPI app.

## Step 5: Deploy the Worker

```bash
npx wrangler deploy
```

This will output the Worker URL, something like:
```
https://notesapp-vectorize.YOUR_SUBDOMAIN.workers.dev
```

## Step 6: Configure FastAPI App

Add these to your `.env` file:

```env
# Cloudflare Worker Settings (for production Vectorize)
VECTORIZE_WORKER_URL=https://notesapp-vectorize.YOUR_SUBDOMAIN.workers.dev
VECTORIZE_WORKER_API_KEY=your-api-key-from-step-4
```

## Step 7: Test the Deployment

### Health Check
```bash
curl https://notesapp-vectorize.YOUR_SUBDOMAIN.workers.dev/health
```

Expected response:
```json
{"status": "healthy", "vectorize_bound": true, "ai_bound": true}
```

### Test Search (from your FastAPI app)
Start your FastAPI server and run a search query - it should now use the Worker.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        User in Mumbai                           │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    FastAPI App (Your Server)                    │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │          VectorizeWorkerService                         │   │
│   │  • Calls Worker instead of direct Vectorize API         │   │
│   │  • ~30-50ms latency (vs 600-2000ms direct)             │   │
│   └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                │ HTTPS (API key auth)
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│              Cloudflare Edge (BOM - Mumbai)                     │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │              notesapp-vectorize Worker                  │   │
│   │                                                         │   │
│   │  • /search: Generate embedding → Query Vectorize        │   │
│   │  • /upsert: Store vectors in Vectorize                  │   │
│   │  • /delete: Remove vectors by IDs                       │   │
│   │  • /health: Status check                                │   │
│   │                                                         │   │
│   │  Bindings:                                              │   │
│   │  • VECTORIZE → notesapp-vectors index                   │   │
│   │  • AI → Workers AI (BGE embedding model)                │   │
│   └─────────────────────────────────────────────────────────┘   │
│                          │                                      │
│                          │ Internal binding (~1ms)              │
│                          ▼                                      │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │              Vectorize Index                            │   │
│   │              notesapp-vectors                           │   │
│   │              768 dimensions, cosine                     │   │
│   │              316 vectors                                │   │
│   └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Latency Comparison

| Method | Latency from Mumbai | Why |
|--------|---------------------|-----|
| Direct Vectorize API | 600-2000ms | Routes to US central, TLS handshake overhead |
| Via Worker at Edge | 30-50ms | Worker runs at BOM, internal binding to Vectorize |

## Troubleshooting

### "Unauthorized" errors
- Verify `VECTORIZE_WORKER_API_KEY` in `.env` matches the secret in Cloudflare
- Check the Worker is deployed: `npx wrangler deployments list`

### "Vectorize not bound" in health check
- The Vectorize index might not exist: `npx wrangler vectorize list`
- Redeploy if needed: `npx wrangler deploy`

### Search returns empty results
- Check metadata indexes exist: `npx wrangler vectorize info notesapp-vectors`
- Re-run migration if needed: `python scripts/migrate_to_vectorize.py`

### Worker deployment fails
- Check wrangler.toml syntax
- Ensure your Cloudflare account has Workers and Vectorize enabled
- Check the AI binding is correct for the BGE model

## Monitoring

View real-time logs:
```bash
npx wrangler tail
```

View in Cloudflare Dashboard:
1. Go to Workers & Pages
2. Select `notesapp-vectorize`
3. View Analytics, Logs, and Errors

## Cost Estimate

| Component | Free Tier | Paid Usage |
|-----------|-----------|------------|
| Workers | 100,000 requests/day | $0.30/million after |
| Vectorize | 30M queries/month, 5M stored dimensions | $0.01/M queries after |
| Workers AI | 10,000 neurons/day free | ~$0.01/1000 embeddings after |

**Estimated monthly cost**: $0-5 for typical usage patterns.
