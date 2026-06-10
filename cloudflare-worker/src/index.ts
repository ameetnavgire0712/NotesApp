/**
 * NotesApp Vector Search Worker - Enhanced with Voyage AI Reranking
 * 
 * Runs at Cloudflare edge for low-latency vector operations.
 * - /mcp: MCP (Model Context Protocol) server for Claude Desktop
 * - /rag-search-auth: Full RAG pipeline with JWT/API key auth (for frontend direct calls)
 * - /rag-search: Full RAG pipeline (spell check + tags + hybrid search + synthesis)
 * - /search: Query vectors with optional filters
 * - /rerank: Rerank documents using Voyage AI
 * - /embed: Generate embedding for text
 * - /embed-batch: Generate embeddings for multiple texts
 * - /upsert: Insert or update vectors
 * - /delete: Remove vectors by ID
 * - /health: Health check
 */

import { handleRagSearch, handleRagSearchContinue, RagSearchEnv } from './rag-search';
import { handleMCP, MCPEnv } from './mcp-server';
import { validateAuth, AuthResult, AuthEnv } from './auth';
import { redact, maskEmail } from './log-redact';
import {
  handleAuthMe,
  handleListApiKeys,
  handleCreateApiKey,
  handleDeleteApiKey,
  handleRevokeAllSessions,
  handleListNotes,
  handleNotesStats,
  handleListTags,
  handleGetViewToken,
  handleNoteHighlights,
  handleRefreshInstagramPreview,
  handleDeleteNote,
  handleBulkDeleteNotes,
  handleNewspaperEdition,
  ApiEnv,
  ApiEnvWithVectorize,
} from './api-endpoints';
import {
  handleDashboardUsers,
  handleDashboardActivities,
  handleSearchTrace,
  handleTraceOperations,
  handleFileTrace,
  LogsEnv,
} from './logs-endpoints';
import {
  handleKpiSummary,
  handleKpiSearchTimeseries,
  handleKpiLatencyTimeseries,
  handleKpiUploadDetails,
  handleKpiSearchSources,
  handleKpiErrorDetails,
  handleKpiLatencyStats,
  handleKpiUploadLatencyStats,
  handleKpiUploadErrorDetails,
  AdminEnv,
} from './admin-kpi-endpoints';
import {
  handleUploadFileWithDO,
  handleUploadScreenshotWithDO,
  handleUploadQuickNoteWithDO,
  handleUploadWebpageWithDO,
  handleUploadSharedUrlWithDO,
  handleUploadStatus,
  handleUploadQuota,
  handleCancelUpload,
  handleTestTensorLake,
  handleEditQuickNoteWithDO,
  UploadEnv,
} from './upload-routes';
import {
  handleRecapGet,
  handleRecapSave,
  handleRecapListSaved,
  handleRecapGetSaved,
  handleRecapDeleteSaved,
  generateRecapForUser,
  listActiveUserIds,
  RecapEnv,
} from './recap';
import {
  consumeQuota,
  quotaExceededResponse,
  handleBillingStatus,
  handleBillingUpgradeDev,
  handleBillingCancel,
  handleBillingReactivate,
  handleBillingHistory,
  refundQuota,
  type BillingEnv,
} from './billing';
import {
  ensureUserProfileAndAcceptInvites,
  handleAcceptGroupInvite,
  handleApproveJoinRequest,
  handleCreateGroup,
  handleDeclineGroupInvite,
  handleDenyJoinRequest,
  handleDiscoverGroups,
  handleGetGroup,
  handleInviteToGroup,
  handleLeaveGroup,
  handleListGroups,
  handleListNotifications,
  handleMarkGroupSeen,
  handleReactToGroupSnap,
  handleRequestToJoinGroup,
  handleSearchUsers,
  handleShareSnapToGroup,
  handleTransferGroupAdmin,
  handleUploadGroupAvatar,
  handleUploadUserAvatar,
  type GroupsEnv,
} from './groups';
import { handleRegisterDeviceToken, type PushEnv } from './push-notifications';
import { handleAppBootstrap } from './bootstrap';

// Export Durable Object class for Cloudflare runtime
export { UploadProcessor } from './upload-processor';

export interface Env {
  VECTORIZE: Vectorize;
  AI: Ai;
  WORKER_API_KEY: string;
  VOYAGE_API_KEY: string;
  GROQ_API_KEY: string;  // For RAG search LLM calls
  EMBEDDING_MODEL: string;
  BACKEND_URL?: string;  // DEPRECATED: No longer used, logs go to Supabase directly
  LOG_ENABLED?: string;  // "true" to enable logging to backend
  EMBEDDING_CACHE: KVNamespace;  // KV namespace for embedding cache
  SEARCH_CACHE: KVNamespace;  // KV namespace for search results cache
  TAGS_CACHE: KVNamespace;  // KV namespace for user tags cache
  SYNTHESIS_CACHE: KVNamespace;  // KV namespace for synthesis cache
  SUPABASE_URL: string;  // Supabase project URL for keyword search
  SUPABASE_SERVICE_KEY: string;  // Supabase service role key
  SUPABASE_JWT_SECRET: string;  // Supabase JWT secret for validating user tokens
  AZURE_STORAGE_CONNECTION_STRING?: string;  // For generating Azure blob SAS URLs
  AZURE_STORAGE_CONTAINER?: string;  // Azure blob container name
  AZURE_THUMBNAILS_CONTAINER?: string;  // Public thumbnail blob container name
  TENSORLAKE_API_KEY?: string;  // TensorLake document conversion API key
  SENDGRID_API_KEY?: string;  // SendGrid API key for group email invites
  SENDGRID_FROM_EMAIL?: string;  // Verified SendGrid sender email
  FIREBASE_PROJECT_ID?: string;  // Firebase project id for FCM pushes
  FIREBASE_CLIENT_EMAIL?: string;  // Firebase service account client email
  FIREBASE_PRIVATE_KEY?: string;  // Firebase service account private key
  YOUTUBE_API_KEY?: string;  // Official YouTube Data API key for compliant enrichment
  INSTAGRAM_OEMBED_ACCESS_TOKEN?: string;  // Official Meta token for Instagram oEmbed previews
  UPLOAD_PROCESSOR: DurableObjectNamespace;  // Durable Object for long-running uploads
  CHAT_SESSIONS: KVNamespace;  // KV namespace for chat conversation memory
  THUMBNAIL_FOLDERS?: KVNamespace;  // user_id -> opaque public thumbnail folder id

  // Cloudflare Rate Limiting bindings (Workers built-in, not WAF).
  // Limits are per-key, sliding-window. Cheap to invoke (single edge call).
  // Tuned to be permissive for normal humans, hostile to scripted abuse.
  //   UPLOAD_RATELIMIT — 30 requests / minute per user_id, applied to
  //                      every /api/v1/upload/* endpoint.
  //   SEARCH_RATELIMIT — 120 requests / minute per user_id, applied to
  //                      /rag-search-auth + /rag-search.
  // Both are optional so local `wrangler dev` and any environment that
  // hasn't been redeployed yet still works.
  UPLOAD_RATELIMIT?: RateLimit;
  SEARCH_RATELIMIT?: RateLimit;
}

// Cloudflare's built-in rate-limit binding shape (workers ratelimit API).
// Minimal interface; full type ships with `@cloudflare/workers-types`
// but is not yet stable across all versions, so we declare just what we use.
interface RateLimit {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

interface SearchRequest {
  query?: string;           // Text query (will generate embedding)
  embedding?: number[];     // Pre-computed embedding (768-dim)
  user_id?: string;
  tag?: string;
  limit?: number;
}

interface UpsertRequest {
  vectors: Array<{
    id: string;
    values?: number[];      // Pre-computed embedding
    text?: string;          // Text to embed (if values not provided)
    metadata: Record<string, unknown>;
  }>;
}

interface DeleteRequest {
  ids: string[];
}

interface RerankRequest {
  query: string;
  documents: string[];
  model?: string;
  top_k?: number;
  user_id?: string;  // Optional: for logging/tracing
}

interface EmbedRequest {
  text: string;
  user_id?: string;  // Optional: for logging/tracing
}

interface EmbedBatchRequest {
  texts: string[];
  user_id?: string;  // Optional: for logging/tracing
}

// Hybrid search request - combines embed + search + rerank in one call
interface HybridSearchRequest {
  query: string;           // Text query (required)
  user_id?: string;        // Filter by user
  tag?: string;            // Filter by tag
  limit?: number;          // Final results to return (default 10)
  rerank?: boolean;        // Enable reranking (default true)
  rerank_top_k?: number;   // How many to rerank per batch (default 50)
  rerank_offset?: number;  // Skip first N chunks before reranking (for pagination)
  retrieval_limit?: number; // How many chunks to retrieve before filtering (default 500)
  debug?: boolean;         // Return intermediate data for debugging
  correlation_id?: string; // Backend correlation ID for trace linking
  seen_doc_ids?: string[]; // Document IDs already seen (for continuation filtering)
}

interface VoyageRerankResponse {
  object: string;
  model: string;
  usage: { total_tokens: number };
  data: Array<{
    index: number;
    relevance_score: number;
    document?: string;
  }>;
}

// CORS headers for cross-origin requests
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
};

