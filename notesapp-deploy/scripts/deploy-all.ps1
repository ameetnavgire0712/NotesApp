# =============================================================================
# Deploy All Services (Windows PowerShell)
# =============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Full NotesApp Deployment" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Yellow

if (-not (Get-Command fly -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Fly CLI not found. Install from: https://fly.io/docs/hands-on/install-flyctl/" -ForegroundColor Red
    exit 1
}

if (-not (Get-Command wrangler -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Wrangler CLI not found. Install with: npm install -g wrangler" -ForegroundColor Red
    exit 1
}

Write-Host "✅ All CLIs installed" -ForegroundColor Green
Write-Host ""

# Deploy Worker
Write-Host "Step 1/3: Deploying Cloudflare Worker..." -ForegroundColor Yellow
Set-Location "$ProjectDir\cloudflare-worker"

if (-not (Test-Path "node_modules")) {
    Write-Host "Installing dependencies..."
    npm install
}

wrangler deploy
Write-Host "✅ Worker deployed" -ForegroundColor Green
Write-Host ""

# Deploy Search
Write-Host "Step 2/3: Deploying Search Service..." -ForegroundColor Yellow
Set-Location $ProjectDir

# Create app if needed
$apps = fly apps list
if (-not ($apps -match "notesapp-search")) {
    fly apps create notesapp-search
}

fly deploy --config fly-search.toml --dockerfile Dockerfile.search
Write-Host "✅ Search service deployed" -ForegroundColor Green
Write-Host ""

# Deploy Upload
Write-Host "Step 3/3: Deploying Upload Service..." -ForegroundColor Yellow

if (-not ($apps -match "notesapp-upload")) {
    fly apps create notesapp-upload
}

fly deploy --config fly-upload.toml --dockerfile Dockerfile.upload
Write-Host "✅ Upload service deployed" -ForegroundColor Green
Write-Host ""

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "✅ Full Deployment Complete!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Services deployed:"
Write-Host "  - Worker: https://notesapp-vector-search.YOUR_SUBDOMAIN.workers.dev"
Write-Host "  - Search: https://notesapp-search.fly.dev"
Write-Host "  - Upload: https://notesapp-upload.fly.dev"
Write-Host ""
Write-Host "Monitor logs:"
Write-Host "  fly logs --app notesapp-search"
Write-Host "  fly logs --app notesapp-upload"
Write-Host "  wrangler tail"
