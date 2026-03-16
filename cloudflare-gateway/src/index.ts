/**
 * NotesApp Edge Gateway Worker
 * 
 * Purpose: Rate limiting and proxy to Fly.io backend
 * 
 * Features:
 * - Per-API-key rate limiting (60 req/min)
 * - Global rate limiting (500 req/sec)
 * - Transparent proxy to Fly.io
 * - Health check endpoint
 */

export interface Env {
  RATE_LIMITER: DurableObjectNamespace;
  FLY_BACKEND_URL: string;
  RATE_LIMIT_PER_KEY_PER_MINUTE: string;
  RATE_LIMIT_GLOBAL_PER_SECOND: string;
}

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
};

// =============================================================================
// RATE LIMITER DURABLE OBJECT
// =============================================================================

interface RateLimitState {
  requests: number[];  // Timestamps of recent requests
}

export class RateLimiter implements DurableObject {
  state: DurableObjectState;
  
  constructor(state: DurableObjectState) {
    this.state = state;
  }
  
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const action = url.searchParams.get("action");
    
    if (action === "check") {
      const windowMs = parseInt(url.searchParams.get("windowMs") || "60000");
      const limit = parseInt(url.searchParams.get("limit") || "60");
      
      return await this.checkAndIncrement(windowMs, limit);
    }
    
    if (action === "stats") {
      return await this.getStats();
    }
    
    return new Response("Unknown action", { status: 400 });
  }
  
  async checkAndIncrement(windowMs: number, limit: number): Promise<Response> {
    const now = Date.now();
    const cutoff = now - windowMs;
    
    // Get current state
    let requests: number[] = await this.state.storage.get("requests") || [];
    
    // Filter to only requests within the window
    requests = requests.filter(ts => ts > cutoff);
    
    // Check if over limit
    if (requests.length >= limit) {
      const oldestInWindow = Math.min(...requests);
      const retryAfterMs = oldestInWindow + windowMs - now;
      const retryAfterSec = Math.ceil(retryAfterMs / 1000);
      
      return Response.json({
        allowed: false,
        current: requests.length,
        limit: limit,
        retryAfter: retryAfterSec
      });
    }
    
    // Add this request
    requests.push(now);
    await this.state.storage.put("requests", requests);
    
    return Response.json({
      allowed: true,
      current: requests.length,
      limit: limit,
      remaining: limit - requests.length
    });
  }
  
  async getStats(): Promise<Response> {
    const requests: number[] = await this.state.storage.get("requests") || [];
    const now = Date.now();
    
    // Count requests in last minute and last second
    const lastMinute = requests.filter(ts => ts > now - 60000).length;
    const lastSecond = requests.filter(ts => ts > now - 1000).length;
    
    return Response.json({
      lastMinute,
      lastSecond,
      totalTracked: requests.length
    });
  }
}

// =============================================================================
// RATE LIMIT CHECK FUNCTIONS
// =============================================================================

async function checkPerKeyRateLimit(
  env: Env,
  apiKey: string
): Promise<{ allowed: boolean; retryAfter?: number; remaining?: number }> {
  const limit = parseInt(env.RATE_LIMIT_PER_KEY_PER_MINUTE);
  const windowMs = 60000; // 1 minute
  
  // Use API key hash as Durable Object ID
  const keyHash = await hashString(apiKey);
  const id = env.RATE_LIMITER.idFromName(`key:${keyHash}`);
  const stub = env.RATE_LIMITER.get(id);
  
  const response = await stub.fetch(
    `http://internal/?action=check&windowMs=${windowMs}&limit=${limit}`
  );
  
  return await response.json();
}

async function checkGlobalRateLimit(
  env: Env
): Promise<{ allowed: boolean; retryAfter?: number; remaining?: number }> {
  const limit = parseInt(env.RATE_LIMIT_GLOBAL_PER_SECOND);
  const windowMs = 1000; // 1 second
  
  // Global rate limiter
  const id = env.RATE_LIMITER.idFromName("global");
  const stub = env.RATE_LIMITER.get(id);
  
  const response = await stub.fetch(
    `http://internal/?action=check&windowMs=${windowMs}&limit=${limit}`
  );
  
  return await response.json();
}

// Simple string hash
async function hashString(str: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(str);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("").substring(0, 16);
}