// Generate unique request ID
function generateRequestId(): string {
  return `wr_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
}

// Log entry interface
interface WorkerLogEntry {
  request_id: string;
  timestamp: string;
  endpoint: string;
  method: string;
  user_id?: string;
  query?: string;
  timing: Record<string, number>;
  result: Record<string, unknown>;
  error?: string;
}

// Search trace entry - detailed logging for debugging
interface SearchTraceEntry {
  correlation_id: string;
  user_id: string;
  query: string;
  query_corrected?: string;
  
  // Timestamps for each phase (ISO format)
  request_received_at?: string;    // When request arrived at Worker
  auth_started_at?: string;        // When auth validation started
  auth_completed_at?: string;      // When auth validation completed
  embedding_started_at?: string;   // When embedding generation started
  search_started_at?: string;      // When vector/keyword search started
  rerank_started_at?: string;      // When reranking started
  response_sent_at?: string;       // When response was sent
  
  // Timing durations (ms)
  timing_total_ms?: number;
  timing_auth_ms?: number;         // Auth validation duration
  timing_embedding_ms?: number;
  timing_vector_search_ms?: number;
  timing_keyword_search_ms?: number;
  timing_rerank_ms?: number;
  timing_worker_ms?: number;
  
  // Auth details
  auth_method?: string;            // 'jwt', 'api_key', 'worker_key'
  auth_user_email?: string;        // User email if available
  
  // Cache status
  embedding_cached: boolean;
  search_cached: boolean;
  
  // Candidates
  vector_candidates?: Array<Record<string, any>>;
  keyword_candidates?: Array<Record<string, any>>;
  combined_candidates?: Array<Record<string, any>>;
  reranked_candidates?: Array<Record<string, any>>;
  final_results?: Array<Record<string, any>>;
  
  // Counts
  vector_count?: number;
  keyword_count?: number;
  combined_count?: number;
  reranked_count?: number;
  final_count?: number;
  
  // Thresholds
  min_vector_threshold?: number;
  min_rerank_threshold?: number;
  
  // Source info
  source_worker?: string;
  request_path?: string;
}

// Send log to Supabase worker_logs table (fire and forget)
async function sendLogToBackend(entry: WorkerLogEntry, env: Env, ctx: ExecutionContext): Promise<void> {
  if (env.LOG_ENABLED !== "true" || !env.SUPABASE_URL || !env.SUPABASE_SERVICE_KEY) {
    return;
  }
  
  // Use waitUntil so logging doesn't delay the response
  ctx.waitUntil(
    (async () => {
      try {
        const response = await fetch(`${env.SUPABASE_URL}/rest/v1/worker_logs`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "apikey": env.SUPABASE_SERVICE_KEY,
            "Authorization": `Bearer ${env.SUPABASE_SERVICE_KEY}`,
            "Prefer": "return=minimal",
          },
          body: JSON.stringify({
            request_id: entry.request_id,
            user_id: entry.user_id,
            // PII scrub: queries are free-form user input and may contain
            // emails / tokens copy-pasted by accident. Always redact before
            // persisting.
            query: entry.query ? redact(entry.query) : entry.query,
            endpoint: entry.endpoint,
            method: entry.method,
            status_code: entry.status_code,
            duration_ms: entry.duration_ms,
            metadata: entry.metadata || {},
          }),
        });
        if (!response.ok) {
          console.error("Failed to log to Supabase worker_logs:", response.status);
        }
      } catch (err) {
        console.error("Failed to send log to Supabase:", err);
      }
    })()
  );
}

// Send search trace to Supabase search_traces table (fire and forget)
async function sendSearchTraceToBackend(trace: SearchTraceEntry, env: Env, ctx: ExecutionContext): Promise<void> {
  if (env.LOG_ENABLED !== "true" || !env.SUPABASE_URL || !env.SUPABASE_SERVICE_KEY) {
    return;
  }
  
  // Use waitUntil so logging doesn't delay the response
  ctx.waitUntil(
    (async () => {
      try {
        const response = await fetch(`${env.SUPABASE_URL}/rest/v1/search_traces`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "apikey": env.SUPABASE_SERVICE_KEY,
            "Authorization": `Bearer ${env.SUPABASE_SERVICE_KEY}`,
            "Prefer": "return=minimal",
          },
          body: JSON.stringify({
            correlation_id: trace.correlation_id,
            user_id: trace.user_id,
            // PII scrub: redact the user-typed query + any spellchecked variant
            // before they hit the search_traces table.
            query: trace.query ? redact(trace.query) : trace.query,
            query_corrected: trace.query_corrected ? redact(trace.query_corrected) : trace.query_corrected,
            // Timestamps for each phase
            request_received_at: trace.request_received_at,
            auth_started_at: trace.auth_started_at,
            auth_completed_at: trace.auth_completed_at,
            embedding_started_at: trace.embedding_started_at,
            search_started_at: trace.search_started_at,
            rerank_started_at: trace.rerank_started_at,
            response_sent_at: trace.response_sent_at,
            // Timing durations
            timing_total_ms: trace.timing_total_ms,
            timing_auth_ms: trace.timing_auth_ms,
            timing_embedding_ms: trace.timing_embedding_ms,
            timing_vector_search_ms: trace.timing_vector_search_ms,
            timing_keyword_search_ms: trace.timing_keyword_search_ms,
            timing_rerank_ms: trace.timing_rerank_ms,
            // Auth details
            auth_method: trace.auth_method,
            // Mask email to first-char + domain so support can still correlate
            // a trace to a user without storing the full address in the trace
            // table that loads in the admin dashboard.
            auth_user_email: trace.auth_user_email ? maskEmail(trace.auth_user_email) : trace.auth_user_email,
            // Cache and counts
            embedding_cached: trace.embedding_cached,
            vector_count: trace.vector_count,
            keyword_count: trace.keyword_count,
            final_count: trace.final_count,
            source_worker: trace.source_worker || "cloudflare-worker",
            request_path: trace.request_path,
          }),
        });
        if (!response.ok) {
          console.error("Failed to log to Supabase search_traces:", response.status);
        }
      } catch (err) {
        console.error("Failed to send search trace to Supabase:", err);
      }
    })()
  );
}

// Short hash for compact chunk_ids (6-char base36, ~2.1B unique values)
function shortHash(s: string): string {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = ((h << 5) - h + s.charCodeAt(i)) | 0;
  }
  return (h >>> 0).toString(36).padStart(6, '0').slice(0, 6);
}

// Validate API key
function validateApiKey(request: Request, env: Env): boolean {
  const apiKey = request.headers.get("X-API-Key") || 
                 request.headers.get("Authorization")?.replace("Bearer ", "");
  return apiKey === env.WORKER_API_KEY;
}

// Validate user API key (na_* format) against Supabase
async function validateUserApiKey(apiKey: string, env: Env): Promise<{ valid: boolean; user_id?: string }> {
  if (!apiKey || !(apiKey.startsWith('na_') || apiKey.startsWith('ina_'))) {
    return { valid: false };
  }
  
  try {
    // Hash the API key using SHA-256 (keys are stored hashed in the database)
    const encoder = new TextEncoder();
    const data = encoder.encode(apiKey);
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const hashedKey = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
    
    const response = await fetch(`${env.SUPABASE_URL}/rest/v1/user_api_keys?api_key=eq.${hashedKey}&select=user_id,is_active`, {
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });
    
    if (!response.ok) {
      return { valid: false };
    }
    
    const keys = await response.json() as Array<{ user_id: string; is_active: boolean }>;
    if (keys.length === 0 || !keys[0].is_active) {
      return { valid: false };
    }
    
    return { valid: true, user_id: keys[0].user_id };
  } catch (e) {
    console.error('API key validation error:', e);
    return { valid: false };
  }
}

// ============================================================================
// Extension Timing Handler - Updates search_traces with Chrome extension timing
// ============================================================================
interface ExtensionTimingRequest {
  correlation_id: string;
  query?: string;
  timing_total_flow_ms: number;      // TRUE total from navigation start
  timing_page_load_ms?: number;       // Time for Google page to load
  timing_extension_only_ms?: number;  // Time in extension after page load
  timing_settings_check_ms?: number;
  timing_backend_search_ms?: number;
  timing_notification_ms?: number;
  timing_delay_ms?: number;
  timing_backend_reported_ms?: number;
  results_count?: number;
  source?: string;
}

async function handleExtensionTiming(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  try {
    // Validate auth - uses the shared validateAuth function (supports JWT, API key, worker key)
    const authResult = await validateAuth(request, env as AuthEnv);
    
    if (!authResult.authenticated) {
      return new Response(
        JSON.stringify({ success: false, error: authResult.error || "Authentication required" }),
        { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    const timing = await request.json() as ExtensionTimingRequest;
    
    if (!timing.correlation_id) {
      return new Response(
        JSON.stringify({ success: false, error: "correlation_id required" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Update the existing search trace with extension timing data
    const updateData: Record<string, any> = {
      extension_total_flow_ms: timing.timing_total_flow_ms,  // TRUE total from nav start
      extension_settings_check_ms: timing.timing_settings_check_ms,
      extension_backend_search_ms: timing.timing_backend_search_ms,
      extension_notification_ms: timing.timing_notification_ms,
      extension_delay_ms: timing.timing_delay_ms,
      extension_source: timing.source || 'chrome-extension',
    };
    
    // Add page load time if available (new field)
    if (timing.timing_page_load_ms !== undefined) {
      updateData.extension_page_load_ms = timing.timing_page_load_ms;
    }
    
    // Fire and forget - update search_traces in background
    ctx.waitUntil(
      (async () => {
        try {
          const response = await fetch(
            `${env.SUPABASE_URL}/rest/v1/search_traces?correlation_id=eq.${timing.correlation_id}`,
            {
              method: "PATCH",
              headers: {
                "Content-Type": "application/json",
                "apikey": env.SUPABASE_SERVICE_KEY,
                "Authorization": `Bearer ${env.SUPABASE_SERVICE_KEY}`,
                "Prefer": "return=minimal",
              },
              body: JSON.stringify(updateData),
            }
          );
          
          if (!response.ok) {
            console.error("Failed to update search_traces with extension timing:", response.status);
          } else {
            console.log(`[Extension Timing] Updated ${timing.correlation_id}`);
          }
        } catch (err) {
          console.error("Extension timing update error:", err);
        }
      })()
    );
    
    // Log detailed timing breakdown
    const pageLoad = timing.timing_page_load_ms || 0;
    const backendSearch = timing.timing_backend_search_ms || 0;
    const totalFlow = timing.timing_total_flow_ms;
    
    console.log(`[Extension Timing] ${timing.correlation_id}: Total=${totalFlow}ms (PageLoad=${pageLoad}ms + BackendCall=${backendSearch}ms + Other)`);
    
    return new Response(
      JSON.stringify({
        success: true,
        correlation_id: timing.correlation_id,
        timing_total_ms: totalFlow,
        timing_page_load_ms: pageLoad,
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  } catch (e) {
    console.error("Extension timing error:", e);
    return new Response(
      JSON.stringify({ success: false, error: String(e) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Generate embedding using Workers AI
async function generateEmbedding(text: string, env: Env): Promise<{ embedding: number[], time_ms: number }> {
  const start = Date.now();
  
  // Add query prefix for BGE model
  const queryText = `Represent this sentence for searching relevant passages: ${text}`;
  
  const response = await env.AI.run(env.EMBEDDING_MODEL as any, {
    text: [queryText],
  });
  
  const embedding = (response as any).data[0];
  const time_ms = Date.now() - start;
  console.log(`Embedding generated in ${time_ms}ms, dim=${embedding.length}`);
  
  return { embedding, time_ms };
}

// Embedding cache helpers
const EMBEDDING_CACHE_TTL = 3600; // 1 hour in seconds

function getCacheKey(query: string): string {
  // Normalize and hash the query for cache key
  const normalized = query.toLowerCase().trim();
  // Simple hash using built-in - good enough for cache key
  let hash = 0;
  for (let i = 0; i < normalized.length; i++) {
    const char = normalized.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash; // Convert to 32bit integer
  }
  return `emb_${hash.toString(16)}`;
}

async function getCachedEmbedding(query: string, env: Env): Promise<number[] | null> {
  try {
    const key = getCacheKey(query);
    const cached = await env.EMBEDDING_CACHE.get(key, "json");
    if (cached) {
      console.log(`Cache HIT for query: "${query.substring(0, 30)}..."`);
      return cached as number[];
    }
    console.log(`Cache MISS for query: "${query.substring(0, 30)}..."`);
    return null;
  } catch (e) {
    console.error("Cache read error:", e);
    return null; // Graceful degradation
  }
}

async function setCachedEmbedding(query: string, embedding: number[], env: Env, ctx: ExecutionContext): Promise<void> {
  try {
    const key = getCacheKey(query);
    // Use waitUntil so caching doesn't delay response
    ctx.waitUntil(
      env.EMBEDDING_CACHE.put(key, JSON.stringify(embedding), { expirationTtl: EMBEDDING_CACHE_TTL })
    );
    console.log(`Cached embedding for: "${query.substring(0, 30)}..."`);
  } catch (e) {
    console.error("Cache write error:", e);
    // Graceful degradation - continue without caching
  }
}

// ===== SEARCH RESULTS CACHE =====
const SEARCH_CACHE_TTL = 300; // 5 minutes in seconds

// Generate cache key for search results
function getSearchCacheKey(query: string, userId: string, limit: number, tag?: string): string {
  const normalized = query.toLowerCase().trim();
  let hash = 0;
  const keyString = `${normalized}:${userId}:${limit}:${tag || ''}`;
  for (let i = 0; i < keyString.length; i++) {
    const char = keyString.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash;
  }
  return `search_${userId.substring(0, 8)}_${hash.toString(16)}`;
}

// Get cached search results
async function getCachedSearchResults(
  query: string, 
  userId: string, 
  limit: number, 
  tag: string | undefined, 
  env: Env
): Promise<{ results: any, cached_at: number } | null> {
  try {
    const key = getSearchCacheKey(query, userId, limit, tag);
    const cached = await env.SEARCH_CACHE.get(key, "json");
    if (cached) {
      console.log(`Search cache HIT for: "${query.substring(0, 30)}..." user=${userId.substring(0, 8)}`);
      return cached as { results: any, cached_at: number };
    }
    console.log(`Search cache MISS for: "${query.substring(0, 30)}..." user=${userId.substring(0, 8)}`);
    return null;
  } catch (e) {
    console.error("Search cache read error:", e);
    return null;
  }
}

// Store search results in cache
async function setCachedSearchResults(
  query: string,
  userId: string,
  limit: number,
  tag: string | undefined,
  results: any,
  env: Env,
  ctx: ExecutionContext
): Promise<void> {
  try {
    const key = getSearchCacheKey(query, userId, limit, tag);
    const cacheData = {
      results,
      cached_at: Date.now()
    };
    ctx.waitUntil(
      env.SEARCH_CACHE.put(key, JSON.stringify(cacheData), { expirationTtl: SEARCH_CACHE_TTL })
    );
    console.log(`Cached search results for: "${query.substring(0, 30)}..." user=${userId.substring(0, 8)}`);
  } catch (e) {
    console.error("Search cache write error:", e);
  }
}

// Invalidate search cache for a user (by setting a version)
// KV doesn't support prefix deletion, so we use versioning
async function getUserCacheVersion(userId: string, env: Env): Promise<string> {
  try {
    const version = await env.SEARCH_CACHE.get(`version_${userId}`);
    return version || "0";
  } catch {
    return "0";
  }
}

async function invalidateUserSearchCache(userId: string, env: Env): Promise<void> {
  const newVersion = Date.now().toString();
  await env.SEARCH_CACHE.put(`version_${userId}`, newVersion);
  console.log(`Invalidated search cache for user ${userId.substring(0, 8)}, new version: ${newVersion}`);
}

// Updated cache key that includes version
async function getVersionedSearchCacheKey(
  query: string, 
  userId: string, 
  limit: number, 
  tag: string | undefined, 
  env: Env
): Promise<string> {
  const version = await getUserCacheVersion(userId, env);
  const normalized = query.toLowerCase().trim();
  let hash = 0;
  const keyString = `${version}:${normalized}:${userId}:${limit}:${tag || ''}`;
  for (let i = 0; i < keyString.length; i++) {
    const char = keyString.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash;
  }
  return `search_${userId.substring(0, 8)}_${hash.toString(16)}`;
}

// Get cached search results with version checking
async function getCachedSearchResultsVersioned(
  query: string, 
  userId: string, 
  limit: number, 
  tag: string | undefined, 
  env: Env
): Promise<{ results: any, cached_at: number } | null> {
  try {
    const key = await getVersionedSearchCacheKey(query, userId, limit, tag, env);
    const cached = await env.SEARCH_CACHE.get(key, "json");
    if (cached) {
      console.log(`Search cache HIT for: "${query.substring(0, 30)}..." user=${userId.substring(0, 8)}`);
      return cached as { results: any, cached_at: number };
    }
    console.log(`Search cache MISS for: "${query.substring(0, 30)}..." user=${userId.substring(0, 8)}`);
    return null;
  } catch (e) {
    console.error("Search cache read error:", e);
    return null;
  }
}

// Store search results in cache with version
async function setCachedSearchResultsVersioned(
  query: string,
  userId: string,
  limit: number,
  tag: string | undefined,
  results: any,
  env: Env,
  ctx: ExecutionContext
): Promise<void> {
  try {
    const key = await getVersionedSearchCacheKey(query, userId, limit, tag, env);
    const cacheData = {
      results,
      cached_at: Date.now()
    };
    ctx.waitUntil(
      env.SEARCH_CACHE.put(key, JSON.stringify(cacheData), { expirationTtl: SEARCH_CACHE_TTL })
    );
    console.log(`Cached search results for: "${query.substring(0, 30)}..." user=${userId.substring(0, 8)}`);
  } catch (e) {
    console.error("Search cache write error:", e);
  }
}

// Generate embedding with caching
async function generateEmbeddingCached(
  text: string, 
  env: Env, 
  ctx: ExecutionContext
): Promise<{ embedding: number[], time_ms: number, cached: boolean }> {
  // Check cache first
  const cached = await getCachedEmbedding(text, env);
  if (cached) {
    return { embedding: cached, time_ms: 0, cached: true };
  }
  
  // Generate new embedding
  const result = await generateEmbedding(text, env);
  
  // Cache it (async, non-blocking)
  setCachedEmbedding(text, result.embedding, env, ctx);
  
  return { ...result, cached: false };
}

// Generate embeddings for batch of texts
async function generateEmbeddings(texts: string[], env: Env): Promise<{ embeddings: number[][], time_ms: number }> {
  const start = Date.now();
  
  // Add query prefix for BGE model
  const queryTexts = texts.map(t => `Represent this sentence for searching relevant passages: ${t}`);
  
  const response = await env.AI.run(env.EMBEDDING_MODEL as any, {
    text: queryTexts,
  });
  
  const embeddings = (response as any).data;
  const time_ms = Date.now() - start;
  
  console.log(`Batch embeddings generated in ${time_ms}ms, count=${embeddings.length}`);
  
  return { embeddings, time_ms };
}

// Call Voyage AI Reranker API
async function rerank(
  query: string, 
  documents: string[], 
  env: Env,
  model: string = "rerank-2.5",
  top_k?: number
): Promise<{ results: Array<{ index: number; score: number; text: string }>, time_ms: number }> {
  const start = Date.now();
  
  // Validate model - only accept Voyage AI models, default to rerank-2.5
  const validModels = ["rerank-2.5", "rerank-2.5-lite", "rerank-2", "rerank-2-lite", "rerank-lite-1"];
  const actualModel = validModels.includes(model) ? model : "rerank-2.5";
  
  const response = await fetch("https://api.voyageai.com/v1/rerank", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${env.VOYAGE_API_KEY}`,
    },
    body: JSON.stringify({
      model: actualModel,
      query,
      documents,
      top_k: top_k || documents.length,
      return_documents: true,
    }),
  });
  
  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Voyage API error: ${response.status} - ${error}`);
  }
  
  const data: VoyageRerankResponse = await response.json();
  const time_ms = Date.now() - start;
  
  const results = data.data.map((r) => ({
    index: r.index,
    score: r.relevance_score,
    text: r.document || documents[r.index],
  }));
  
  console.log(`Reranking completed in ${time_ms}ms, input=${documents.length}, output=${results.length}`);
  
  return { results, time_ms };
}

// Supabase chunk-level keyword search interface
interface SupabaseChunkKeywordResult {
  note_id: string;
  chunk_index: number;      // -1 for title match, -2 for description match, 0+ for chunk match
  chunk_content: string;
  text_rank: number;
  match_source: 'chunk' | 'title' | 'description';  // Where the match was found
  normalized_query?: string;  // tsquery text generated by Postgres for this request
}

// Title/description match with content for injection
interface TitleDescMatch {
  score: number;
  content: string;
}

interface KeywordSearchResults {
  // note-level scores (max chunk score per note) - for backward compat in score combination
  results: Map<string, number>;
  // chunk-level results grouped by note_id
  chunks: Map<string, SupabaseChunkKeywordResult[]>;
  // title/description matches WITH CONTENT for injection into results
  titleMatches: Map<string, TitleDescMatch>;       // note_id -> {score, content}
  descriptionMatches: Map<string, TitleDescMatch>; // note_id -> {score, content}
  normalized_query?: string;
  time_ms: number;
}

async function fetchNormalizedKeywordQuery(
  query: string,
  env: Env
): Promise<string | undefined> {
  try {
    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/rpc/normalize_keyword_query`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "apikey": env.SUPABASE_SERVICE_KEY,
          "Authorization": `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
        body: JSON.stringify({ query_text: query }),
      }
    );

    if (!response.ok) {
      const error = await response.text();
      console.warn(`normalize_keyword_query RPC failed: ${response.status} - ${error}`);
      return undefined;
    }

    const payload = await response.json() as unknown;
    if (typeof payload === 'string') {
      return payload || undefined;
    }

    if (Array.isArray(payload) && payload.length > 0) {
      const first = payload[0] as { normalize_keyword_query?: string; normalized_query?: string };
      return first?.normalize_keyword_query || first?.normalized_query;
    }

    if (payload && typeof payload === 'object') {
      const obj = payload as { normalize_keyword_query?: string; normalized_query?: string };
      return obj.normalize_keyword_query || obj.normalized_query;
    }
  } catch (error) {
    console.warn("Failed to fetch normalized keyword query:", error);
  }

  return undefined;
}

// Call Supabase RPC for chunk-level full-text keyword search
async function keywordSearch(
  query: string,
  userId: string,
  env: Env,
  tag?: string,
  limit: number = 50
): Promise<KeywordSearchResults> {
  const start = Date.now();
  const empty: KeywordSearchResults = { 
    results: new Map(), 
    chunks: new Map(), 
    titleMatches: new Map(),
    descriptionMatches: new Map(),
    normalized_query: undefined,
    time_ms: 0 
  };
  
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_KEY) {
    console.log("Supabase credentials not configured, skipping keyword search");
    return empty;
  }
  
  try {
    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/rpc/search_chunks_fulltext`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "apikey": env.SUPABASE_SERVICE_KEY,
          "Authorization": `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
        body: JSON.stringify({
          query_text: query,
          match_user_id: userId,
          match_tag: tag || null,
          match_limit: limit,
        }),
      }
    );
    
    if (!response.ok) {
      const error = await response.text();
      console.error(`Supabase chunk keyword search failed: ${response.status} - ${error}`);
      return { ...empty, time_ms: Date.now() - start };
    }
    
    const data: SupabaseChunkKeywordResult[] = await response.json();
    const time_ms = Date.now() - start;
    
    // Build note-level scores (max chunk score per note)
    const results = new Map<string, number>();
    // Build chunk-level results grouped by note_id (only actual chunks, not title/description)
    const chunks = new Map<string, SupabaseChunkKeywordResult[]>();
    // Track title and description matches WITH CONTENT for injection
    const titleMatches = new Map<string, TitleDescMatch>();
    const descriptionMatches = new Map<string, TitleDescMatch>();
    let normalizedQuery: string | undefined;
    
    let titleMatchCount = 0;
    let descMatchCount = 0;
    let chunkMatchCount = 0;
    
    for (const row of data) {
      if (!normalizedQuery && row.normalized_query) {
        normalizedQuery = row.normalized_query;
      }

      // Note-level: keep max score (from any source)
      const existing = results.get(row.note_id);
      if (!existing || row.text_rank > existing) {
        results.set(row.note_id, row.text_rank);
      }
      
      // Handle based on match_source (chunk_index: -1=title, -2=description, 0+=chunk)
      const matchSource = row.match_source || (row.chunk_index === -1 ? 'title' : row.chunk_index === -2 ? 'description' : 'chunk');
      
      if (matchSource === 'title' || row.chunk_index === -1) {
        // Title match - store with content for potential injection
        const existingTitle = titleMatches.get(row.note_id);
        if (!existingTitle || row.text_rank > existingTitle.score) {
          titleMatches.set(row.note_id, { score: row.text_rank, content: row.chunk_content || '' });
        }
        titleMatchCount++;
      } else if (matchSource === 'description' || row.chunk_index === -2) {
        // Description match - store with content for potential injection
        const existingDesc = descriptionMatches.get(row.note_id);
        if (!existingDesc || row.text_rank > existingDesc.score) {
          descriptionMatches.set(row.note_id, { score: row.text_rank, content: row.chunk_content || '' });
        }
        descMatchCount++;
      } else {
        // Actual chunk match - add to chunks for injection
        const noteChunks = chunks.get(row.note_id) || [];
        noteChunks.push(row);
        chunks.set(row.note_id, noteChunks);
        chunkMatchCount++;
      }
    }

    // If there were no keyword matches, fetch normalization directly from Postgres RPC.
    if (!normalizedQuery) {
      normalizedQuery = await fetchNormalizedKeywordQuery(query, env);
    }
    
    console.log(`Chunk keyword search: ${results.size} notes (${titleMatchCount} title, ${descMatchCount} desc, ${chunkMatchCount} chunk matches) in ${time_ms}ms`);
    return { results, chunks, titleMatches, descriptionMatches, normalized_query: normalizedQuery, time_ms };
    
  } catch (error) {
    console.error("Keyword search error:", error);
    return { ...empty, time_ms: Date.now() - start };
  }
}

// Handle search requests
async function handleSearch(request: Request, env: Env, ctx: ExecutionContext, requestId: string): Promise<Response> {
  const start = Date.now();
  const timing: Record<string, number> = {};
  let queryText: string | undefined;
  let userId: string | undefined;
  
  try {
    const parseStart = Date.now();
    const body: SearchRequest = await request.json();
    timing.parse_ms = Date.now() - parseStart;
    
    queryText = body.query;
    userId = body.user_id;
    
    // Get or generate embedding
    let queryVector: number[];
    if (body.embedding && body.embedding.length === 768) {
      queryVector = body.embedding;
      timing.embedding_ms = 0; // Pre-computed
    } else if (body.query) {
      const result = await generateEmbedding(body.query, env);
      queryVector = result.embedding;
      timing.embedding_ms = result.time_ms;
    } else {
      return new Response(
        JSON.stringify({ error: "Must provide 'query' or 'embedding'" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Build filter if provided
    const filter: VectorizeVectorMetadataFilter = {};
    if (body.user_id) {
      filter["user_id"] = { $eq: body.user_id };
    }
    if (body.tag) {
      filter["tag"] = { $eq: body.tag };
    }
    
    // Query Vectorize
    const limit = Math.min(body.limit || 50, 50); // Max 50 with metadata
    const vectorizeStart = Date.now();
    
    const results = await env.VECTORIZE.query(queryVector, {
      topK: limit,
      returnMetadata: "all",
      filter: Object.keys(filter).length > 0 ? filter : undefined,
    });
    
    timing.vectorize_ms = Date.now() - vectorizeStart;
    
    // Transform results
    const transformStart = Date.now();
    const matches = results.matches.map((match) => ({
      chunk_id: match.id,
      similarity: match.score,
      ...match.metadata,
    }));
    timing.transform_ms = Date.now() - transformStart;
    
    timing.total_ms = Date.now() - start;
    console.log(`[${requestId}] Search: ${matches.length} results, embed=${timing.embedding_ms}ms, vec=${timing.vectorize_ms}ms, total=${timing.total_ms}ms`);
    
    // Send log to backend
    sendLogToBackend({
      request_id: requestId,
      timestamp: new Date().toISOString(),
      endpoint: "/search",
      method: "POST",
      user_id: userId,
      query: queryText,
      timing,
      result: { match_count: matches.length },
    }, env, ctx);
    
    return new Response(
      JSON.stringify({
        success: true,
        matches,
        request_id: requestId,
        timing: {
          embedding_ms: timing.embedding_ms,
          vectorize_ms: timing.vectorize_ms,
          total_ms: timing.total_ms,
        },
      }),
      { 
        status: 200, 
        headers: { "Content-Type": "application/json", ...corsHeaders } 
      }
    );
    
  } catch (error) {
    timing.total_ms = Date.now() - start;
    const errorMsg = String(error);
    console.error(`[${requestId}] Search error:`, error);
    
    // Log the error
    sendLogToBackend({
      request_id: requestId,
      timestamp: new Date().toISOString(),
      endpoint: "/search",
      method: "POST",
      user_id: userId,
      query: queryText,
      timing,
      result: {},
      error: errorMsg,
    }, env, ctx);
    
    return new Response(
      JSON.stringify({ error: errorMsg, request_id: requestId }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle upsert requests
async function handleUpsert(request: Request, env: Env): Promise<Response> {
  const start = Date.now();
  
  try {
    const body: UpsertRequest = await request.json();
    
    if (!body.vectors || body.vectors.length === 0) {
      return new Response(
        JSON.stringify({ error: "Must provide 'vectors' array" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Process vectors - generate embeddings if needed
    const vectorsToUpsert: VectorizeVector[] = [];
    
    for (const v of body.vectors) {
      let values: number[];
      
      if (v.values && v.values.length === 768) {
        values = v.values;
      } else if (v.text) {
        const result = await generateEmbedding(v.text, env);
        values = result.embedding;
      } else {
        return new Response(
          JSON.stringify({ error: `Vector ${v.id} must have 'values' or 'text'` }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      
      vectorsToUpsert.push({
        id: v.id,
        values,
        metadata: v.metadata as Record<string, VectorizeVectorMetadata>,
      });
    }
    
    // Batch upsert (max 1000 per batch)
    const batchSize = 1000;
    let totalUpserted = 0;
    
    for (let i = 0; i < vectorsToUpsert.length; i += batchSize) {
      const batch = vectorsToUpsert.slice(i, i + batchSize);
      await env.VECTORIZE.upsert(batch);
      totalUpserted += batch.length;
    }
    
    const totalTime = Date.now() - start;
    console.log(`Upsert completed: ${totalUpserted} vectors in ${totalTime}ms`);
    
    return new Response(
      JSON.stringify({
        success: true,
        count: totalUpserted,
        timing: { total_ms: totalTime },
      }),
      { 
        status: 200, 
        headers: { "Content-Type": "application/json", ...corsHeaders } 
      }
    );
    
  } catch (error) {
    console.error("Upsert error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle single embedding request
async function handleEmbed(request: Request, env: Env, ctx: ExecutionContext, requestId: string): Promise<Response> {
  const start = Date.now();
  try {
    const body: EmbedRequest = await request.json();
    
    if (!body.text) {
      return new Response(
        JSON.stringify({ error: "Must provide 'text'" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    const { embedding, time_ms } = await generateEmbedding(body.text, env);
    
    // Log to backend
    sendLogToBackend({
      request_id: requestId,
      timestamp: new Date().toISOString(),
      endpoint: "/embed",
      method: "POST",
      user_id: body.user_id,
      timing: { embedding_ms: time_ms, total_ms: Date.now() - start },
      result: { dimensions: embedding.length },
    }, env, ctx);
    
    return new Response(
      JSON.stringify({
        success: true,
        embedding,
        dimensions: embedding.length,
        timing: { embedding_ms: time_ms },
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error("Embed error:", error);
    sendLogToBackend({
      request_id: requestId,
      timestamp: new Date().toISOString(),
      endpoint: "/embed",
      method: "POST",
      timing: { total_ms: Date.now() - start },
      result: {},
      error: String(error),
    }, env, ctx);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}


// Handle batch embedding request
async function handleEmbedBatch(request: Request, env: Env, ctx: ExecutionContext, requestId: string): Promise<Response> {
  const start = Date.now();
  try {
    const body: EmbedBatchRequest = await request.json();
    
    if (!body.texts || body.texts.length === 0) {
      return new Response(
        JSON.stringify({ error: "Must provide 'texts' array" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Workers AI has batch limits - process in chunks of 100
    const batchSize = 100;
    const allEmbeddings: number[][] = [];
    let totalTime = 0;
    
    for (let i = 0; i < body.texts.length; i += batchSize) {
      const batch = body.texts.slice(i, i + batchSize);
      const { embeddings, time_ms } = await generateEmbeddings(batch, env);
      allEmbeddings.push(...embeddings);
      totalTime += time_ms;
    }
    
    // Log to backend
    sendLogToBackend({
      request_id: requestId,
      timestamp: new Date().toISOString(),
      endpoint: "/embed-batch",
      method: "POST",
      user_id: body.user_id,
      timing: { embedding_ms: totalTime, total_ms: Date.now() - start },
      result: { count: allEmbeddings.length, dimensions: allEmbeddings[0]?.length || 768 },
    }, env, ctx);
    
    return new Response(
      JSON.stringify({
        success: true,
        embeddings: allEmbeddings,
        count: allEmbeddings.length,
        dimensions: allEmbeddings[0]?.length || 768,
        timing: { embedding_ms: totalTime },
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error("Embed batch error:", error);
    sendLogToBackend({
      request_id: requestId,
      timestamp: new Date().toISOString(),
      endpoint: "/embed-batch",
      method: "POST",
      timing: { total_ms: Date.now() - start },
      result: {},
      error: String(error),
    }, env, ctx);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle standalone rerank requests
async function handleRerank(request: Request, env: Env, ctx: ExecutionContext, requestId: string): Promise<Response> {
  const start = Date.now();
  try {
    const body: RerankRequest = await request.json();
    
    if (!body.query || !body.documents || body.documents.length === 0) {
      return new Response(
        JSON.stringify({ error: "Must provide 'query' and 'documents' array" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    const { results, time_ms } = await rerank(
      body.query,
      body.documents,
      env,
      body.model || "rerank-2.5",
      body.top_k || body.documents.length
    );
    
    // Log to backend
    sendLogToBackend({
      request_id: requestId,
      timestamp: new Date().toISOString(),
      endpoint: "/rerank",
      method: "POST",
      user_id: body.user_id,
      query: body.query,
      timing: { rerank_ms: time_ms, total_ms: Date.now() - start },
      result: { input_count: body.documents.length, rerank_count: results.length },
    }, env, ctx);
    
    // Return in Voyage-compatible format
    return new Response(
      JSON.stringify({
        success: true,
        results: results.map(r => ({
          index: r.index,
          relevance_score: r.score,
          document: { text: r.text },
        })),
        timing: { rerank_ms: time_ms },
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error("Rerank error:", error);
    sendLogToBackend({
      request_id: requestId,
      timestamp: new Date().toISOString(),
      endpoint: "/rerank",
      method: "POST",
      timing: { total_ms: Date.now() - start },
      result: {},
      error: String(error),
    }, env, ctx);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle delete requests
async function handleDelete(request: Request, env: Env): Promise<Response> {
  const start = Date.now();
  
  try {
    const body: DeleteRequest = await request.json();
    
    if (!body.ids || body.ids.length === 0) {
      return new Response(
        JSON.stringify({ error: "Must provide 'ids' array" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    await env.VECTORIZE.deleteByIds(body.ids);
    
    const totalTime = Date.now() - start;
    console.log(`Delete completed: ${body.ids.length} vectors in ${totalTime}ms`);
    
    return new Response(
      JSON.stringify({
        success: true,
        count: body.ids.length,
        timing: { total_ms: totalTime },
      }),
      { 
        status: 200, 
        headers: { "Content-Type": "application/json", ...corsHeaders } 
      }
    );
    
  } catch (error) {
    console.error("Delete error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// ============================================================================
// DOCUMENT VIEW ENDPOINT
// ============================================================================

/**
 * Verify view token and return user_id if valid.
 * Token format: {note_id}:{user_id}:{expiry_ts}:{signature}
 */
async function verifyViewToken(token: string, noteId: string, env: Env): Promise<string | null> {
  try {
    const parts = token.split(":");
    if (parts.length !== 4) {
      console.log(`View token invalid format: expected 4 parts, got ${parts.length}`);
      return null;
    }
    
    const [tokenNoteId, userId, expiryTs, providedSig] = parts;
    
    // Verify note_id matches
    if (tokenNoteId !== noteId) {
      console.log(`View token note_id mismatch: token=${tokenNoteId.slice(0, 8)}, expected=${noteId.slice(0, 8)}`);
      return null;
    }
    
    // Verify not expired
    if (parseInt(expiryTs) < Math.floor(Date.now() / 1000)) {
      console.log(`View token expired for note ${noteId.slice(0, 8)}...`);
      return null;
    }
    
    // Verify signature using SUPABASE_SERVICE_KEY (must match token generation in rag-search.ts)
    // NOTE: Token is generated with SUPABASE_SERVICE_KEY, NOT SUPABASE_JWT_SECRET
    const message = `${tokenNoteId}:${userId}:${expiryTs}`;
    const secret = env.SUPABASE_SERVICE_KEY;
    
    if (!secret) {
      console.error('SUPABASE_SERVICE_KEY not configured');
      return null;
    }
    
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      'raw',
      encoder.encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );
    
    const signatureBuffer = await crypto.subtle.sign('HMAC', key, encoder.encode(message));
    const expectedSig = Array.from(new Uint8Array(signatureBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('')
      .slice(0, 16);
    
    if (providedSig !== expectedSig) {
      console.log(`Invalid view token signature for note ${noteId.slice(0, 8)}... (got: ${providedSig}, expected: ${expectedSig})`);
      return null;
    }
    
    return userId;
  } catch (err) {
    console.error("View token verification error:", err);
    return null;
  }
}

/**
 * Generate Azure Blob SAS token.
 * Uses an older, simpler SAS format (2015-04-05) for better compatibility.
 */
async function generateAzureSasUrl(blobName: string, env: Env, expiryMinutes: number = 5): Promise<string | null> {
  if (!env.AZURE_STORAGE_CONNECTION_STRING || !env.AZURE_STORAGE_CONTAINER) {
    console.error("Azure storage not configured");
    return null;
  }
  
  // Parse connection string
  let accountName = "";
  let accountKey = "";
  for (const part of env.AZURE_STORAGE_CONNECTION_STRING.split(";")) {
    if (part.startsWith("AccountName=")) {
      accountName = part.split("=")[1];
    } else if (part.startsWith("AccountKey=")) {
      accountKey = part.substring("AccountKey=".length);
    }
  }
  
  if (!accountName || !accountKey) {
    console.error("Could not parse Azure storage connection string");
    return null;
  }
  
  const containerName = env.AZURE_STORAGE_CONTAINER;
  
  // Build SAS token parameters (using 2020-02-10 version for compatibility)
  const now = new Date();
  const expiry = new Date(now.getTime() + expiryMinutes * 60 * 1000);
  
  // Format dates for Azure (ISO 8601, no milliseconds)
  const formatDate = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');
  const startTime = formatDate(new Date(now.getTime() - 5 * 60 * 1000)); // 5 min buffer
  const expiryTime = formatDate(expiry);
  
  // Build string to sign (Azure Blob SAS format 2020-02-10)
  const permissions = "r"; // Read only
  const version = "2020-02-10";
  
  // For blob SAS, the canonicalized resource is /blob/accountname/container/blob
  const canonicalizedResource = `/blob/${accountName}/${containerName}/${blobName}`;
  
  // String to sign for service SAS (2020-02-10)
  // permissions + \n + start + \n + expiry + \n + canonicalizedResource + \n + 
  // identifier + \n + IP + \n + protocol + \n + version + \n + resource + \n +
  // snapshot + \n + cacheControl + \n + contentDisposition + \n + contentEncoding + \n +
  // contentLanguage + \n + contentType
  const stringToSign = [
    permissions,           // signedPermissions
    startTime,             // signedStart
    expiryTime,            // signedExpiry  
    canonicalizedResource, // canonicalizedResource
    "",                    // signedIdentifier (empty)
    "",                    // signedIP (empty)
    "",                    // signedProtocol (empty)
    version,               // signedVersion
    "b",                   // signedResource (b = blob)
    "",                    // signedSnapshotTime (empty)
    "",                    // rscc - Cache-Control (empty)
    "",                    // rscd - Content-Disposition (empty)
    "",                    // rsce - Content-Encoding (empty)  
    "",                    // rscl - Content-Language (empty)
    ""                     // rsct - Content-Type (empty)
  ].join("\n");
  
  console.log(`[Azure SAS] String to sign length: ${stringToSign.length}`);
  console.log(`[Azure SAS] Canonicalized resource: ${canonicalizedResource}`);
  
  // HMAC-SHA256 sign with account key (base64 decoded)
  const keyBuffer = Uint8Array.from(atob(accountKey), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    'raw',
    keyBuffer,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  
  const signatureBuffer = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign));
  const signature = btoa(String.fromCharCode(...new Uint8Array(signatureBuffer)));
  
  // Build SAS query string
  const sasParams = new URLSearchParams({
    sv: version,
    st: startTime,
    se: expiryTime,
    sr: "b",
    sp: permissions,
    sig: signature
  });
  
  // Build full URL
  const blobUrl = `https://${accountName}.blob.core.windows.net/${containerName}/${blobName}`;
  console.log(`[Azure SAS] Final URL: ${blobUrl.slice(0, 80)}...`);
  return `${blobUrl}?${sasParams.toString()}`;
}

