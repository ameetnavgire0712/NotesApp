#!/bin/bash
# =============================================================================
# Set Fly.io Secrets for NotesApp Services
# 
# This script sets all required secrets for both search and upload services.
# Run this before deploying the services.
# 
# Prerequisites:
# - Fly CLI installed (`fly` or `flyctl`)
# - Logged in to Fly (`fly auth login`)
# - Apps created (`fly apps create notesapp-search` and `fly apps create notesapp-upload`)
# =============================================================================

set -e

echo "=========================================="
echo "Setting Fly.io Secrets for NotesApp"
echo "=========================================="

# Check if fly CLI is installed
if ! command -v fly &> /dev/null; then
    echo "❌ Fly CLI not found. Install from: https://fly.io/docs/hands-on/install-flyctl/"
    exit 1
fi

# Prompt for secrets if not set in environment
if [ -z "$SUPABASE_URL" ]; then
    read -p "Enter SUPABASE_URL: " SUPABASE_URL
fi

if [ -z "$SUPABASE_SERVICE_KEY" ]; then
    read -s -p "Enter SUPABASE_SERVICE_KEY: " SUPABASE_SERVICE_KEY
    echo
fi

if [ -z "$SUPABASE_JWT_SECRET" ]; then
    read -s -p "Enter SUPABASE_JWT_SECRET: " SUPABASE_JWT_SECRET
    echo
fi

if [ -z "$GROQ_API_KEY" ]; then
    read -s -p "Enter GROQ_API_KEY: " GROQ_API_KEY
    echo
fi

if [ -z "$WORKER_URL" ]; then
    read -p "Enter WORKER_URL (e.g., https://notesapp-vector-search.your-subdomain.workers.dev): " WORKER_URL
fi

if [ -z "$WORKER_API_KEY" ]; then
    read -s -p "Enter WORKER_API_KEY: " WORKER_API_KEY
    echo
fi

if [ -z "$AZURE_STORAGE_CONNECTION_STRING" ]; then
    read -s -p "Enter AZURE_STORAGE_CONNECTION_STRING: " AZURE_STORAGE_CONNECTION_STRING
    echo
fi

if [ -z "$TENSORLAKE_API_KEY" ]; then
    read -s -p "Enter TENSORLAKE_API_KEY: " TENSORLAKE_API_KEY
    echo
fi

echo ""
echo "Setting secrets for notesapp-search..."
fly secrets set \
    SUPABASE_URL="$SUPABASE_URL" \
    SUPABASE_SERVICE_KEY="$SUPABASE_SERVICE_KEY" \
    SUPABASE_JWT_SECRET="$SUPABASE_JWT_SECRET" \
    GROQ_API_KEY="$GROQ_API_KEY" \
    WORKER_URL="$WORKER_URL" \
    WORKER_API_KEY="$WORKER_API_KEY" \
    --app notesapp-search

echo "✅ Search service secrets set"

echo ""
echo "Setting secrets for notesapp-upload..."
fly secrets set \
    SUPABASE_URL="$SUPABASE_URL" \
    SUPABASE_SERVICE_KEY="$SUPABASE_SERVICE_KEY" \
    SUPABASE_JWT_SECRET="$SUPABASE_JWT_SECRET" \
    AZURE_STORAGE_CONNECTION_STRING="$AZURE_STORAGE_CONNECTION_STRING" \
    TENSORLAKE_API_KEY="$TENSORLAKE_API_KEY" \
    WORKER_URL="$WORKER_URL" \
    WORKER_API_KEY="$WORKER_API_KEY" \
    --app notesapp-upload

echo "✅ Upload service secrets set"

echo ""
echo "=========================================="
echo "✅ All secrets configured!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Deploy Worker: ./deploy-worker.sh"
echo "2. Deploy Search: ./deploy-search.sh"
echo "3. Deploy Upload: ./deploy-upload.sh"
