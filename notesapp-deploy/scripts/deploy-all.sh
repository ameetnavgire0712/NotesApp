#!/bin/bash
# =============================================================================
# Full Deployment Script - Deploy All Services
# 
# This script deploys all components in order:
# 1. Cloudflare Worker (vector search + reranking)
# 2. Search Service (Fly.io, multi-region)
# 3. Upload Service (Fly.io, single region)
# 
# Run set-secrets.sh first to configure all secrets.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "Full NotesApp Deployment"
echo "=========================================="
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v fly &> /dev/null; then
    echo "❌ Fly CLI not found. Install from: https://fly.io/docs/hands-on/install-flyctl/"
    exit 1
fi

if ! command -v wrangler &> /dev/null; then
    echo "❌ Wrangler CLI not found. Install with: npm install -g wrangler"
    exit 1
fi

echo "✅ All CLIs installed"
echo ""

# Deploy in order
echo "Step 1/3: Deploying Cloudflare Worker..."
"$SCRIPT_DIR/deploy-worker.sh"
echo ""

echo "Step 2/3: Deploying Search Service..."
"$SCRIPT_DIR/deploy-search.sh"
echo ""

echo "Step 3/3: Deploying Upload Service..."
"$SCRIPT_DIR/deploy-upload.sh"
echo ""

echo "=========================================="
echo "✅ Full Deployment Complete!"
echo "=========================================="
echo ""
echo "Services deployed:"
echo "  - Worker: https://notesapp-vector-search.YOUR_SUBDOMAIN.workers.dev"
echo "  - Search: https://notesapp-search.fly.dev"
echo "  - Upload: https://notesapp-upload.fly.dev"
echo ""
echo "Next steps:"
echo "1. Set up custom domains (optional)"
echo "2. Run Supabase migration for logs table"
echo "3. Update frontend to use new endpoints"
echo ""
echo "Monitor logs:"
echo "  fly logs --app notesapp-search"
echo "  fly logs --app notesapp-upload"
echo "  wrangler tail"