// =============================================================================
// PROXY TO FLY.IO
// =============================================================================

async function proxyToFly(
  request: Request,
  env: Env,
  path: string
): Promise<Response> {
  const targetUrl = `${env.FLY_BACKEND_URL}${path}`;
  
  // Clone the request with new URL
  const proxyRequest = new Request(targetUrl, {
    method: request.method,
    headers: request.headers,
    body: request.body,
    redirect: "follow",
  });
  
  try {
    const startTime = Date.now();
    const response = await fetch(proxyRequest);
    const duration = Date.now() - startTime;
    
    // Clone response and add gateway headers
    const newHeaders = new Headers(response.headers);
    newHeaders.set("X-Gateway-Duration-Ms", duration.toString());
    newHeaders.set("X-Gateway-Backend", "fly.io");
    
    // Add CORS headers
    for (const [key, value] of Object.entries(corsHeaders)) {
      newHeaders.set(key, value);
    }
    
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: newHeaders,
    });
  } catch (error) {
    console.error("Proxy error:", error);
    return Response.json(
      { error: "Gateway error: Failed to reach backend", detail: String(error) },
      { status: 502, headers: corsHeaders }
    );
  }
}

// =============================================================================
// HEALTH CHECK
// =============================================================================

async function handleHealth(env: Env): Promise<Response> {
  // Check global rate limiter stats
  const globalId = env.RATE_LIMITER.idFromName("global");
  const globalStub = env.RATE_LIMITER.get(globalId);
  const statsResponse = await globalStub.fetch("http://internal/?action=stats");
  const globalStats = await statsResponse.json() as { lastSecond: number; lastMinute: number };
  
  return Response.json({
    status: "healthy",
    service: "notesapp-gateway",
    backend: env.FLY_BACKEND_URL,
    rateLimits: {
      perKeyPerMinute: parseInt(env.RATE_LIMIT_PER_KEY_PER_MINUTE),
      globalPerSecond: parseInt(env.RATE_LIMIT_GLOBAL_PER_SECOND),
    },
    currentLoad: {
      globalRequestsLastSecond: globalStats.lastSecond,
      globalRequestsLastMinute: globalStats.lastMinute,
    },
    timestamp: new Date().toISOString(),
  }, { headers: corsHeaders });
}

// =============================================================================
// MAIN REQUEST HANDLER
// =============================================================================

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname + url.search;
    
    // Handle CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }
    
    // Health check (no auth, no rate limit)
    if (path === "/health" || path === "/") {
      return handleHealth(env);
    }
    
    // Extract API key
    const apiKey = request.headers.get("X-API-Key") || 
                   request.headers.get("Authorization")?.replace("Bearer ", "");
    
    // Determine if this path needs rate limiting
    // Rate limit search endpoints, passthrough others
    const rateLimitedPaths = [
      "/api/v1/search",
      "/api/v1/search/instant",
    ];
    
    const needsRateLimit = rateLimitedPaths.some(p => path.startsWith(p));
    
    if (needsRateLimit) {
      // Check global rate limit first
      const globalCheck = await checkGlobalRateLimit(env);
      if (!globalCheck.allowed) {
        console.log(`Global rate limit exceeded`);
        return Response.json(
          { 
            error: "Rate limit exceeded",
            message: "Too many requests globally. Please try again later.",
            retryAfter: globalCheck.retryAfter 
          },
          { 
            status: 429, 
            headers: { 
              ...corsHeaders, 
              "Retry-After": String(globalCheck.retryAfter || 1)
            } 
          }
        );
      }
      
      // Check per-key rate limit (only if API key provided)
      if (apiKey) {
        const keyCheck = await checkPerKeyRateLimit(env, apiKey);
        if (!keyCheck.allowed) {
          console.log(`Per-key rate limit exceeded for key: ${apiKey.substring(0, 10)}...`);
          return Response.json(
            { 
              error: "Rate limit exceeded",
              message: "Too many requests. Please slow down.",
              retryAfter: keyCheck.retryAfter,
              limit: "60 requests per minute"
            },
            { 
              status: 429, 
              headers: { 
                ...corsHeaders, 
                "Retry-After": String(keyCheck.retryAfter || 30)
              } 
            }
          );
        }
      }
    }
    
    // Proxy to Fly.io
    return proxyToFly(request, env, path);
  },
};
