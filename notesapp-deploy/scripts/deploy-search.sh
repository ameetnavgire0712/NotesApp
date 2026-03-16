#!/bin/bash
# =============================================================================
# Deploy Search Service to Fly.io
# 
# Lightweight service (~200MB) without ML models.
# Deploys to 3 regions: iad (Virginia), fra (Frankfurt), sin (Singapore)
# 
# Prerequisites:
# - Fly CLI installed
# - Logged in to Fly
# - Secrets set (run set-secrets.sh first)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."

echo "=========================================="
echo "Deploying Search Service to Fly.io"
echo "=========================================="

cd "$PROJECT_DIR"

# Check if fly CLI is installed
if ! command -v fly &> /dev/null; then
    echo "❌ Fly CLI not found. Install from: https://fly.io/docs/hands-on/install-flyctl/"
    exit 1
fi

# Create app if it doesn't exist
if ! fly apps list | grep -q "notesapp-search"; then
    echo "Creating app notesapp-search..."
    fly apps create notesapp-search
fi

# Deploy using fly-search.toml
echo ""
echo "Building and deploying..."
fly deploy --config fly-search.toml --dockerfile Dockerfile.search

echo ""
echo "=========================================="
echo "✅ Search Service deployed!"
echo "=========================================="
echo ""
echo "Service info:"
fly status --app notesapp-search

echo ""
echo "Regions:"
fly regions list --app notesapp-search

echo ""
echo "Test with:"
echo "  curl https://notesapp-search.fly.dev/health"
echo ""
echo "For custom domain, run:"
echo "  fly certs create search-api.notesapp.com --app notesapp-search"
