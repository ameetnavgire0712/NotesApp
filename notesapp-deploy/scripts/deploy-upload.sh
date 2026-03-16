#!/bin/bash
# =============================================================================
# Deploy Upload Service to Fly.io
# 
# Full service (~2GB) with ML models for document processing.
# Deploys to single region: iad (Virginia)
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
echo "Deploying Upload Service to Fly.io"
echo "=========================================="

cd "$PROJECT_DIR"

# Check if fly CLI is installed
if ! command -v fly &> /dev/null; then
    echo "❌ Fly CLI not found. Install from: https://fly.io/docs/hands-on/install-flyctl/"
    exit 1
fi

# Create app if it doesn't exist
if ! fly apps list | grep -q "notesapp-upload"; then
    echo "Creating app notesapp-upload..."
    fly apps create notesapp-upload
fi

# Deploy using fly-upload.toml
echo ""
echo "Building and deploying (this may take a while - ~2GB image)..."
fly deploy --config fly-upload.toml --dockerfile Dockerfile.upload

echo ""
echo "=========================================="
echo "✅ Upload Service deployed!"
echo "=========================================="
echo ""
echo "Service info:"
fly status --app notesapp-upload

echo ""
echo "Note: First startup may take 30-60 seconds to load ML models."
echo ""
echo "Test with:"
echo "  curl https://notesapp-upload.fly.dev/health"
echo ""
echo "For custom domain, run:"
echo "  fly certs create upload-api.notesapp.com --app notesapp-upload"
