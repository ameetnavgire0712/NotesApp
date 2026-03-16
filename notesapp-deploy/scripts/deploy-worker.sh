#!/bin/bash
# =============================================================================
# Deploy Cloudflare Worker with Jina Reranking
# 
# This script deploys the enhanced Worker to Cloudflare.
# 
# Prerequisites:
# - Wrangler CLI installed (`npm install -g wrangler`)
# - Logged in to Cloudflare (`wrangler login`)
# - Vectorize index created (`wrangler vectorize create notesapp-vectors --dimensions=768 --metric=cosine`)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$SCRIPT_DIR/../cloudflare-worker"

echo "=========================================="
echo "Deploying Cloudflare Worker"
echo "=========================================="

cd "$WORKER_DIR"

# Check if wrangler is installed
if ! command -v wrangler &> /dev/null; then
    echo "❌ Wrangler CLI not found. Install with: npm install -g wrangler"
    exit 1
fi

# Install dependencies if needed
if [ ! -d "node_modules" ]; then
    echo "Installing dependencies..."
    npm install
fi

# Check if secrets are set
echo "Checking secrets..."
SECRETS=$(wrangler secret list 2>/dev/null || echo "")

if ! echo "$SECRETS" | grep -q "WORKER_API_KEY"; then
    echo "⚠️ WORKER_API_KEY not set. Setting now..."
    read -s -p "Enter WORKER_API_KEY: " API_KEY
    echo
    echo "$API_KEY" | wrangler secret put WORKER_API_KEY
fi

if ! echo "$SECRETS" | grep -q "JINA_API_KEY"; then
    echo "⚠️ JINA_API_KEY not set. Setting now..."
    read -s -p "Enter JINA_API_KEY: " JINA_KEY
    echo
    echo "$JINA_KEY" | wrangler secret put JINA_API_KEY
fi

# Deploy
echo ""
echo "Deploying Worker..."
wrangler deploy

echo ""
echo "=========================================="
echo "✅ Worker deployed successfully!"
echo "=========================================="
echo ""
echo "Endpoints available:"
echo "  - /health       - Health check"
echo "  - /search       - Vector search"
echo "  - /search-rerank - Search + Jina reranking"
echo "  - /embed        - Generate embedding"
echo "  - /embed-batch  - Batch embeddings"
echo "  - /upsert       - Upsert vectors"
echo "  - /delete       - Delete vectors"
echo ""
echo "Test with:"
echo "  curl https://notesapp-vector-search.YOUR_SUBDOMAIN.workers.dev/health"
