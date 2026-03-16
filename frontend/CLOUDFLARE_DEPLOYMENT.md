# SecondBrain Frontend - Cloudflare Pages Deployment

## Overview

This frontend is a static HTML/CSS/JavaScript application designed to be deployed on **Cloudflare Pages** for global CDN distribution and high availability.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         CLOUDFLARE PAGES                                 │
│                    (Global Edge Network - 300+ PoPs)                     │
│                                                                          │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │
│   │   Tokyo     │  │   London    │  │  New York   │  │   Sydney    │   │
│   │   Edge      │  │   Edge      │  │   Edge      │  │   Edge      │   │
│   └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │
│                                                                          │
│   Static Assets: index.html, dashboard.html, *.js, *.css                │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ API Calls
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           FLY.IO BACKEND                                 │
│                    https://notesapp-search.fly.dev                       │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  FastAPI Backend                                                 │   │
│   │  - /api/v1/auth/*     (Authentication, API Keys)                │   │
│   │  - /api/v1/notes/*    (Notes CRUD, Stats)                       │   │
│   │  - /api/v1/chat/      (LLM Chat with Streaming)                 │   │
│   └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **Cloudflare Account** - Free tier is sufficient
2. **Wrangler CLI** (optional, for local preview):
   ```bash
   npm install -g wrangler
   ```

## Configuration

### 1. Update API URL

Edit `config.js` and set your production API URL:

```javascript
// config.js - Line 32
const PRODUCTION_API_URL = 'https://notesapp-search.fly.dev';  // Your Fly.io app
```

### 2. Update Supabase OAuth Redirect

In your **Supabase Dashboard** → **Authentication** → **URL Configuration**:

Add your Cloudflare Pages URL to **Redirect URLs**:
```
https://your-project.pages.dev/
https://your-custom-domain.com/
```

### 3. Update Backend CORS

In your FastAPI backend (`app/main.py`), update CORS origins:

```python
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://your-project.pages.dev",
        "https://your-custom-domain.com",
        "http://localhost:3000",  # For development
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
```

## Deployment Methods

### Method 1: GitHub Integration (Recommended)

1. **Connect to GitHub**:
   - Go to [Cloudflare Pages Dashboard](https://dash.cloudflare.com/?to=/:account/pages)
   - Click "Create a project" → "Connect to Git"
   - Select your repository

2. **Configure Build Settings**:
   - **Production branch**: `main`
   - **Build command**: *(leave empty - no build needed)*
   - **Build output directory**: `frontend`
   - **Root directory**: `/` or leave empty

3. **Deploy**: Push to `main` branch triggers automatic deployment

### Method 2: Direct Upload

1. **Via Dashboard**:
   - Go to Cloudflare Pages Dashboard
   - Click "Create a project" → "Direct Upload"
   - Upload the `frontend` folder

2. **Via Wrangler CLI**:
   ```bash
   cd frontend
   npx wrangler pages deploy . --project-name=secondbrain
   ```

### Method 3: GitHub Actions (CI/CD)

Create `.github/workflows/deploy-frontend.yml`:

```yaml
name: Deploy Frontend to Cloudflare Pages

on:
  push:
    branches: [main]
    paths:
      - 'frontend/**'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Deploy to Cloudflare Pages
        uses: cloudflare/wrangler-action@v3
        with:
          apiToken: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          accountId: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
          command: pages deploy frontend --project-name=secondbrain
```

**Required Secrets**:
- `CLOUDFLARE_API_TOKEN`: Create at Cloudflare Dashboard → Profile → API Tokens
- `CLOUDFLARE_ACCOUNT_ID`: Found in Cloudflare Dashboard URL

## Production Best Practices

### 1. Custom Headers (`_headers` file)

Create `frontend/_headers`:

```
# Security headers for all pages
/*
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=()

# Cache static assets aggressively
/*.js
  Cache-Control: public, max-age=31536000, immutable

/*.css
  Cache-Control: public, max-age=31536000, immutable

# Don't cache HTML (for updates)
/*.html
  Cache-Control: no-cache, no-store, must-revalidate

/
  Cache-Control: no-cache, no-store, must-revalidate
```

### 2. Redirects (`_redirects` file)

Create `frontend/_redirects`:

```
# SPA fallback (if needed in future)
# /*    /index.html   200

# Redirect www to non-www (if using custom domain)
# https://www.yourdomain.com/*  https://yourdomain.com/:splat  301
```

### 3. Custom Domain

1. Go to your Pages project → **Custom domains**
2. Add your domain (e.g., `app.secondbrain.com`)
3. Update DNS records as instructed
4. SSL is automatically provisioned

### 4. Environment-Specific Configs

For different environments (staging vs production):

**Option A: Multiple config files**
```
config.js           # Auto-detects environment
config.staging.js   # Override for staging
config.production.js # Override for production
```

**Option B: Cloudflare Pages Environment Variables**
- Pages Dashboard → Settings → Environment Variables
- Use `_worker.js` or Functions to inject config

## Local Development

```bash
cd frontend

# Option 1: Simple HTTP server
npx serve . -l 3000

# Option 2: Cloudflare Pages dev server (includes Functions support)
npx wrangler pages dev . --port 8788

# Option 3: Python
python -m http.server 3000
```

**Note**: For local development, ensure your backend is running and update `config.js`:
```javascript
const DEVELOPMENT_API_URL = '';  // Empty = same origin (use with proxy)
// OR
const DEVELOPMENT_API_URL = 'http://localhost:8000';  // Direct to backend
```

## Monitoring & Analytics

### Cloudflare Web Analytics (Free)

1. Pages Dashboard → Settings → Web Analytics
2. Enable to get:
   - Page views
   - Unique visitors
   - Performance metrics (Core Web Vitals)

### Error Tracking

Consider adding:
- **Sentry** for JavaScript error tracking
- **LogRocket** for session replay

## Troubleshooting

### CORS Errors
```
Access to fetch at 'https://api...' from origin 'https://...' has been blocked by CORS
```
**Solution**: Update backend CORS settings to include your Pages domain.

### OAuth Redirect Issues
```
Invalid redirect URI
```
**Solution**: Add your Pages URL to Supabase Auth redirect allowlist.

### Streaming Not Working
If chat streaming hangs or buffers:
- Cloudflare Pages handles `ReadableStream` correctly
- Check backend sends proper headers: `Content-Type: text/event-stream`
- Ensure no other proxies are buffering responses

### 404 on Page Refresh
For SPA-like behavior, add `_redirects`:
```
/*    /index.html   200
```

## File Structure

```
frontend/
├── index.html          # Landing page
├── dashboard.html      # Main app (chat, profile)
├── log-viewer.html     # Admin log viewer
├── styles.css          # Landing page styles
├── dashboard-styles.css # Dashboard dark theme
├── config.js           # ⭐ API configuration
├── auth.js             # Supabase authentication
├── dashboard.js        # API key management
├── dashboard-chat.js   # Chat functionality
├── package.json        # Dev dependencies
├── _headers            # Cloudflare custom headers
├── _redirects          # Cloudflare redirects
└── CLOUDFLARE_DEPLOYMENT.md  # This file
```

## Cost Estimation

| Tier | Requests/month | Bandwidth | Price |
|------|----------------|-----------|-------|
| Free | Unlimited | Unlimited | $0 |
| Pro | Unlimited | Unlimited | $20/mo (for additional features) |

**Cloudflare Pages Free Tier includes**:
- Unlimited requests
- Unlimited bandwidth
- 500 builds/month
- Automatic SSL
- Global CDN

For 1000+ concurrent users, the free tier is sufficient for static assets.

## Next Steps

1. [ ] Update `config.js` with your Fly.io backend URL
2. [ ] Create Cloudflare Pages project
3. [ ] Add custom headers (`_headers` file)
4. [ ] Update Supabase OAuth redirect URLs
5. [ ] Update backend CORS settings
6. [ ] Set up custom domain (optional)
7. [ ] Enable Web Analytics
