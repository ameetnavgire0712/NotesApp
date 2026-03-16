# =============================================================================
# Set Fly.io Secrets for NotesApp Services (Windows PowerShell)
# 
# This script sets all required secrets for both search and upload services.
# Run this before deploying the services.
# 
# Prerequisites:
# - Fly CLI installed (`fly` or `flyctl`)
# - Logged in to Fly (`fly auth login`)
# - Apps created (`fly apps create notesapp-search` and `fly apps create notesapp-upload`)
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Setting Fly.io Secrets for NotesApp" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Check if fly CLI is installed
if (-not (Get-Command fly -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Fly CLI not found. Install from: https://fly.io/docs/hands-on/install-flyctl/" -ForegroundColor Red
    exit 1
}

# Prompt for secrets
$SUPABASE_URL = if ($env:SUPABASE_URL) { $env:SUPABASE_URL } else { Read-Host "Enter SUPABASE_URL" }
$SUPABASE_SERVICE_KEY = if ($env:SUPABASE_SERVICE_KEY) { $env:SUPABASE_SERVICE_KEY } else { Read-Host "Enter SUPABASE_SERVICE_KEY" -AsSecureString | ConvertFrom-SecureString -AsPlainText }
$SUPABASE_JWT_SECRET = if ($env:SUPABASE_JWT_SECRET) { $env:SUPABASE_JWT_SECRET } else { Read-Host "Enter SUPABASE_JWT_SECRET" -AsSecureString | ConvertFrom-SecureString -AsPlainText }
$GROQ_API_KEY = if ($env:GROQ_API_KEY) { $env:GROQ_API_KEY } else { Read-Host "Enter GROQ_API_KEY" -AsSecureString | ConvertFrom-SecureString -AsPlainText }
$WORKER_URL = if ($env:WORKER_URL) { $env:WORKER_URL } else { Read-Host "Enter WORKER_URL" }
$WORKER_API_KEY = if ($env:WORKER_API_KEY) { $env:WORKER_API_KEY } else { Read-Host "Enter WORKER_API_KEY" -AsSecureString | ConvertFrom-SecureString -AsPlainText }
$AZURE_STORAGE_CONNECTION_STRING = if ($env:AZURE_STORAGE_CONNECTION_STRING) { $env:AZURE_STORAGE_CONNECTION_STRING } else { Read-Host "Enter AZURE_STORAGE_CONNECTION_STRING" -AsSecureString | ConvertFrom-SecureString -AsPlainText }
$TENSORLAKE_API_KEY = if ($env:TENSORLAKE_API_KEY) { $env:TENSORLAKE_API_KEY } else { Read-Host "Enter TENSORLAKE_API_KEY" -AsSecureString | ConvertFrom-SecureString -AsPlainText }

Write-Host ""
Write-Host "Setting secrets for notesapp-search..." -ForegroundColor Yellow
fly secrets set `
    SUPABASE_URL="$SUPABASE_URL" `
    SUPABASE_SERVICE_KEY="$SUPABASE_SERVICE_KEY" `
    SUPABASE_JWT_SECRET="$SUPABASE_JWT_SECRET" `
    GROQ_API_KEY="$GROQ_API_KEY" `
    WORKER_URL="$WORKER_URL" `
    WORKER_API_KEY="$WORKER_API_KEY" `
    --app notesapp-search

Write-Host "✅ Search service secrets set" -ForegroundColor Green

Write-Host ""
Write-Host "Setting secrets for notesapp-upload..." -ForegroundColor Yellow
fly secrets set `
    SUPABASE_URL="$SUPABASE_URL" `
    SUPABASE_SERVICE_KEY="$SUPABASE_SERVICE_KEY" `
    SUPABASE_JWT_SECRET="$SUPABASE_JWT_SECRET" `
    AZURE_STORAGE_CONNECTION_STRING="$AZURE_STORAGE_CONNECTION_STRING" `
    TENSORLAKE_API_KEY="$TENSORLAKE_API_KEY" `
    WORKER_URL="$WORKER_URL" `
    WORKER_API_KEY="$WORKER_API_KEY" `
    --app notesapp-upload

Write-Host "✅ Upload service secrets set" -ForegroundColor Green

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "✅ All secrets configured!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Deploy Worker: .\deploy-worker.ps1"
Write-Host "2. Deploy Search: .\deploy-search.ps1"
Write-Host "3. Deploy Upload: .\deploy-upload.ps1"