/**
 * Handle document view requests.
 * GET /notes/:id/view?token=...
 */
async function handleNoteView(noteId: string, token: string | null, env: Env): Promise<Response> {
  console.log(`[VIEW] Request for note ${noteId}, token provided: ${!!token}`);
  
  // Require token
  if (!token) {
    console.log(`[VIEW] No token provided`);
    return new Response(
      JSON.stringify({ detail: "View token required. Use the link provided by the search results." }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  console.log(`[VIEW] Token: ${token.slice(0, 50)}...`);
  
  // Verify token
  const userId = await verifyViewToken(token, noteId, env);
  if (!userId) {
    console.log(`[VIEW] Token verification FAILED for note ${noteId}`);
    return new Response(
      JSON.stringify({ detail: "Invalid or expired view token" }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  console.log(`[VIEW] Token verified! user_id: ${userId.slice(0, 8)}...`);
  
  // Get note from Supabase. Owners can view directly; active group members can
  // view notes that were shared into a group they belong to.
  const noteUrl = new URL(`${env.SUPABASE_URL}/rest/v1/notes`);
  noteUrl.searchParams.set('select', 'id,title,blob_url,metadata,user_id,file_type,content_markdown');
  noteUrl.searchParams.set('id', `eq.${noteId}`);
  noteUrl.searchParams.set('user_id', `eq.${userId}`);
  noteUrl.searchParams.set('status', 'eq.active');  // Only allow viewing active notes
  
  const noteResponse = await fetch(noteUrl.toString(), {
    headers: {
      'apikey': env.SUPABASE_SERVICE_KEY,
      'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
    }
  });
  
  if (!noteResponse.ok) {
    return new Response(
      JSON.stringify({ detail: "Failed to fetch note" }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  let notes = await noteResponse.json() as Array<{
    id: string;
    title: string;
    blob_url?: string;
    metadata?: { blob_name?: string; source_url?: string };
    user_id: string;
    file_type?: string;
    content_markdown?: string;
  }>;

  if (notes.length === 0) {
    const accessResp = await fetch(
      `${env.SUPABASE_URL}/rest/v1/group_snaps?note_id=eq.${noteId}&select=group_id`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      },
    );
    const groupSnaps = accessResp.ok ? await accessResp.json() as Array<{ group_id: string }> : [];
    if (groupSnaps.length > 0) {
      const groupIds = groupSnaps.map(g => `"${g.group_id}"`).join(',');
      const memberResp = await fetch(
        `${env.SUPABASE_URL}/rest/v1/group_members?group_id=in.(${groupIds})&user_id=eq.${userId}&status=eq.active&select=id&limit=1`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        },
      );
      const memberRows = memberResp.ok ? await memberResp.json() as unknown[] : [];
      if (memberRows.length > 0) {
        const sharedNoteUrl = new URL(`${env.SUPABASE_URL}/rest/v1/notes`);
        sharedNoteUrl.searchParams.set('select', 'id,title,blob_url,metadata,user_id,file_type,content_markdown');
        sharedNoteUrl.searchParams.set('id', `eq.${noteId}`);
        sharedNoteUrl.searchParams.set('status', 'eq.active');
        const sharedNoteResponse = await fetch(sharedNoteUrl.toString(), {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        });
        notes = sharedNoteResponse.ok ? await sharedNoteResponse.json() as typeof notes : [];
      }
    }
  }
  
  if (notes.length === 0) {
    return new Response(
      JSON.stringify({ detail: "Note not found" }),
      { status: 404, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  const note = notes[0];
  
  // For saved webpages with source_url, redirect to the original URL
  // This provides a better viewing experience than serving raw HTML blob
  if (note.metadata?.source_url) {
    console.log(`ðŸ“„ Webpage view: redirecting to source URL for note ${noteId.slice(0, 8)}...`);
    return new Response(null, {
      status: 302,
      headers: {
        "Location": note.metadata.source_url,
        ...corsHeaders
      }
    });
  }
  
  // For quick_notes without a blob, return the note content as HTML
  if (note.file_type === 'quick_note' && !note.blob_url) {
    const htmlContent = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${note.title || 'Quick Note'}</title>
<style>body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:700px;margin:40px auto;padding:20px;line-height:1.6;color:#1f2937;background:#fafafa;}
h1{font-size:1.5rem;border-bottom:2px solid #e5e7eb;padding-bottom:12px;margin-bottom:20px;}
.note-content{background:white;border-radius:8px;padding:24px;box-shadow:0 1px 3px rgba(0,0,0,0.1);white-space:pre-wrap;}
.meta{color:#6b7280;font-size:0.85rem;margin-top:16px;}</style></head>
<body><h1>ðŸ“ ${note.title || 'Quick Note'}</h1>
<div class="note-content">${note.content_markdown || ''}</div>
<div class="meta">Type: Quick Note</div></body></html>`;
    
    return new Response(htmlContent, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8", ...corsHeaders }
    });
  }
  
  // Extract blob_name from URL or metadata
  let blobName = note.metadata?.blob_name;
  
  if (!blobName && note.blob_url) {
    // Extract from URL: https://account.blob.../container/user/type/file.pdf
    const containerName = env.AZURE_STORAGE_CONTAINER || "notes-storage";
    const parts = note.blob_url.split(`/${containerName}/`);
    if (parts.length > 1) {
      blobName = parts[1].split("?")[0]; // Remove any existing query params
    }
  }
  
  if (!blobName) {
    return new Response(
      JSON.stringify({ detail: "Original file not found" }),
      { status: 404, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  // Generate SAS URL and redirect
  const sasUrl = await generateAzureSasUrl(blobName, env, 5);
  if (!sasUrl) {
    return new Response(
      JSON.stringify({ detail: "Failed to generate access URL" }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  console.log(`ðŸ“„ Document view: note=${noteId.slice(0, 8)}... user=${userId.slice(0, 8)}...`);
  
  // Redirect to Azure blob
  return new Response(null, {
    status: 302,
    headers: {
      "Location": sasUrl,
      ...corsHeaders
    }
  });
}

// Health check
async function handleHealth(env: Env): Promise<Response> {
  try {
    // Simple test query to verify Vectorize is working
    const testVector = new Array(768).fill(0.1);
    await env.VECTORIZE.query(testVector, { topK: 1 });
    
    // Check if Voyage API key is configured
    const voyageConfigured = !!env.VOYAGE_API_KEY;
    const groqConfigured = !!env.GROQ_API_KEY;
    
    return new Response(
      JSON.stringify({ 
        status: "healthy",
        vectorize: "connected",
        ai: "available",
        voyage_reranker: voyageConfigured ? "configured" : "not_configured",
        groq_llm: groqConfigured ? "configured" : "not_configured",
        embedding_cache: "enabled",
        search_cache: "enabled",
        tags_cache: "enabled",
        synthesis_cache: "enabled",
        endpoints: ["/health", "/rag-search", "/search", "/rerank", "/embed", "/embed-batch", "/upsert", "/delete", "/cache/invalidate"],
      }),
      { 
        status: 200, 
        headers: { "Content-Type": "application/json", ...corsHeaders } 
      }
    );
  } catch (error) {
    return new Response(
      JSON.stringify({ 
        status: "unhealthy",
        error: String(error),
      }),
      { 
        status: 503, 
        headers: { "Content-Type": "application/json", ...corsHeaders } 
      }
    );
  }
}

// Handle Pro Waitlist submissions (no auth required)
async function handleProWaitlist(request: Request, env: Env): Promise<Response> {
  try {
    const body = await request.json() as { email?: string };
    const email = body.email?.trim()?.toLowerCase();
    
    if (!email) {
      return new Response(
        JSON.stringify({ error: "Email is required" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Basic email validation
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return new Response(
        JSON.stringify({ error: "Invalid email format" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Get user agent and IP for analytics
    const userAgent = request.headers.get('user-agent') || '';
    const ipAddress = request.headers.get('cf-connecting-ip') || 
                      request.headers.get('x-forwarded-for') || '';
    
    // Insert into pro_waitlist table
    const supabaseUrl = `${env.SUPABASE_URL}/rest/v1/pro_waitlist`;
    const response = await fetch(supabaseUrl, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal'
      },
      body: JSON.stringify({
        email,
        source: 'landing_page',
        ip_address: ipAddress,
        user_agent: userAgent
      })
    });
    
    if (!response.ok) {
      const errorText = await response.text();
      // Check if it's a duplicate email error
      if (errorText.includes('duplicate') || errorText.includes('unique')) {
        return new Response(
          JSON.stringify({ success: true, message: "You're already on the list!" }),
          { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      console.error(`[ProWaitlist] Supabase error: ${errorText}`);
      throw new Error('Failed to save email');
    }
    
    console.log(`[ProWaitlist] New signup: ${email}`);
    
    return new Response(
      JSON.stringify({ success: true, message: "Thanks! We'll notify you when Pro launches." }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error(`[ProWaitlist] Error: ${error}`);
    return new Response(
      JSON.stringify({ error: "Something went wrong. Please try again." }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle cache invalidation requests
interface CacheInvalidateRequest {
  user_id: string;
  type?: "search" | "embedding" | "all";  // Default: "search"
}

async function handleCacheInvalidate(request: Request, env: Env, requestId: string): Promise<Response> {
  const start = Date.now();
  
  try {
    const body: CacheInvalidateRequest = await request.json();
    
    if (!body.user_id) {
      return new Response(
        JSON.stringify({ error: "Must provide 'user_id'" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    const cacheType = body.type || "search";
    const invalidated: string[] = [];
    
    if (cacheType === "search" || cacheType === "all") {
      await invalidateUserSearchCache(body.user_id, env);
      invalidated.push("search");
    }
    
    // Note: Embedding cache is query-based, not user-based, so we can't easily invalidate per user
    // If needed, we'd need to track which queries each user has made
    if (cacheType === "all") {
      invalidated.push("embedding (note: user-specific invalidation not supported)");
    }
    
    const totalTime = Date.now() - start;
    console.log(`[${requestId}] Cache invalidated for user ${body.user_id.substring(0, 8)}: ${invalidated.join(", ")}`);
    
    return new Response(
      JSON.stringify({
        success: true,
        user_id: body.user_id,
        invalidated,
        timing: { total_ms: totalTime },
      }),
      { 
        status: 200, 
        headers: { "Content-Type": "application/json", ...corsHeaders } 
      }
    );
    
  } catch (error) {
    console.error("Cache invalidate error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// ============================================================================
// HYBRID SEARCH FUNCTION (internal - for use by rag-search module)
// ============================================================================

interface HybridSearchParams {
  query: string;
  originalQuery?: string;  // Pre-rewrite query for keyword search fallback
  user_id: string;
  tag?: string;
  limit: number;
  rerank: boolean;
  retrieval_limit?: number;  // How many vectors to retrieve (before filtering)
  exclude_note_ids?: string[];  // Exclude these note_ids from vector search (for "search deeper")
}

interface HybridSearchResult {
  matches: Array<Record<string, any>>;
  timing: {
    embedding_ms: number;
    parallel_search_ms: number;
    keyword_ms: number;
    rerank_ms: number;
  };
  embedding_cached: boolean;
  total_candidates?: number;  // Total candidates before reranking (for progressive search)
  // Unique note_ids surfaced by vector + keyword search BEFORE the reranker
  // filtered them. Used by Search Deeper so the next round excludes any note
  // already considered (and rejected) by the reranker, not just the ones
  // that survived the threshold.
  candidate_note_ids?: string[];
  // Candidate data for trace logging
  trace_data?: {
    vector_candidates: Array<Record<string, any>>;
    keyword_candidates: Array<Record<string, any>>;
    combined_candidates: Array<Record<string, any>>;
    reranked_candidates: Array<Record<string, any>>;
    reranker_input_preview: Array<Record<string, any>>;
    chunks_before_grouping?: number;
    unique_documents?: number;
  };
}

async function performHybridSearch(
  params: HybridSearchParams,
  env: Env,
  ctx: ExecutionContext
): Promise<HybridSearchResult> {
  const timing = {
    embedding_ms: 0,
    parallel_search_ms: 0,
    keyword_ms: 0,
    rerank_ms: 0,
  };

  // Trace data containers for pipeline visibility
  const trace_data: {
    vector_candidates: Array<Record<string, any>>;
    keyword_candidates: Array<Record<string, any>>;
    keyword_query?: string;  // The query used for keyword search
    keyword_query_normalized?: string;  // tsquery text generated by Postgres
    keyword_match_count?: number;  // Total keyword matches found
    combined_candidates: Array<Record<string, any>>;
    reranked_candidates: Array<Record<string, any>>;
    reranker_input_preview: Array<Record<string, any>>;
  } = {
    vector_candidates: [],
    keyword_candidates: [],
    combined_candidates: [],
    reranked_candidates: [],
    reranker_input_preview: [],
  };

  // STEP 1: Generate embedding (with cache)
  const { embedding: queryVector, time_ms: embedTime, cached } = await generateEmbeddingCached(
    params.query,
    env,
    ctx
  );
  timing.embedding_ms = embedTime;

  // STEP 2: Run vector search and keyword search
  // Single Vectorize query (topK: 50 with returnMetadata: "all")
  // Use $nin note_id to exclude already-seen documents for "search deeper" iterations
  const MIN_VECTOR_SIMILARITY = 0.15;
  const VECTORIZE_TOP_K = 50;  // Max with returnMetadata: "all"
  const KEYWORD_SEARCH_LIMIT = 200;
  
  const vectorFilter: VectorizeVectorMetadataFilter = {};
  if (params.user_id) {
    vectorFilter["user_id"] = { $eq: params.user_id };
  }
  if (params.tag) {
    vectorFilter["tag"] = { $eq: params.tag };
  }
  // Exclude already-seen documents for "search deeper" iterations
  // IMPORTANT: Vectorize $nin filter has a limit (~100 values), so we only use it for first 50
  // and do server-side filtering for the rest
  const MAX_VECTORIZE_NIN = 50;
  if (params.exclude_note_ids && params.exclude_note_ids.length > 0) {
    const vectorNinIds = params.exclude_note_ids.slice(0, MAX_VECTORIZE_NIN);
    vectorFilter["note_id"] = { $nin: vectorNinIds };
    console.log(`[performHybridSearch] Excluding ${vectorNinIds.length} note_ids via $nin (${params.exclude_note_ids.length} total, rest filtered server-side)`);
  }

  const parallelStart = Date.now();
  
  // Single vector search query
  let queryResult;
  try {
    queryResult = await env.VECTORIZE.query(queryVector, {
      topK: VECTORIZE_TOP_K,
      returnMetadata: "all",
      filter: Object.keys(vectorFilter).length > 0 ? vectorFilter : undefined,
    });
  } catch (vectorizeError) {
    console.error(`[performHybridSearch] Vectorize query failed:`, vectorizeError);
    // Return empty result if Vectorize fails
    queryResult = { matches: [] };
  }
  
  const allVectorMatches = queryResult.matches.filter(m => {
    if (m.score < MIN_VECTOR_SIMILARITY) return false;
    // Server-side dedup fallback: filter out excluded note_ids in case $nin didn't work
    if (params.exclude_note_ids && params.exclude_note_ids.length > 0) {
      const noteId = String(m.metadata?.note_id || "");
      if (params.exclude_note_ids.includes(noteId)) {
        return false;
      }
    }
    return true;
  });
  if (params.exclude_note_ids && params.exclude_note_ids.length > 0) {
    console.log(`[performHybridSearch] After dedup filter: ${allVectorMatches.length} vectors (excluded ${queryResult.matches.length - allVectorMatches.length} dupes)`);
  }

  // Run keyword search (with both rewritten and original queries if they differ)
  const keywordResults: KeywordSearchResults = params.user_id
    ? await keywordSearch(params.query, params.user_id, env, params.tag, KEYWORD_SEARCH_LIMIT)
    : { results: new Map<string, number>(), chunks: new Map<string, SupabaseChunkKeywordResult[]>(), titleMatches: new Map<string, TitleDescMatch>(), descriptionMatches: new Map<string, TitleDescMatch>(), time_ms: 0 };

  // Store keyword query in trace for observability
  trace_data.keyword_query = params.query;
  trace_data.keyword_query_normalized = keywordResults.normalized_query;
  trace_data.keyword_match_count = keywordResults.results.size;

  // If query was rewritten, also run keyword search with original query and merge results
  if (params.originalQuery && params.originalQuery.toLowerCase() !== params.query.toLowerCase() && params.user_id) {
    const originalKeywordResults = await keywordSearch(params.originalQuery, params.user_id, env, params.tag, KEYWORD_SEARCH_LIMIT);
    // Merge note-level scores: keep the higher score for each note_id
    originalKeywordResults.results.forEach((score, noteId) => {
      const existing = keywordResults.results.get(noteId);
      if (!existing || score > existing) {
        keywordResults.results.set(noteId, score);
      }
    });
    // Merge chunk-level results: combine chunks, keep higher score per (note_id, chunk_index)
    originalKeywordResults.chunks.forEach((origChunks, noteId) => {
      const existingChunks = keywordResults.chunks.get(noteId) || [];
      const chunkMap = new Map<number, SupabaseChunkKeywordResult>();
      for (const c of existingChunks) chunkMap.set(c.chunk_index, c);
      for (const c of origChunks) {
        const existing = chunkMap.get(c.chunk_index);
        if (!existing || c.text_rank > existing.text_rank) {
          chunkMap.set(c.chunk_index, c);
        }
      }
      keywordResults.chunks.set(noteId, Array.from(chunkMap.values()));
    });
    // Merge title matches: keep higher score (now with content)
    originalKeywordResults.titleMatches.forEach((match, noteId) => {
      const existing = keywordResults.titleMatches.get(noteId);
      if (!existing || match.score > existing.score) {
        keywordResults.titleMatches.set(noteId, match);
      }
    });
    // Merge description matches: keep higher score (now with content)
    originalKeywordResults.descriptionMatches.forEach((match, noteId) => {
      const existing = keywordResults.descriptionMatches.get(noteId);
      if (!existing || match.score > existing.score) {
        keywordResults.descriptionMatches.set(noteId, match);
      }
    });
    keywordResults.time_ms += originalKeywordResults.time_ms;
    console.log(`[performHybridSearch] Original query keyword search: ${originalKeywordResults.results.size} matches for "${params.originalQuery}" (merged with rewritten query results)`);
  }

  // Filter excluded note IDs from keyword results (for "search deeper")
  if (params.exclude_note_ids && params.exclude_note_ids.length > 0) {
    const excludeSet = new Set(params.exclude_note_ids);
    let removedCount = 0;
    for (const noteId of keywordResults.results.keys()) {
      if (excludeSet.has(noteId)) {
        keywordResults.results.delete(noteId);
        keywordResults.chunks.delete(noteId);
        keywordResults.titleMatches.delete(noteId);
        keywordResults.descriptionMatches.delete(noteId);
        removedCount++;
      }
    }
    if (removedCount > 0) {
      console.log(`[performHybridSearch] Excluded ${removedCount} keyword matches (search deeper)`);
    }
  }

  timing.parallel_search_ms = Date.now() - parallelStart;
  timing.keyword_ms = keywordResults.time_ms;

  // Capture vector candidates for trace
  trace_data.vector_candidates = allVectorMatches.map((match) => {
    const isDoc = match.metadata?.chunk_type === 'document';
    const previewText = isDoc
      ? String(match.metadata?.content_preview || match.metadata?.chunk_text || "").substring(0, 300)
      : String(match.metadata?.chunk_text || "").substring(0, 300);
    return {
      chunk_id: match.id,
      note_id: String(match.metadata?.note_id || ""),
      title: String(match.metadata?.title || ""),
      tag: match.metadata?.tag as string | undefined,
      vector_score: match.score,
      content: previewText,
      chunk_type: isDoc ? 'document' : String(match.metadata?.chunk_type || 'chunk'),
      source_text: isDoc ? 'doc_preview' : 'chunk_text',
    };
  });

  // Capture keyword candidates for trace (with chunk info)
  keywordResults.results.forEach((score, noteId) => {
    const noteChunks = keywordResults.chunks.get(noteId) || [];
    trace_data.keyword_candidates.push({
      note_id: noteId,
      keyword_score: score,
      matched_chunks: noteChunks.map(c => c.chunk_index),
    });
  });

  // Snapshot of every unique note_id surfaced by vector OR keyword search at
  // this point — i.e. before the reranker filters anything out. Search Deeper
  // uses this to exclude all candidates the system already considered, so the
  // next round draws from genuinely fresh notes.
  const candidateNoteIdSet = new Set<string>();
  for (const m of allVectorMatches) {
    const id = String(m.metadata?.note_id || "");
    if (id) candidateNoteIdSet.add(id);
  }
  for (const id of keywordResults.results.keys()) if (id) candidateNoteIdSet.add(id);
  for (const id of keywordResults.titleMatches.keys()) if (id) candidateNoteIdSet.add(id);
  for (const id of keywordResults.descriptionMatches.keys()) if (id) candidateNoteIdSet.add(id);
  const candidateNoteIds = Array.from(candidateNoteIdSet);

  // Transform and combine results
  // Track which (note_id, chunk_index) pairs are already from vector search
  const vectorChunkKeys = new Set<string>();
  let allChunks: Array<Record<string, any>> = allVectorMatches
    .map((match) => {
      const noteId = String(match.metadata?.note_id || "");
      const chunkIndex = Number(match.metadata?.chunk_index ?? -1);
      vectorChunkKeys.add(`${noteId}_${chunkIndex}`);
      const keywordScore = keywordResults.results.get(noteId) || 0;
      // Get title/description match boosts (already factored into RPC score via 1.5x/1.2x multiplier)
      const hasTitle = keywordResults.titleMatches.has(noteId);
      const hasDesc = keywordResults.descriptionMatches.has(noteId);
      // Apply title/description match as additional score boost for vector results
      const titleBoost = hasTitle ? 0.08 : 0;
      const descBoost = hasDesc ? 0.04 : 0;
      const combinedScore = keywordScore > 0
        ? (match.score * 0.7) + (keywordScore * 0.3) + titleBoost + descBoost
        : match.score;
      const isDocVec = match.metadata?.chunk_type === 'document';
      return {
        chunk_id: match.id,
        similarity: match.score,
        combined_score: combinedScore,
        keyword_score: keywordScore,
        has_title_match: hasTitle,
        has_description_match: hasDesc,
        ...match.metadata,
        // For doc vectors, populate content from description + content_preview so downstream
        // reranker/verification always receives meaningful text (not empty)
        content: isDocVec
          ? (() => {
              const desc = String(match.metadata?.description || "").trim();
              const preview = String(match.metadata?.content_preview || match.metadata?.chunk_text || "").trim();
              return desc && preview ? `Description: ${desc}\n\nContent: ${preview}` : (desc || preview);
            })()
          : String(match.metadata?.chunk_text || ""),
        source_text: isDocVec ? 'doc_preview' : 'chunk_text',
      };
    });

  // CHUNK-LEVEL KEYWORD INJECTION: Add keyword-matched chunks that vector search missed
  // This handles multiple cases:
  // 1. Notes found ONLY by keyword chunk (not in vector results at all) - "keyword_only"
  // 2. Notes in BOTH but the specific keyword-matching chunk wasn't in vector results - "keyword_chunk"
  // 3. Notes matching on title/description ONLY (no chunk match) - "title_only" / "description_only"
  // 4. Notes matching on title AND content - inject title pseudo-chunk - "title_with_content"
  // 5. Notes matching on description AND content - inject description pseudo-chunk - "desc_with_content"
  const vectorNoteIds = new Set(allChunks.map(c => String(c.note_id || "")));
  const keywordOnlyNoteIds: string[] = [];
  let keywordChunkInjectedCount = 0;
  let titleOnlyInjectedCount = 0;
  let descOnlyInjectedCount = 0;
  let titleWithContentInjectedCount = 0;
  let descWithContentInjectedCount = 0;
  
  // Track which notes have had title/desc pseudo-chunks injected (to avoid duplicates)
  const notesWithTitlePseudoChunk = new Set<string>();
  const notesWithDescPseudoChunk = new Set<string>();

  // First, inject chunk matches
  keywordResults.chunks.forEach((chunkResults, noteId) => {
    const isKeywordOnly = !vectorNoteIds.has(noteId);
    if (isKeywordOnly) {
      keywordOnlyNoteIds.push(noteId);
    }

    // Get title/description match info for this note
    const titleMatch = keywordResults.titleMatches.get(noteId);
    const descMatch = keywordResults.descriptionMatches.get(noteId);
    const titleBoost = titleMatch ? 0.08 : 0;
    const descBoost = descMatch ? 0.04 : 0;

    for (const chunk of chunkResults) {
      const chunkKey = `${noteId}_${chunk.chunk_index}`;
      if (!vectorChunkKeys.has(chunkKey)) {
        // This keyword-matched chunk is NOT in vector results — inject it
        const kwScore = chunk.text_rank;
        const scaledScore = Math.min(kwScore * 0.5, 0.8) + titleBoost + descBoost;
        allChunks.push({
          chunk_id: `${noteId}_chunk_${chunk.chunk_index}`,
          similarity: 0,
          combined_score: scaledScore,
          keyword_score: kwScore,
          has_title_match: !!titleMatch,
          has_description_match: !!descMatch,
          note_id: noteId,
          chunk_type: 'chunk',
          chunk_index: chunk.chunk_index,
          content: chunk.chunk_content,
          chunk_text: chunk.chunk_content.substring(0, 500),
          source: isKeywordOnly ? "keyword_only" : "keyword_chunk",
        });
        vectorChunkKeys.add(chunkKey); // prevent duplicate injection
        keywordChunkInjectedCount++;
      }
    }
    
    // NEW: If title also matched for this note with chunk content, inject title as pseudo-chunk
    // This ensures the reranker/LLM sees the title text explicitly
    if (titleMatch && !notesWithTitlePseudoChunk.has(noteId)) {
      const kwScore = titleMatch.score;
      const scaledScore = Math.min(kwScore * 0.55, 0.82); // Slightly higher than pure title-only
      const content = `[TITLE+CONTENT MATCH] Title: "${titleMatch.content}"`;
      
      allChunks.push({
        chunk_id: `${noteId}_title_with_content`,
        similarity: 0,
        combined_score: scaledScore,
        keyword_score: kwScore,
        has_title_match: true,
        has_description_match: !!descMatch,
        note_id: noteId,
        chunk_type: 'title',
        chunk_index: -1,
        content: content,
        chunk_text: content,
        title: titleMatch.content,
        source: "title_with_content",
      });
      notesWithTitlePseudoChunk.add(noteId);
      titleWithContentInjectedCount++;
    }
    
    // NEW: If description also matched for this note with chunk content, inject description as pseudo-chunk
    if (descMatch && !notesWithDescPseudoChunk.has(noteId)) {
      const kwScore = descMatch.score;
      const scaledScore = Math.min(kwScore * 0.48, 0.72); // Slightly higher than pure desc-only
      const content = `[DESCRIPTION+CONTENT MATCH] Description: "${descMatch.content}"`;
      
      allChunks.push({
        chunk_id: `${noteId}_desc_with_content`,
        similarity: 0,
        combined_score: scaledScore,
        keyword_score: kwScore,
        has_title_match: !!titleMatch,
        has_description_match: true,
        note_id: noteId,
        chunk_type: 'description',
        chunk_index: -2,
        content: content,
        chunk_text: content,
        source: "desc_with_content",
      });
      notesWithDescPseudoChunk.add(noteId);
      descWithContentInjectedCount++;
    }
  });

  // Second, inject title-only matches (notes that matched on title but NO chunks)
  // This ensures notes found by title search get to reranker/LLM
  keywordResults.titleMatches.forEach((titleMatch, noteId) => {
    const hasChunkMatch = keywordResults.chunks.has(noteId);
    const hasVectorMatch = vectorNoteIds.has(noteId);
    
    // Only inject if this note has NO other representation in results
    if (!hasChunkMatch && !hasVectorMatch) {
      const descMatch = keywordResults.descriptionMatches.get(noteId);
      const kwScore = titleMatch.score;
      // Title-only gets a good score since title matches are most important
      const scaledScore = Math.min(kwScore * 0.6, 0.85);
      
      // Combine title + description content if both match
      let content = `[TITLE MATCH] ${titleMatch.content}`;
      if (descMatch) {
        content += `\n[DESCRIPTION] ${descMatch.content}`;
      }
      
      allChunks.push({
        chunk_id: `${noteId}_title_match`,
        similarity: 0,
        combined_score: scaledScore,
        keyword_score: kwScore,
        has_title_match: true,
        has_description_match: !!descMatch,
        note_id: noteId,
        chunk_type: 'title',
        chunk_index: -1,  // Special index for title
        content: content,
        chunk_text: content.substring(0, 500),
        title: titleMatch.content,  // The title itself
        source: "title_only",
      });
      keywordOnlyNoteIds.push(noteId);
      titleOnlyInjectedCount++;
      notesWithTitlePseudoChunk.add(noteId);
      if (descMatch) notesWithDescPseudoChunk.add(noteId);
    }
  });

  // Third, inject description-only matches (notes that matched on description but NO title, NO chunks)
  keywordResults.descriptionMatches.forEach((descMatch, noteId) => {
    const hasChunkMatch = keywordResults.chunks.has(noteId);
    const hasVectorMatch = vectorNoteIds.has(noteId);
    const hasTitleMatch = keywordResults.titleMatches.has(noteId);
    
    // Only inject if this note has NO other representation AND wasn't already added via title
    if (!hasChunkMatch && !hasVectorMatch && !hasTitleMatch) {
      const kwScore = descMatch.score;
      const scaledScore = Math.min(kwScore * 0.5, 0.75);
      const content = `[DESCRIPTION MATCH] ${descMatch.content}`;
      
      allChunks.push({
        chunk_id: `${noteId}_desc_match`,
        similarity: 0,
        combined_score: scaledScore,
        keyword_score: kwScore,
        has_title_match: false,
        has_description_match: true,
        note_id: noteId,
        chunk_type: 'description',
        chunk_index: -2,  // Special index for description
        content: content,
        chunk_text: content.substring(0, 500),
        source: "description_only",
      });
      keywordOnlyNoteIds.push(noteId);
      descOnlyInjectedCount++;
      notesWithDescPseudoChunk.add(noteId);
    }
  });

  if (keywordOnlyNoteIds.length > 0 || keywordChunkInjectedCount > 0) {
    console.log(`[performHybridSearch] Keyword chunk injection: ${keywordOnlyNoteIds.length} keyword-only notes, ${keywordChunkInjectedCount} chunks injected`);
  }
  if (titleOnlyInjectedCount > 0 || descOnlyInjectedCount > 0) {
    console.log(`[performHybridSearch] Title/desc-only injection: ${titleOnlyInjectedCount} title-only, ${descOnlyInjectedCount} desc-only`);
  }
  if (titleWithContentInjectedCount > 0 || descWithContentInjectedCount > 0) {
    console.log(`[performHybridSearch] Title/desc WITH content injection: ${titleWithContentInjectedCount} title+content, ${descWithContentInjectedCount} desc+content`);
  }
  if (keywordResults.titleMatches.size > 0 || keywordResults.descriptionMatches.size > 0) {
    console.log(`[performHybridSearch] Title/description matches: ${keywordResults.titleMatches.size} title, ${keywordResults.descriptionMatches.size} description`);
  }

  (trace_data as any).keyword_only_injected = keywordOnlyNoteIds.length;
  (trace_data as any).keyword_chunks_injected = keywordChunkInjectedCount;
  (trace_data as any).title_only_injected = titleOnlyInjectedCount;
  (trace_data as any).desc_only_injected = descOnlyInjectedCount;
  (trace_data as any).title_with_content_injected = titleWithContentInjectedCount;
  (trace_data as any).desc_with_content_injected = descWithContentInjectedCount;
  (trace_data as any).title_match_count = keywordResults.titleMatches.size;
  (trace_data as any).description_match_count = keywordResults.descriptionMatches.size;

  // Enrich keyword candidates with titles from allChunks
  const chunkTitleMap = new Map<string, string>();
  for (const chunk of allChunks) {
    const nid = String(chunk.note_id || "");
    if (nid && chunk.title && !chunkTitleMap.has(nid)) {
      chunkTitleMap.set(nid, String(chunk.title));
    }
  }
  trace_data.keyword_candidates = trace_data.keyword_candidates.map((kc: any) => ({
    ...kc,
    title: chunkTitleMap.get(kc.note_id) || undefined,
    source: keywordOnlyNoteIds.includes(kc.note_id) ? "keyword_only" : "keyword+vector",
    chunk_type: keywordOnlyNoteIds.includes(kc.note_id) ? 'keyword_only' : 'keyword_chunk',
    source_text: keywordOnlyNoteIds.includes(kc.note_id) ? 'keyword_only' : 'keyword_chunk',
    has_title_match: keywordResults.titleMatches.has(kc.note_id),
    has_description_match: keywordResults.descriptionMatches.has(kc.note_id),
  }));

  // Keep TOP 3 CHUNKS per document for reranking (not just 1)
  // This allows multiple relevant chunks from the same document to be considered for reranking
  const TOP_CHUNKS_PER_DOC = 3;
  const chunksPerNote = new Map<string, Array<typeof allChunks[0]>>();
  
  for (const chunk of allChunks) {
    const noteId = String(chunk.note_id || "");
    const chunks = chunksPerNote.get(noteId) || [];
    chunks.push(chunk);
    chunksPerNote.set(noteId, chunks);
  }
  
  // Take top N chunks per document, sorted by combined score
  let matches: Array<typeof allChunks[0]> = [];
  for (const [noteId, chunks] of chunksPerNote) {
    chunks.sort((a, b) => (b.combined_score || b.similarity) - (a.combined_score || a.similarity));
    matches.push(...chunks.slice(0, TOP_CHUNKS_PER_DOC));
  }

  // Sort all matches by combined score
  matches.sort((a, b) => (b.combined_score || b.similarity) - (a.combined_score || a.similarity));

  // Capture combined candidates for trace with chunk selection metadata
  // Include info about the top-3 selection process
  (trace_data as any).chunks_before_grouping = allChunks.length;
  (trace_data as any).unique_documents = chunksPerNote.size;
  (trace_data as any).chunks_per_doc_limit = TOP_CHUNKS_PER_DOC;
  (trace_data as any).chunks_after_grouping = matches.length;
  
  trace_data.combined_candidates = matches.map((m) => ({
    note_id: String(m.note_id || ""),
    title: String(m.title || ""),
    tag: m.tag as string | undefined,
    vector_score: m.similarity,
    keyword_score: m.keyword_score || 0,
    combined_score: m.combined_score,
    content: String(m.content || "").substring(0, 300),
    chunk_type: String(m.chunk_type || 'chunk'),
    source_text: m.source_text || m.source || 'chunk_text',
  }));

  // STEP 3: Rerank if enabled
  const MIN_RERANK_SCORE = 0.4;
  if (params.rerank && matches.length > 0) {
    const documents = matches.map(m =>
      String(m.content || m.content_preview || m.title || "")
    ).filter(d => d.length > 0);

    trace_data.reranker_input_preview = matches.map((m, i) => {
      const documentText = String(m.content || m.content_preview || m.title || "");
      return {
        candidate_index: i,
        note_id: String(m.note_id || ""),
        title: String(m.title || ""),
        chunk_type: String(m.chunk_type || 'chunk'),
        source_text: String(m.source_text || m.source || 'chunk_text'),
        reranker_input_preview: documentText.substring(0, 300),
        reranker_input_length: documentText.length,
      };
    });

    if (documents.length > 0) {
      try {
        // Don't limit reranker output - let threshold filtering determine quality
        const { results: reranked, time_ms: rerankTime } = await rerank(
          params.query,
          documents,
          env,
          "rerank-2.5"
          // No top_k limit - all documents will be scored and filtered by threshold
        );
        timing.rerank_ms = rerankTime;

        // Capture reranked candidates for trace (before threshold filtering)
        trace_data.reranked_candidates = reranked.map((r) => ({
          note_id: String(matches[r.index]?.note_id || ""),
          title: String(matches[r.index]?.title || ""),
          tag: matches[r.index]?.tag as string | undefined,
          combined_score: matches[r.index]?.combined_score || 0,
          rerank_score: r.score,
          passed_rerank_threshold: r.score >= MIN_RERANK_SCORE,
          content: String(matches[r.index]?.content || "").substring(0, 300),
          chunk_type: String(matches[r.index]?.chunk_type || 'chunk'),
          source_text: matches[r.index]?.source_text || matches[r.index]?.source || 'chunk_text',
        }));

        // Reorder and filter by threshold
        // Keyword-matched results get a moderately lower rerank threshold since they have confirmed text matches
        const KEYWORD_MATCH_RERANK_SCORE = 0.2;
        const rerankedMatches = reranked
          .filter(r => {
            const match = matches[r.index];
            const hasKeywordMatch = (match?.keyword_score || 0) > 0;
            const threshold = hasKeywordMatch ? KEYWORD_MATCH_RERANK_SCORE : MIN_RERANK_SCORE;
            return r.score >= threshold;
          })
          .map(r => ({
            ...matches[r.index],
            rerank_score: r.score,
            original_similarity: matches[r.index].similarity,
            // Keep original vector similarity — don't overwrite with rerank score
          }));

        matches = rerankedMatches;
      } catch (rerankError) {
        console.error("Rerank failed:", rerankError);
        // On rerank failure, keep results filtered by vector threshold only
      }
    }
  }
  // No artificial limit - threshold filtering already applied
  
  // Track total candidates before any batching/pagination
  const totalCandidatesBeforeRerank = (trace_data as any).chunks_after_grouping || matches.length;

  // ───────────────────────────────────────────────────────────────────────
  // Title backfill: notes.title is the source of truth (NOT vector metadata).
  // Vector chunk metadata `title` may be empty/stale (e.g. when title is set
  // by a backfill job after chunks were embedded). Join live titles from the
  // `notes` table for the result note_ids and overwrite each match's title.
  // ───────────────────────────────────────────────────────────────────────
  try {
    const uniqueNoteIds = Array.from(new Set(
      matches.map(m => String(m.note_id || "")).filter(Boolean)
    ));
    if (uniqueNoteIds.length > 0) {
      const titleFetchStart = Date.now();
      const inList = uniqueNoteIds.map(id => `"${id}"`).join(',');
      const titleResp = await fetch(
        `${env.SUPABASE_URL}/rest/v1/notes?id=in.(${inList})&user_id=eq.${params.user_id}&select=id,title`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      );
      if (titleResp.ok) {
        const rows = await titleResp.json() as Array<{ id: string; title: string | null }>;
        const titleMap = new Map<string, string>();
        for (const row of rows) {
          if (row.id && row.title) titleMap.set(row.id, row.title);
        }
        for (const m of matches) {
          const nid = String(m.note_id || "");
          const liveTitle = titleMap.get(nid);
          if (liveTitle) {
            m.title = liveTitle;
          }
        }
        (trace_data as any).title_backfill_ms = Date.now() - titleFetchStart;
        (trace_data as any).title_backfill_count = titleMap.size;
      } else {
        console.warn(`[performHybridSearch] Title backfill failed: ${titleResp.status} — falling back to vector metadata titles`);
      }
    }
  } catch (err) {
    console.warn(`[performHybridSearch] Title backfill error (non-fatal):`, err);
  }

  return {
    matches,
    timing,
    embedding_cached: cached,
    total_candidates: totalCandidatesBeforeRerank,
    candidate_note_ids: candidateNoteIds,
    trace_data,
  };
}

// =========================================================================
// Migrate chunk_ids to short hashes for a user's vectors
// =========================================================================
async function handleMigrateChunkIds(request: Request, env: Env): Promise<Response> {
  const body = await request.json() as { user_id?: string; reindex?: boolean };
  const userId = body.user_id;
  const reindex = body.reindex === true; // Re-upsert ALL vectors to rebuild metadata indexes
  if (!userId) {
    return new Response(JSON.stringify({ error: "user_id is required" }), {
      status: 400, headers: { "Content-Type": "application/json", ...corsHeaders }
    });
  }

  console.log(`[migrate-chunk-ids] Starting migration for user ${userId.slice(0, 8)}...`);

  // Step 1: Get all note IDs from Supabase for this user
  const notesUrl = new URL(`${env.SUPABASE_URL}/rest/v1/notes`);
  notesUrl.searchParams.set('select', 'id,metadata');
  notesUrl.searchParams.set('user_id', `eq.${userId}`);
  notesUrl.searchParams.set('status', 'eq.active');

  const notesResp = await fetch(notesUrl.toString(), {
    headers: {
      'apikey': env.SUPABASE_SERVICE_KEY,
      'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
    }
  });

  if (!notesResp.ok) {
    return new Response(JSON.stringify({ error: "Failed to fetch notes from Supabase", status: notesResp.status }), {
      status: 500, headers: { "Content-Type": "application/json", ...corsHeaders }
    });
  }

  const notes = await notesResp.json() as Array<{ id: string; metadata?: { chunk_count?: number } }>;
  console.log(`[migrate-chunk-ids] Found ${notes.length} notes for user`);

  if (notes.length === 0) {
    return new Response(JSON.stringify({ migrated: 0, skipped: 0, notes: 0, message: "No notes found" }), {
      status: 200, headers: { "Content-Type": "application/json", ...corsHeaders }
    });
  }

  // Step 2: Build list of all possible vector IDs for each note
  const allVectorIds: string[] = [];
  for (const note of notes) {
    allVectorIds.push(`${note.id}_doc`);
    const chunkCount = note.metadata?.chunk_count || 0;
    // Use stored chunk_count, or check up to 5 if unknown
    const maxChunks = chunkCount > 0 ? chunkCount : 5;
    for (let i = 0; i < maxChunks; i++) {
      allVectorIds.push(`${note.id}_chunk_${i}`);
    }
  }

  console.log(`[migrate-chunk-ids] Checking ${allVectorIds.length} possible vector IDs`);

  // Step 3: Fetch vectors in batches of 100 using getByIds
  let migrated = 0;
  let skipped = 0;
  let notFound = 0;
  const BATCH_SIZE = 20;  // Vectorize getByIds limit is 20

  for (let i = 0; i < allVectorIds.length; i += BATCH_SIZE) {
    const batchIds = allVectorIds.slice(i, i + BATCH_SIZE);
    
    let vectors: VectorizeVector[];
    try {
      vectors = (await env.VECTORIZE.getByIds(batchIds)) as VectorizeVector[];
    } catch (err) {
      console.error(`[migrate-chunk-ids] getByIds error at batch ${Math.floor(i / BATCH_SIZE)}:`, err);
      continue;
    }

    if (!vectors || vectors.length === 0) {
      notFound += batchIds.length;
      continue;
    }

    notFound += batchIds.length - vectors.length;

    // Filter to vectors that need migration (or all if reindex mode)
    const toUpsert: VectorizeVector[] = [];
    for (const vec of vectors) {
      if (reindex) {
        // Re-upsert with same metadata to rebuild indexes
        toUpsert.push({
          id: vec.id,
          values: vec.values as number[],
          metadata: vec.metadata as Record<string, VectorizeVectorMetadata> || {},
        });
      } else {
        const currentChunkId = String(vec.metadata?.chunk_id || '');
        if (currentChunkId.length > 8) {
          // Old-style long chunk_id — needs migration to short hash
          const newChunkId = shortHash(vec.id);
          const updatedMetadata = { ...(vec.metadata || {}), chunk_id: newChunkId };
          toUpsert.push({
            id: vec.id,
            values: vec.values as number[],
            metadata: updatedMetadata,
          });
        } else if (currentChunkId.length === 0) {
          // No chunk_id at all — add short hash
          const newChunkId = shortHash(vec.id);
          const updatedMetadata = { ...(vec.metadata || {}), chunk_id: newChunkId };
          toUpsert.push({
            id: vec.id,
            values: vec.values as number[],
            metadata: updatedMetadata,
          });
        } else {
          // Already has a short chunk_id
          skipped++;
        }
      }
    }

    if (toUpsert.length > 0) {
      try {
        await env.VECTORIZE.upsert(toUpsert);
        migrated += toUpsert.length;
        console.log(`[migrate-chunk-ids] Upserted batch: ${toUpsert.length} vectors (batch ${Math.floor(i / BATCH_SIZE) + 1})`);
      } catch (err) {
        console.error(`[migrate-chunk-ids] Upsert error at batch ${Math.floor(i / BATCH_SIZE)}:`, err);
      }
    }
  }

  const result = {
    migrated,
    skipped,
    not_found: notFound,
    total_notes: notes.length,
    total_vector_ids_checked: allVectorIds.length,
    message: `Migrated ${migrated} vectors to short chunk_ids, ${skipped} already had short ids`,
  };
  console.log(`[migrate-chunk-ids] Done:`, JSON.stringify(result));

  return new Response(JSON.stringify(result), {
    status: 200, headers: { "Content-Type": "application/json", ...corsHeaders }
  });
}

// ============================================================================
// Sweeper: clean up upload pipelines that got stuck (Suggestion 3)
// ----------------------------------------------------------------------------
// Find upload_traces rows that have been in 'accepted' or 'processing' for
// longer than `thresholdMinutes`, mark them failed, delete the placeholder
// note (status='incomplete' guard), and refund the user's monthly quota.
// Called from the scheduled() handler on every cron tick.
// ============================================================================
async function sweepStuckUploads(env: Env, thresholdMinutes: number): Promise<void> {
  const cutoffIso = new Date(Date.now() - thresholdMinutes * 60_000).toISOString();
  const listUrl =
    `${env.SUPABASE_URL}/rest/v1/upload_traces` +
    `?status=in.(accepted,processing)` +
    `&created_at=lt.${encodeURIComponent(cutoffIso)}` +
    `&select=trace_id,user_id,note_id,created_at,status` +
    `&order=created_at.asc` +
    `&limit=100`;

  let stuck: Array<{ trace_id: string; user_id: string; note_id: string | null; created_at: string; status: string }> = [];
  try {
    const resp = await fetch(listUrl, {
      headers: {
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });
    if (!resp.ok) {
      console.log(`[sweepStuckUploads] list query HTTP ${resp.status}`);
      return;
    }
    stuck = await resp.json() as typeof stuck;
  } catch (e) {
    console.log('[sweepStuckUploads] list query threw', String(e));
    return;
  }

  if (stuck.length === 0) return;
  console.log(`[sweepStuckUploads] found ${stuck.length} stuck upload(s) older than ${thresholdMinutes}m`);

  const errMsg = `Stuck upload swept after ${thresholdMinutes}m without progress`;
  const billingEnv = env as unknown as BillingEnv;

  for (const row of stuck) {
    // 1. Mark the trace as failed.
    try {
      await fetch(
        `${env.SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.${encodeURIComponent(row.trace_id)}`,
        {
          method: 'PATCH',
          headers: {
            apikey: env.SUPABASE_SERVICE_KEY,
            Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
            'Content-Type': 'application/json',
            Prefer: 'return=minimal',
          },
          body: JSON.stringify({
            status: 'failed',
            error_message: errMsg,
            completed_at: new Date().toISOString(),
          }),
        }
      );
    } catch (e) {
      console.log(`[sweepStuckUploads] trace patch failed for ${row.trace_id}: ${String(e)}`);
    }

    // 2. Delete the placeholder note (only if still incomplete \u2014 never clobber
    //    a row that some other flow finalised to 'active').
    if (row.note_id) {
      try {
        await fetch(
          `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${encodeURIComponent(row.note_id)}&user_id=eq.${encodeURIComponent(row.user_id)}&status=in.(incomplete,deleted)`,
          {
            method: 'DELETE',
            headers: {
              apikey: env.SUPABASE_SERVICE_KEY,
              Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
              Prefer: 'return=minimal',
            },
          }
        );
      } catch (e) {
        console.log(`[sweepStuckUploads] note delete failed for ${row.note_id}: ${String(e)}`);
      }

      // Bump search-cache version so the client refresh removes it.
      try {
        await env.SEARCH_CACHE.put(`version_${row.user_id}`, Date.now().toString());
      } catch {
        /* non-fatal */
      }
    }

    // 3. Refund the upload quota credit (idempotent; trace_id is the key).
    try {
      await refundQuota(billingEnv, row.user_id, 'upload', row.trace_id);
    } catch (e) {
      console.log(`[sweepStuckUploads] refund failed for ${row.trace_id}: ${String(e)}`);
    }
  }
}

// Main request handler
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const requestId = generateRequestId();
    
    // Debug log the path for API routes
    if (path.startsWith('/api/v1/')) {
      console.log(`[${requestId}] API route: path="${path}", method=${request.method}`);
    }
    
    // Handle CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // =========================================================================
    // Rate limiting (Cloudflare Workers built-in, NOT WAF).
    // Keyed by CF-Connecting-IP. We rate limit on IP rather than user_id
    // because validating auth costs ~50ms and runs against Supabase — we'd
    // rather reject script floods before paying that cost. Trade-off: NAT/
    // corporate proxies share an IP, but the limits are generous enough
    // (30 uploads/min, 120 searches/min) that even shared offices won't
    // hit them with normal use.
    //
    // Bindings are optional so local `wrangler dev` and any deploy that
    // hasn't picked up the new wrangler.toml still works (just no limits).
    // =========================================================================
    if (request.method === "POST") {
      const clientIp = request.headers.get("CF-Connecting-IP") || "unknown";
      let limiter: RateLimit | undefined;
      let limiterName = "";
      if (path.startsWith("/api/v1/upload/") && env.UPLOAD_RATELIMIT) {
        limiter = env.UPLOAD_RATELIMIT;
        limiterName = "upload";
      } else if ((path === "/rag-search-auth" || path === "/rag-search") && env.SEARCH_RATELIMIT) {
        limiter = env.SEARCH_RATELIMIT;
        limiterName = "search";
      }
      if (limiter) {
        try {
          const { success } = await limiter.limit({ key: clientIp });
          if (!success) {
            console.log(`[${requestId}] Rate limited (${limiterName}) ip=${clientIp}`);
            return new Response(
              JSON.stringify({
                error: "Rate limit exceeded",
                detail: `Too many ${limiterName} requests from this source. Please slow down.`,
                retry_after_seconds: 60,
              }),
              {
                status: 429,
                headers: {
                  "Content-Type": "application/json",
                  "Retry-After": "60",
                  ...corsHeaders,
                },
              }
            );
          }
        } catch (rateLimitErr) {
          // Never fail-closed on a rate-limit infrastructure error — log and
          // continue so a CF outage doesn't take the app down.
          console.error(`[${requestId}] Rate-limit binding error:`, redact(rateLimitErr));
        }
      }
    }
    
    // Health check (no auth required)
    if (path === "/health" || path === "/") {
      return handleHealth(env);
    }
    
    // =========================================================================
    // Pro Waitlist - Collect emails for Pro plan interest (no auth required)
    // POST /api/pro-waitlist
    // =========================================================================
    if (path === "/api/pro-waitlist") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      return handleProWaitlist(request, env);
    }
    
    // =========================================================================
    // Extension timing endpoint - logs Chrome extension timing to search_traces
    // POST /logs/extension-timing (requires API key)
    // =========================================================================
    if (path === "/logs/extension-timing" || path === "/api/v1/logs/extension-timing") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      return handleExtensionTiming(request, env, ctx);
    }
    
    // =========================================================================
    // Admin KPI Dashboard Endpoints
    // GET /api/v1/admin/kpi/summary - Complete KPI summary
    // GET /api/v1/admin/kpi/search-timeseries - Search counts by time
    // GET /api/v1/admin/kpi/latency-timeseries - Latency stats by time
    // =========================================================================
    if (path === "/api/v1/admin/kpi/summary") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleKpiSummary(request, authResult, env as AdminEnv);
    }
    
    if (path === "/api/v1/admin/kpi/search-timeseries") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleKpiSearchTimeseries(request, authResult, env as AdminEnv);
    }
    
    if (path === "/api/v1/admin/kpi/latency-timeseries") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleKpiLatencyTimeseries(request, authResult, env as AdminEnv);
    }
    
    if (path === "/api/v1/admin/kpi/upload-details") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleKpiUploadDetails(request, authResult, env as AdminEnv);
    }
    
    if (path === "/api/v1/admin/kpi/search-sources") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleKpiSearchSources(request, authResult, env as AdminEnv);
    }
    
    if (path === "/api/v1/admin/kpi/error-details") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleKpiErrorDetails(request, authResult, env as AdminEnv);
    }
    
    if (path === "/api/v1/admin/kpi/latency-stats") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleKpiLatencyStats(request, authResult, env as AdminEnv);
    }
    
    if (path === "/api/v1/admin/kpi/upload-latency-stats") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleKpiUploadLatencyStats(request, authResult, env as AdminEnv);
    }
    
    if (path === "/api/v1/admin/kpi/upload-error-details") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleKpiUploadErrorDetails(request, authResult, env as AdminEnv);
    }

    // =========================================================================
    // Migrate chunk_ids to short hashes
    // POST /api/v1/admin/migrate-chunk-ids { user_id: string }
    // Requires WORKER_API_KEY. Re-upserts all vectors for a user with short chunk_ids.
    // =========================================================================
    if (path === "/api/v1/admin/migrate-chunk-ids") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      if (!validateApiKey(request, env)) {
        return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } });
      }
      return handleMigrateChunkIds(request, env);
    }
    
    // =========================================================================
    // Logs Dashboard Endpoints (for activity-logs.html admin page)
    // GET /api/v1/logs/dashboard/users - Get users with recent activity
    // GET /api/v1/logs/dashboard/activities - Get activities for a user
    // GET /api/v1/logs/search-trace/:id - Get single search trace
    // GET /api/v1/logs/trace/:id - Get trace operations
    // GET /api/v1/logs/file/trace/:id - Get file trace
    // =========================================================================
    if (path === "/api/v1/logs/dashboard/users") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleDashboardUsers(request, authResult, env as LogsEnv);
    }
    
    if (path === "/api/v1/logs/dashboard/activities") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleDashboardActivities(request, authResult, env as LogsEnv);
    }
    
    // GET /api/v1/logs/search-trace/:id
    const searchTraceMatch = path.match(/^\/api\/v1\/logs\/search-trace\/(.+)$/);
    if (searchTraceMatch) {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleSearchTrace(searchTraceMatch[1], authResult, env as LogsEnv);
    }
    
    // GET /api/v1/logs/trace/:id - trace operations
    const traceOpsMatch = path.match(/^\/api\/v1\/logs\/trace\/(.+)$/);
    if (traceOpsMatch) {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleTraceOperations(traceOpsMatch[1], authResult, env as LogsEnv);
    }
    
    // GET /api/v1/logs/file/trace/:id
    const fileTraceMatch = path.match(/^\/api\/v1\/logs\/file\/trace\/(.+)$/);
    if (fileTraceMatch) {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleFileTrace(fileTraceMatch[1], request, authResult, env as LogsEnv);
    }
    
    // =========================================================================
    // API ENDPOINTS (migrated from Fly.io for better scaling)
    // All require JWT or API key authentication
    // =========================================================================
    
    // Auth endpoints
    if (path === "/api/v1/app/bootstrap") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleAppBootstrap(request, authResult, env as unknown as ApiEnv & BillingEnv & GroupsEnv & AuthEnv);
    }

    if (path === "/api/v1/auth/me") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      ctx.waitUntil(ensureUserProfileAndAcceptInvites(authResult, env as GroupsEnv));
      return handleAuthMe(authResult, env as ApiEnv);
    }

    // Groups collaboration endpoints
    if (path === "/api/v1/users/search" && request.method === "GET") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleSearchUsers(request, authResult, env as GroupsEnv);
    }

    if (path === "/api/v1/users/me/avatar" && request.method === "POST") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleUploadUserAvatar(request, authResult, env as GroupsEnv);
    }

    if (path === "/api/v1/groups") {
      const authResult = await validateAuth(request, env as AuthEnv);
      if (request.method === "GET") return handleListGroups(authResult, env as GroupsEnv);
      if (request.method === "POST") return handleCreateGroup(request, authResult, env as GroupsEnv);
      return new Response("Method not allowed", { status: 405, headers: corsHeaders });
    }

    if (path === "/api/v1/groups/discover" && request.method === "GET") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleDiscoverGroups(request, authResult, env as GroupsEnv);
    }

    if (path === "/api/v1/notifications" && request.method === "GET") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleListNotifications(authResult, env as GroupsEnv);
    }

    if (path === "/api/v1/device-tokens" && request.method === "POST") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleRegisterDeviceToken(request, authResult, env as PushEnv);
    }

    const groupReactionMatch = path.match(/^\/api\/v1\/groups\/([a-f0-9-]+)\/snaps\/([a-f0-9-]+)\/reaction$/);
    if (groupReactionMatch && request.method === "POST") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleReactToGroupSnap(groupReactionMatch[1], groupReactionMatch[2], request, authResult, env as GroupsEnv);
    }

    const groupRequestActionMatch = path.match(/^\/api\/v1\/groups\/([a-f0-9-]+)\/requests\/([a-f0-9-]+)\/(approve|deny)$/);
    if (groupRequestActionMatch && request.method === "POST") {
      const authResult = await validateAuth(request, env as AuthEnv);
      const groupId = groupRequestActionMatch[1];
      const requestId = groupRequestActionMatch[2];
      const action = groupRequestActionMatch[3];
      if (action === 'approve') return handleApproveJoinRequest(groupId, requestId, authResult, env as GroupsEnv);
      if (action === 'deny') return handleDenyJoinRequest(groupId, requestId, authResult, env as GroupsEnv);
    }

    const groupActionMatch = path.match(/^\/api\/v1\/groups\/([a-f0-9-]+)(?:\/([^/]+))?(?:\/([^/]+))?$/);
    if (groupActionMatch) {
      const authResult = await validateAuth(request, env as AuthEnv);
      const groupId = groupActionMatch[1];
      const action = groupActionMatch[2];
      const subAction = groupActionMatch[3];

      if (!action && request.method === "GET") return handleGetGroup(groupId, authResult, env as GroupsEnv);
      if (action === "invite" && request.method === "POST") return handleInviteToGroup(groupId, request, authResult, env as GroupsEnv);
      if (action === "accept" && request.method === "POST") return handleAcceptGroupInvite(groupId, authResult, env as GroupsEnv);
      if (action === "decline" && request.method === "POST") return handleDeclineGroupInvite(groupId, authResult, env as GroupsEnv);
      if (action === "join" && request.method === "POST") return handleRequestToJoinGroup(groupId, authResult, env as GroupsEnv);
      if (action === "admin" && request.method === "POST") return handleTransferGroupAdmin(groupId, request, authResult, env as GroupsEnv);
      if (action === "avatar" && request.method === "POST") return handleUploadGroupAvatar(groupId, request, authResult, env as GroupsEnv);
      if (action === "snaps" && request.method === "POST") return handleShareSnapToGroup(groupId, request, authResult, env as GroupsEnv);
      if (action === "seen" && request.method === "POST") return handleMarkGroupSeen(groupId, authResult, env as GroupsEnv);
      if (action === "leave" && request.method === "POST") return handleLeaveGroup(groupId, request, authResult, env as GroupsEnv);
      return new Response("Method not allowed", { status: 405, headers: corsHeaders });
    }
    
    if (path === "/api/v1/auth/api-keys") {
      const authResult = await validateAuth(request, env as AuthEnv);
      if (request.method === "GET") {
        return handleListApiKeys(authResult, env as ApiEnv);
      }
      if (request.method === "POST") {
        return handleCreateApiKey(request, authResult, env as ApiEnv);
      }
      return new Response("Method not allowed", { status: 405, headers: corsHeaders });
    }
    
    // DELETE /api/v1/auth/api-keys/:id
    const apiKeyDeleteMatch = path.match(/^\/api\/v1\/auth\/api-keys\/([a-f0-9-]+)$/);
    if (apiKeyDeleteMatch && request.method === "DELETE") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleDeleteApiKey(apiKeyDeleteMatch[1], authResult, env as ApiEnv);
    }
    
    // POST /api/v1/auth/revoke-all-sessions - Sign out from all devices
    if (path === "/api/v1/auth/revoke-all-sessions") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleRevokeAllSessions(authResult, env as ApiEnv);
    }
    
    // Notes endpoints
    if (path === "/api/v1/notes/stats") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleNotesStats(authResult, env as ApiEnv);
    }
    
    if (path === "/api/v1/notes/tags/all") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleListTags(authResult, env as ApiEnv);
    }
    
    // GET /api/v1/notes/:id/highlights
    const highlightsMatch = path.match(/^\/api\/v1\/notes\/([a-f0-9-]+)\/highlights$/);
    if (highlightsMatch && request.method === 'GET') {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleNoteHighlights(highlightsMatch[1], authResult, env as ApiEnv);
    }

    // POST /api/v1/notes/:id/instagram-preview/refresh
    const instagramPreviewRefreshMatch = path.match(/^\/api\/v1\/notes\/([a-f0-9-]+)\/instagram-preview\/refresh$/);
    if (instagramPreviewRefreshMatch && request.method === 'POST') {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleRefreshInstagramPreview(instagramPreviewRefreshMatch[1], authResult, env as ApiEnv);
    }

    // GET /api/v1/newspaper - generate daily newspaper edition
    if (path === "/api/v1/newspaper" && request.method === "GET") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleNewspaperEdition(request, authResult, env as ApiEnv);
    }

    // ───── Recap (daily / weekly / monthly slideshow) ─────
    // GET /api/v1/recap?period=day|week|month[&date=YYYY-MM-DD][&refresh=1]
    if (path === "/api/v1/recap" && request.method === "GET") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleRecapGet(request, authResult, env as RecapEnv);
    }
    // POST /api/v1/recap/save
    if (path === "/api/v1/recap/save" && request.method === "POST") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleRecapSave(request, authResult, env as RecapEnv);
    }
    // GET /api/v1/recap/saved
    if (path === "/api/v1/recap/saved" && request.method === "GET") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleRecapListSaved(request, authResult, env as RecapEnv);
    }
    // GET /api/v1/recap/saved/:id  or  DELETE /api/v1/recap/saved/:id
    const savedRecapMatch = path.match(/^\/api\/v1\/recap\/saved\/([a-f0-9-]+)$/);
    if (savedRecapMatch) {
      const authResult = await validateAuth(request, env as AuthEnv);
      if (request.method === "GET") {
        return handleRecapGetSaved(savedRecapMatch[1], authResult, env as RecapEnv);
      }
      if (request.method === "DELETE") {
        return handleRecapDeleteSaved(savedRecapMatch[1], authResult, env as RecapEnv);
      }
      return new Response("Method not allowed", { status: 405, headers: corsHeaders });
    }

    // GET /api/v1/notes/:id/view-token
    const viewTokenMatch = path.match(/^\/api\/v1\/notes\/([a-f0-9-]+)\/view-token$/);
    if (viewTokenMatch && request.method === "GET") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleGetViewToken(viewTokenMatch[1], authResult, env as ApiEnv);
    }

    // POST /api/v1/notes/:id/recreate - quick-note edit via DO async pipeline
    const recreateNoteMatch = path.match(/^\/api\/v1\/notes\/([a-f0-9-]+)\/recreate$/);
    if (recreateNoteMatch && request.method === "POST") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleEditQuickNoteWithDO(request, recreateNoteMatch[1], authResult, env as UploadEnv);
    }
    
    // DELETE /api/v1/notes/bulk - Delete multiple notes at once
    if (path === "/api/v1/notes/bulk" && request.method === "DELETE") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleBulkDeleteNotes(request, authResult, env as ApiEnvWithVectorize);
    }
    
    // DELETE /api/v1/notes/:id - Delete a note (soft delete)
    const deleteNoteMatch = path.match(/^\/api\/v1\/notes\/([a-f0-9-]+)$/);
    if (deleteNoteMatch && request.method === "DELETE") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleDeleteNote(deleteNoteMatch[1], authResult, env as ApiEnvWithVectorize);
    }
    
    // GET /api/v1/notes/ or /api/v1/notes (list notes)
    if ((path === "/api/v1/notes/" || path === "/api/v1/notes") && request.method === "GET") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleListNotes(request, authResult, env as ApiEnv);
    }
    
    // =========================================================================
    // Upload Endpoints (using Durable Objects for long-running processing)
    // POST /api/v1/upload/file - Upload a document file
    // POST /api/v1/upload/screenshot - Upload a screenshot
    // POST /api/v1/upload/quick-note - Create a quick note
    // POST /api/v1/upload/cancel/:trace_id - Cancel an upload
    // GET  /api/v1/upload/status/:trace_id - Check upload status
    // GET  /api/v1/upload/quota - Check storage quota
    // =========================================================================
    if (path === "/api/v1/upload/file") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      // Use Durable Object version for long-running uploads (no 30s timeout)
      return handleUploadFileWithDO(request, authResult, env as unknown as UploadEnv);
    }
    
    if (path === "/api/v1/upload/screenshot") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      // Use Durable Object version for long-running uploads (no 30s timeout)
      return handleUploadScreenshotWithDO(request, authResult, env as unknown as UploadEnv);
    }
    
    if (path === "/api/v1/upload/quick-note") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      // Use Durable Object version for consistency
      return handleUploadQuickNoteWithDO(request, authResult, env as unknown as UploadEnv);
    }
    
    if (path === "/api/v1/upload/webpage") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleUploadWebpageWithDO(request, authResult, env as unknown as UploadEnv);
    }

    // Share-intent path: native social apps share their URL here. The handler
    // detects the platform (YouTube, …) and runs a platform-specific enricher
    // (e.g. transcript fetch). Unknown URLs transparently fall back to the
    // webpage scrape path above.
    if (path === "/api/v1/upload/shared-url") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleUploadSharedUrlWithDO(request, authResult, env as unknown as UploadEnv);
    }

    
    // POST /api/v1/upload/cancel/:trace_id - Cancel an upload
    const uploadCancelMatch = path.match(/^\/api\/v1\/upload\/cancel\/(.+)$/);
    if (uploadCancelMatch) {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleCancelUpload(uploadCancelMatch[1], authResult, env as unknown as UploadEnv);
    }
    
    if (path === "/api/v1/upload/quota") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleUploadQuota(authResult, env as unknown as UploadEnv);
    }

    // =========================================================================
    // Billing / plan placeholders. Payment gateway webhooks can replace the
    // manual upgrade endpoint later; quota enforcement already reads the same
    // user_plans and monthly usage tables.
    // =========================================================================
    if (path === "/api/v1/billing/status") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleBillingStatus(authResult, env as unknown as BillingEnv);
    }

    if (path === "/api/v1/billing/upgrade-dev") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleBillingUpgradeDev(authResult, env as unknown as BillingEnv);
    }

    if (path === "/api/v1/billing/cancel") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleBillingCancel(authResult, env as unknown as BillingEnv);
    }

    if (path === "/api/v1/billing/reactivate") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleBillingReactivate(authResult, env as unknown as BillingEnv);
    }

    if (path === "/api/v1/billing/history") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleBillingHistory(authResult, env as unknown as BillingEnv);
    }
    
    // Debug: Test TensorLake directly
    if (path === "/api/v1/upload/test-tensorlake") {
      return handleTestTensorLake(request, env as unknown as UploadEnv);
    }

    // (Removed) IG enrichment queue admin endpoints — Apify-based IG
    // enrichment was retired. The queue table, RPCs, and ig-enrich-queue.ts
    // module were dropped along with the every-minute cron drainer.

    // GET /api/v1/upload/status/:trace_id
    const uploadStatusMatch = path.match(/^\/api\/v1\/upload\/status\/(.+)$/);
    if (uploadStatusMatch) {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleUploadStatus(uploadStatusMatch[1], authResult, env as unknown as UploadEnv, url);
    }
    
    // =========================================================================
    // Document view endpoint (no API key - uses signed token in URL)
    // GET /notes/:id/view?token=... OR /api/v1/notes/:id/view?token=...
    // =========================================================================
    const noteViewMatch = path.match(/^(\/api\/v1)?\/notes\/([a-f0-9-]+)\/view$/);
    if (noteViewMatch) {
      console.log(`ðŸ“„ Note view request: path="${path}"`);
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const noteId = noteViewMatch[2]; // Group 2 is the note ID now
      const token = url.searchParams.get('token');
      console.log(`ðŸ“„ Note view: noteId=${noteId.slice(0,8)}..., hasToken=${!!token}`);
      return handleNoteView(noteId, token, env);
    }
    
    // Also check for /view/ path (some links might have trailing content)
    if (path.startsWith('/notes/') && path.includes('/view')) {
      console.log(`ðŸ“„ Unmatched notes/view path: path="${path}"`);
    }
    
    // =========================================================================
    // MCP (Model Context Protocol) Server for Claude Desktop
    // Supports: API Key (X-API-Key na_*), JWT (Authorization: Bearer)
    // =========================================================================
    if (path === "/mcp") {
      console.log(`[${requestId}] MCP request from Claude Desktop`);
      return handleMCP(request, env as unknown as MCPEnv, ctx);
    }
    
    // =========================================================================
    // NEW: Authenticated RAG search endpoint for frontend direct calls
    // Supports: JWT (Authorization: Bearer), API Key (X-API-Key na_*), Worker Key
    // =========================================================================
    if (path === "/rag-search-auth") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      
      // Capture auth timing
      const authStartTime = Date.now();
      const authStartedAt = new Date().toISOString();
      
      // Validate auth (JWT, user API key, or worker API key)
      const authResult = await validateAuth(request, env as AuthEnv);
      
      const authCompletedAt = new Date().toISOString();
      const authDurationMs = Date.now() - authStartTime;
      
      if (!authResult.authenticated) {
        return new Response(
          JSON.stringify({ error: authResult.error || "Unauthorized" }),
          { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      
      // Clone request to read body (can only read once)
      const body = await request.json() as { query?: string; user_id?: string; max_results?: number; debug?: boolean; client_source?: string; tag_filter?: string | string[]; new_session?: boolean; exclude_note_ids?: string[]; note_id?: string };
      
      // Get user_id from auth or body
      let userId = authResult.user_id;
      
      // For worker_key auth (server-to-server), user_id must come from body
      if (authResult.auth_method === 'worker_key') {
        userId = body.user_id;
      }
      
      if (!userId) {
        return new Response(
          JSON.stringify({ error: "user_id required - either in JWT or request body" }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      
      if (!body.query) {
        return new Response(
          JSON.stringify({ error: "query is required" }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }

      const isGoogleSearch = body.client_source === 'google-search';
      const quotaMetric = isGoogleSearch ? 'google_search' : 'snapbot_search';
      const quotaDecision = await consumeQuota(
        env as unknown as BillingEnv,
        userId,
        quotaMetric,
        requestId,
        {
          query: body.query.slice(0, 500),
          client_source: body.client_source || null,
          search_deeper: Array.isArray(body.exclude_note_ids) && body.exclude_note_ids.length > 0,
        },
      );
      if (!quotaDecision.allowed) {
        return quotaExceededResponse(quotaDecision);
      }
      
      console.log(`[${requestId}] RAG auth: method=${authResult.auth_method}, user=${userId.slice(0, 8)}, auth_ms=${authDurationMs}, source=${body.client_source || 'unknown'}`);
      
      // Create new request with user_id from auth AND auth timing data
      const modifiedRequest = new Request(request.url, {
        method: "POST",
        headers: request.headers,
        body: JSON.stringify({
          query: body.query,
          user_id: userId,
          max_results: body.max_results,
          debug: body.debug,
          client_source: body.client_source,  // Forward client_source to handleRagSearch
          tag_filter: body.tag_filter,  // Forward explicit tag filter
          new_session: body.new_session,  // Forward new session flag to clear stale KV
          exclude_note_ids: body.exclude_note_ids,  // Forward for "search deeper"
          note_id: body.note_id,  // Forward anchored note constraint
          // Pass auth timing data to handleRagSearch
          _auth_timing: {
            auth_started_at: authStartedAt,
            auth_completed_at: authCompletedAt,
            timing_auth_ms: authDurationMs,
            auth_method: authResult.auth_method,
            auth_user_email: (authResult as any).user_email,
          }
        }),
      });
      
      return handleRagSearch(
        modifiedRequest,
        env as unknown as RagSearchEnv,
        ctx,
        requestId,
        performHybridSearch
      );
    }

    // =========================================================================
    // Agent search endpoint (Phase 0/1) — additive, isolated from /rag-search.
    // If the agent claims the query (currently: counting/group queries) it
    // returns an answer directly. Otherwise it forwards to handleRagSearch
    // unchanged so behaviour is identical to /rag-search-auth.
    // =========================================================================
    if (path === "/agent-search-auth") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }

      const authStartTime = Date.now();
      const authStartedAt = new Date().toISOString();
      const authResult = await validateAuth(request, env as AuthEnv);
      const authCompletedAt = new Date().toISOString();
      const authDurationMs = Date.now() - authStartTime;

      if (!authResult.authenticated) {
        return new Response(
          JSON.stringify({ error: authResult.error || "Unauthorized" }),
          { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }

      const body = await request.json() as { query?: string; user_id?: string; max_results?: number; debug?: boolean; client_source?: string; tag_filter?: string | string[]; new_session?: boolean; exclude_note_ids?: string[]; note_id?: string };

      let userId = authResult.user_id;
      if (authResult.auth_method === 'worker_key') {
        userId = body.user_id;
      }
      if (!userId) {
        return new Response(
          JSON.stringify({ error: "user_id required" }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      if (!body.query) {
        return new Response(
          JSON.stringify({ error: "query is required" }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }

      const isGoogleSearch = body.client_source === 'google-search';
      const quotaMetric = isGoogleSearch ? 'google_search' : 'snapbot_search';
      const quotaDecision = await consumeQuota(
        env as unknown as BillingEnv,
        userId,
        quotaMetric,
        requestId,
        {
          query: body.query.slice(0, 500),
          client_source: body.client_source || null,
          search_deeper: Array.isArray(body.exclude_note_ids) && body.exclude_note_ids.length > 0,
          agent: true,
        },
      );
      if (!quotaDecision.allowed) {
        return quotaExceededResponse(quotaDecision);
      }

      // -----------------------------------------------------------------
      // MIGRATED 2025-01: This endpoint URL is preserved for Flutter/extension
      // callers, but now routes through the v2 planner-loop handler. The old
      // regex router (./agent/handler.ts and ./agent/understand.ts) is
      // commented out for rollback — see those files' headers for context.
      // -----------------------------------------------------------------
      const { handleAgentV2Search } = await import('./agent_v2/handler');
      const { performLeanVectorSearch } = await import('./agent_v2/lean_search');

      // Closure that builds the modified request and invokes classic search.
      // The agent handler calls this when it can't claim the query, then
      // post-processes the response through the Phase 3 controller.
      const forwardToClassic = async (): Promise<Response> => {
        const modifiedRequest = new Request(request.url, {
          method: "POST",
          headers: request.headers,
          body: JSON.stringify({
            query: body.query,
            user_id: userId,
            max_results: body.max_results,
            debug: body.debug,
            client_source: body.client_source,
            tag_filter: body.tag_filter,
            new_session: body.new_session,
            exclude_note_ids: body.exclude_note_ids,
            note_id: body.note_id,
            _auth_timing: {
              auth_started_at: authStartedAt,
              auth_completed_at: authCompletedAt,
              timing_auth_ms: authDurationMs,
              auth_method: authResult.auth_method,
              auth_user_email: (authResult as any).user_email,
            },
          }),
        });
        return handleRagSearch(
          modifiedRequest,
          env as unknown as RagSearchEnv,
          ctx,
          requestId,
          performHybridSearch,
        );
      };

      return handleAgentV2Search(
        { ...body, query: body.query, user_id: userId },
        env as unknown as RagSearchEnv,
        ctx,
        requestId,
        forwardToClassic,
        // Lean retrieval closure — binds env/ctx/userId; the planner's
        // vector_search tool calls this directly, skipping rag-search.ts's
        // LLM gates (spell-check, plan-gate, intent, rewriter, synthesis).
        (q, k, exclude, tag) => performLeanVectorSearch(
          { query: q, user_id: userId!, k, exclude_note_ids: exclude, tag },
          performHybridSearch,
          env as any,
          ctx,
        ),
      );
    }

    // =========================================================================
    // Agent V2 search endpoint — function-calling planner agent.
    //
    // This is the Step-1 build of the simplified architecture: a single Groq
    // tool-use loop replaces the regex router and 5-lane dispatch in
    // /agent-search-auth. Both endpoints run in parallel during validation.
    // Once parity is proven, /agent-search-auth's regex router will be
    // commented out and traffic migrated to /agent-v2-search-auth.
    // =========================================================================
    if (path === "/agent-v2-search-auth") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }

      const authStartTime = Date.now();
      const authStartedAt = new Date().toISOString();
      const authResult = await validateAuth(request, env as AuthEnv);
      const authCompletedAt = new Date().toISOString();
      const authDurationMs = Date.now() - authStartTime;

      if (!authResult.authenticated) {
        return new Response(
          JSON.stringify({ error: authResult.error || "Unauthorized" }),
          { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }

      const body = await request.json() as { query?: string; user_id?: string; max_results?: number; debug?: boolean; client_source?: string; tag_filter?: string | string[]; new_session?: boolean; exclude_note_ids?: string[]; note_id?: string };

      let userId = authResult.user_id;
      if (authResult.auth_method === 'worker_key') {
        userId = body.user_id;
      }
      if (!userId) {
        return new Response(
          JSON.stringify({ error: "user_id required" }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      if (!body.query) {
        return new Response(
          JSON.stringify({ error: "query is required" }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }

      const isGoogleSearch = body.client_source === 'google-search';
      const quotaMetric = isGoogleSearch ? 'google_search' : 'snapbot_search';
      const quotaDecision = await consumeQuota(
        env as unknown as BillingEnv,
        userId,
        quotaMetric,
        requestId,
        {
          query: body.query.slice(0, 500),
          client_source: body.client_source || null,
          search_deeper: Array.isArray(body.exclude_note_ids) && body.exclude_note_ids.length > 0,
          agent_v2: true,
        },
      );
      if (!quotaDecision.allowed) {
        return quotaExceededResponse(quotaDecision);
      }

      const { handleAgentV2Search } = await import('./agent_v2/handler');
      const { performLeanVectorSearch } = await import('./agent_v2/lean_search');

      // Forward closure used by the vector_search tool — invokes the existing
      // /rag-search-auth pipeline as a sub-tool. Same shape as agent v1.
      const forwardToClassic = async (): Promise<Response> => {
        const modifiedRequest = new Request(request.url, {
          method: "POST",
          headers: request.headers,
          body: JSON.stringify({
            query: body.query,
            user_id: userId,
            max_results: body.max_results,
            debug: body.debug,
            client_source: body.client_source,
            tag_filter: body.tag_filter,
            new_session: body.new_session,
            exclude_note_ids: body.exclude_note_ids,
            note_id: body.note_id,
            _auth_timing: {
              auth_started_at: authStartedAt,
              auth_completed_at: authCompletedAt,
              timing_auth_ms: authDurationMs,
              auth_method: authResult.auth_method,
              auth_user_email: (authResult as any).user_email,
            },
          }),
        });
        return handleRagSearch(
          modifiedRequest,
          env as unknown as RagSearchEnv,
          ctx,
          requestId,
          performHybridSearch,
        );
      };

      return handleAgentV2Search(
        { ...body, query: body.query, user_id: userId },
        env as unknown as RagSearchEnv,
        ctx,
        requestId,
        forwardToClassic,
        (q, k, exclude, tag) => performLeanVectorSearch(
          { query: q, user_id: userId!, k, exclude_note_ids: exclude, tag },
          performHybridSearch,
          env as any,
          ctx,
        ),
      );
    }

    // =========================================================================
    // Authenticated RAG search continue endpoint for progressive search
    // Supports: JWT (Authorization: Bearer), API Key (X-API-Key na_*), Worker Key
    // =========================================================================
    if (path === "/rag-search-continue-auth") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      
      // Validate auth (JWT, user API key, or worker API key)
      const authResult = await validateAuth(request, env as AuthEnv);
      
      if (!authResult.authenticated) {
        return new Response(
          JSON.stringify({ error: authResult.error || "Unauthorized" }),
          { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      
      // Clone request to read body
      const body = await request.json() as { query?: string; user_id?: string; remaining_note_ids?: string[]; query_type?: string };
      
      // Get user_id from auth or body
      let userId = authResult.user_id;
      if (authResult.auth_method === 'worker_key') {
        userId = body.user_id;
      }
      
      if (!userId) {
        return new Response(
          JSON.stringify({ error: "user_id required - either in JWT or request body" }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      
      console.log(`[${requestId}] RAG continue auth: method=${authResult.auth_method}, user=${userId.slice(0, 8)}`);
      
      // Create modified request with user_id from auth
      const modifiedRequest = new Request(request.url, {
        method: request.method,
        headers: request.headers,
        body: JSON.stringify({
          ...body,
          user_id: userId,
        }),
      });
      
      return handleRagSearchContinue(
        modifiedRequest,
        env as unknown as RagSearchEnv,
        ctx,
        requestId,
        performHybridSearch
      );
    }
    
    // Validate API key for all other endpoints
    if (!validateApiKey(request, env)) {
      return new Response(
        JSON.stringify({ error: "Unauthorized - Invalid or missing API key" }),
        { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Route requests
    switch (path) {
      case "/rag-search":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleRagSearch(
          request,
          env as unknown as RagSearchEnv,
          ctx,
          requestId,
          performHybridSearch
        );

      case "/rag-search-continue":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleRagSearchContinue(
          request,
          env as unknown as RagSearchEnv,
          ctx,
          requestId,
          performHybridSearch
        );
        
      case "/search":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleSearch(request, env, ctx, requestId);
        
      case "/rerank":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleRerank(request, env, ctx, requestId);
        
      case "/embed":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleEmbed(request, env, ctx, requestId);
        
      case "/embed-batch":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleEmbedBatch(request, env, ctx, requestId);
        
      case "/upsert":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleUpsert(request, env);
        
      case "/delete":
        if (request.method !== "POST" && request.method !== "DELETE") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleDelete(request, env);
        
      case "/cache/invalidate":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleCacheInvalidate(request, env, requestId);
        
      default:
        return new Response(
          JSON.stringify({ 
            error: "Not found",
            endpoints: ["/health", "/rag-search", "/search", "/rerank", "/embed", "/embed-batch", "/upsert", "/delete", "/cache/invalidate", "/api/v1/upload/file", "/api/v1/upload/screenshot", "/api/v1/upload/quick-note", "/api/v1/upload/status/:id", "/api/v1/upload/quota"],
          }),
          { status: 404, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
    }
  },

  // ───────────────────────────────────────────────────────────────────────────
  // Cron scheduler — pre-warms weekly recap caches every Sunday 09:00 UTC
  // and daily recap caches every morning 08:00 UTC.
  // Configured in wrangler.toml [triggers] crons.
  // ───────────────────────────────────────────────────────────────────────────
  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    const cron = event.cron;

    // Stuck-upload sweeper (Suggestion 3) — runs on every cron tick.
    // If a Durable Object dies in a weird way (or its failure-cleanup
    // itself crashes), an upload_traces row can sit in 'accepted' or
    // 'processing' forever and the user sees a permanent "Saving…"
    // placeholder. This sweeper marks anything older than 15 minutes
    // as failed, deletes the placeholder note, and refunds the quota.
    try {
      await sweepStuckUploads(env, 15);
    } catch (e) {
      console.log('[cron] sweepStuckUploads failed', String(e));
    }

    // Cron `*/15 * * * *` is dedicated to the stuck-upload sweeper —
    // skip the recap fan-out branch for it so we don't burn subrequests.
    if (cron === '*/15 * * * *') {
      return;
    }

    let period: 'day' | 'week' | 'month';
    if (cron === '0 9 * * 0') period = 'week';
    else if (cron === '0 9 1 * *') period = 'month';
    else period = 'day';

    console.log(`[cron] recap fan-out start cron="${cron}" period=${period}`);
    const t0 = Date.now();

    const recapEnv = env as unknown as RecapEnv;
    let userIds: string[] = [];
    try {
      userIds = await listActiveUserIds(recapEnv, period === 'month' ? 45 : 14);
    } catch (e) {
      console.log('[cron] listActiveUserIds failed', String(e));
      return;
    }

    console.log(`[cron] fan-out across ${userIds.length} active users`);
    const BATCH = 5;
    let ok = 0, fail = 0;
    for (let i = 0; i < userIds.length; i += BATCH) {
      const batch = userIds.slice(i, i + BATCH);
      const results = await Promise.allSettled(
        batch.map(uid => generateRecapForUser(recapEnv, uid, period))
      );
      for (const r of results) {
        if (r.status === 'fulfilled') ok++; else { fail++; console.log('[cron] recap fail', String(r.reason)); }
      }
    }
    console.log(`[cron] done ok=${ok} fail=${fail} elapsed=${Date.now() - t0}ms`);
  },
};
