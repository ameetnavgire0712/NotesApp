/**
 * NotesApp Vector Search Worker - Enhanced with Voyage AI Reranking
 * 
 * Runs at Cloudflare edge for low-latency vector operations.
 * - /mcp: MCP (Model Context Protocol) server for Claude Desktop
 * - /rag-search-auth: Full RAG pipeline with JWT/API key auth (for frontend direct calls)
 * - /rag-search: Full RAG pipeline (spell check + tags + hybrid search + synthesis)
 * - /hybrid: Combined embed + search + rerank (single call - FASTEST)
 * - /search: Query vectors with optional filters
 * - /rerank: Rerank documents using Voyage AI
 * - /embed: Generate embedding for text
 * - /embed-batch: Generate embeddings for multiple texts
 * - /upsert: Insert or update vectors
 * - /delete: Remove vectors by ID
 * - /health: Health check
 */

import { handleRagSearch, RagSearchEnv } from './rag-search';
import { handleMCP, MCPEnv } from './mcp-server';
import { validateAuth, AuthResult, AuthEnv } from './auth';
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
  handleDeleteNote,
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
  handleUploadStatus,
  handleUploadQuota,
  handleCancelUpload,
  handleTestTensorLake,
  UploadEnv,
} from './upload-routes';

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
  TENSORLAKE_API_KEY?: string;  // TensorLake document conversion API key
  UPLOAD_PROCESSOR: DurableObjectNamespace;  // Durable Object for long-running uploads
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
  rerank_top_k?: number;   // How many to fetch for reranking (default 20)
  debug?: boolean;         // Return intermediate data for debugging
  correlation_id?: string; // Backend correlation ID for trace linking
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
            query: entry.query,
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
            query: trace.query,
            query_corrected: trace.query_corrected,
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
            auth_user_email: trace.auth_user_email,
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

// Validate API key
function validateApiKey(request: Request, env: Env): boolean {
  const apiKey = request.headers.get("X-API-Key") || 
                 request.headers.get("Authorization")?.replace("Bearer ", "");
  return apiKey === env.WORKER_API_KEY;
}

// Validate user API key (na_* format) against Supabase
async function validateUserApiKey(apiKey: string, env: Env): Promise<{ valid: boolean; user_id?: string }> {
  if (!apiKey || !apiKey.startsWith('na_')) {
    return { valid: false };
  }
  
  try {
    const response = await fetch(`${env.SUPABASE_URL}/rest/v1/api_keys?key_value=eq.${apiKey}&select=user_id,is_active`, {
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
  timing_total_flow_ms: number;
  timing_settings_check_ms?: number;
  timing_backend_search_ms?: number;
  timing_notification_ms?: number;
  timing_delay_ms?: number;
  timing_backend_reported_ms?: number;
  results_count?: number;
  source?: string;
}

async function handleExtensionTiming(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  // Validate API key (user API key na_* or worker API key)
  const apiKey = request.headers.get("X-API-Key");
  
  if (!apiKey) {
    return new Response(
      JSON.stringify({ success: false, error: "API key required" }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  // Check if it's a user API key (na_*) or worker API key
  let isAuthorized = false;
  if (apiKey.startsWith('na_')) {
    const validation = await validateUserApiKey(apiKey, env);
    isAuthorized = validation.valid;
  } else {
    isAuthorized = apiKey === env.WORKER_API_KEY;
  }
  
  if (!isAuthorized) {
    return new Response(
      JSON.stringify({ success: false, error: "Invalid API key" }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  try {
    const timing = await request.json() as ExtensionTimingRequest;
    
    if (!timing.correlation_id) {
      return new Response(
        JSON.stringify({ success: false, error: "correlation_id required" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Update the existing search trace with extension timing data
    const updateData = {
      extension_total_flow_ms: timing.timing_total_flow_ms,
      extension_settings_check_ms: timing.timing_settings_check_ms,
      extension_backend_search_ms: timing.timing_backend_search_ms,
      extension_notification_ms: timing.timing_notification_ms,
      extension_delay_ms: timing.timing_delay_ms,
      extension_source: timing.source || 'chrome-extension',
    };
    
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
    
    // Calculate the overhead
    const backendReported = timing.timing_backend_reported_ms || 0;
    const totalFlow = timing.timing_total_flow_ms;
    const overhead = totalFlow - backendReported > 0 ? totalFlow - backendReported : 0;
    
    console.log(`[Extension Timing] ${timing.correlation_id}: Total=${totalFlow}ms, Backend=${backendReported}ms, Overhead=${overhead}ms`);
    
    return new Response(
      JSON.stringify({
        success: true,
        correlation_id: timing.correlation_id,
        timing_overhead_ms: overhead,
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

// Supabase keyword search interface
interface SupabaseKeywordResult {
  id: string;
  title: string;
  tag: string;
  text_rank: number;
}

// Call Supabase RPC for full-text keyword search
async function keywordSearch(
  query: string,
  userId: string,
  env: Env,
  tag?: string,
  limit: number = 20
): Promise<{ results: Map<string, number>, time_ms: number }> {
  const start = Date.now();
  
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_KEY) {
    console.log("Supabase credentials not configured, skipping keyword search");
    return { results: new Map(), time_ms: 0 };
  }
  
  try {
    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/rpc/search_notes_fulltext`,
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
      console.error(`Supabase keyword search failed: ${response.status} - ${error}`);
      return { results: new Map(), time_ms: Date.now() - start };
    }
    
    const data: SupabaseKeywordResult[] = await response.json();
    const time_ms = Date.now() - start;
    
    // Convert to Map<note_id, text_rank>
    const results = new Map<string, number>();
    for (const doc of data) {
      results.set(doc.id, doc.text_rank);
    }
    
    console.log(`Keyword search: ${results.size} matches in ${time_ms}ms`);
    return { results, time_ms };
    
  } catch (error) {
    console.error("Keyword search error:", error);
    return { results: new Map(), time_ms: Date.now() - start };
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

// Handle hybrid search - combines embed + vector search + keyword search + rerank in single call
async function handleHybridSearch(request: Request, env: Env, ctx: ExecutionContext, requestId: string): Promise<Response> {
  const start = Date.now();
  const timing: Record<string, number> = {};
  let userId: string | undefined;
  let queryText: string | undefined;
  
  // Timestamp tracking for detailed trace logging
  const timestamps: {
    request_received_at: string;
    auth_started_at?: string;
    auth_completed_at?: string;
    embedding_started_at?: string;
    search_started_at?: string;
    rerank_started_at?: string;
    response_sent_at?: string;
  } = {
    request_received_at: new Date(start).toISOString(),
  };
  
  // Auth info tracking
  let authMethod: string | undefined;
  let authUserEmail: string | undefined;
  let authDurationMs: number | undefined;
  
  // Trace data containers - ALWAYS captured for persistent logging
  const traceData: {
    vector_candidates: Array<Record<string, any>>;
    keyword_candidates: Array<Record<string, any>>;
    combined_candidates: Array<Record<string, any>>;
    reranked_candidates: Array<Record<string, any>>;
    final_results: Array<Record<string, any>>;
  } = {
    vector_candidates: [],
    keyword_candidates: [],
    combined_candidates: [],
    reranked_candidates: [],
    final_results: [],
  };
  
  // Correlation ID for trace linking - use backend's ID if provided, else Worker's requestId
  let traceCorrelationId = requestId;
  
  // Thresholds defined at top for use throughout the function
  const MIN_VECTOR_SIMILARITY = 0.15;
  const MIN_RERANK_SCORE = 0.5;
  
  try {
    const parseStart = Date.now();
    const body: HybridSearchRequest = await request.json();
    timing.parse_ms = Date.now() - parseStart;
    
    queryText = body.query;
    userId = body.user_id;
    const debugMode = body.debug === true;
    
    // Use backend correlation_id if provided for trace linking
    if (body.correlation_id) {
      traceCorrelationId = body.correlation_id;
    }
    
    if (!body.query) {
      return new Response(
        JSON.stringify({ error: "Must provide 'query'" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    const limit = body.limit || 10;
    const doRerank = body.rerank !== false; // Default true
    const rerankTopK = body.rerank_top_k || 20;
    
    // STEP 0: Check search results cache (if user_id provided) - SKIP cache for debug mode
    if (userId && !debugMode) {
      const cachedSearch = await getCachedSearchResultsVersioned(body.query, userId, limit, body.tag, env);
      if (cachedSearch) {
        timing.total_ms = Date.now() - start;
        timing.search_cache_hit = 1;
        console.log(`[${requestId}] Search cache HIT, returning cached results from ${new Date(cachedSearch.cached_at).toISOString()}`);
        
        // Log cache hit
        sendLogToBackend({
          request_id: requestId,
          timestamp: new Date().toISOString(),
          endpoint: "/hybrid",
          method: "POST",
          user_id: userId,
          query: queryText,
          timing,
          result: { 
            match_count: cachedSearch.results.matches?.length || 0,
            search_cache_hit: true,
            cached_at: cachedSearch.cached_at
          },
        }, env, ctx);
        
        // Send search trace for cache hit (to link with backend correlation_id)
        if (queryText) {
          // Extract cached timing and count info
          const cachedTiming = cachedSearch.results.timing || {};
          sendSearchTraceToBackend({
            correlation_id: traceCorrelationId,  // Use backend's correlation_id if provided
            user_id: userId,
            query: queryText,
            timing_total_ms: timing.total_ms,
            timing_embedding_ms: cachedTiming.embedding_ms || 0,
            timing_vector_search_ms: cachedTiming.parallel_search_ms || cachedTiming.vector_search_ms || 0,
            timing_keyword_search_ms: cachedTiming.keyword_ms || 0,
            timing_rerank_ms: cachedTiming.rerank_ms || 0,
            timing_worker_ms: timing.total_ms,
            embedding_cached: true,  // Assume true for cached results
            search_cached: true,
            // For cached results, we don't have the detailed candidate lists
            vector_candidates: [],
            keyword_candidates: [],
            combined_candidates: [],
            reranked_candidates: [],
            final_results: cachedSearch.results.matches?.map((m: any) => ({
              chunk_id: m.chunk_id,
              doc_id: m.doc_id,
              score: m.score,
              title: m.title,
            })) || [],
            vector_count: cachedSearch.results.matches?.length || 0,
            keyword_count: 0,
            combined_count: cachedSearch.results.matches?.length || 0,
            reranked_count: cachedSearch.results.matches?.length || 0,
            final_count: cachedSearch.results.matches?.length || 0,
            min_vector_threshold: MIN_VECTOR_SIMILARITY,
            min_rerank_threshold: MIN_RERANK_SCORE,
            source_worker: "cloudflare-worker",
            request_path: "/hybrid",
          }, env, ctx);
        }
        
        return new Response(
          JSON.stringify({
            ...cachedSearch.results,
            request_id: requestId,
            timing: {
              ...cachedSearch.results.timing,
              search_cache_hit: true,
              cached_at: cachedSearch.cached_at,
              total_ms: timing.total_ms,
            },
          }),
          { 
            status: 200, 
            headers: { "Content-Type": "application/json", ...corsHeaders } 
          }
        );
      }
    }
    
    // STEP 1: Generate embedding (with cache)
    timestamps.embedding_started_at = new Date().toISOString();
    const embedStart = Date.now();
    const { embedding: queryVector, time_ms: embedTime, cached } = await generateEmbeddingCached(
      body.query, 
      env, 
      ctx
    );
    timing.embedding_ms = embedTime;
    timing.embedding_cached = cached ? 1 : 0;
    
    // STEP 2: Run vector search and keyword search in PARALLEL
    timestamps.search_started_at = new Date().toISOString();
    const filter: VectorizeVectorMetadataFilter = {};
    if (body.user_id) {
      filter["user_id"] = { $eq: body.user_id };
    }
    if (body.tag) {
      filter["tag"] = { $eq: body.tag };
    }
    
    const searchLimit = doRerank ? rerankTopK : limit;
    const parallelStart = Date.now();
    
    // Run both searches in parallel
    const [vectorResults, keywordResults] = await Promise.all([
      env.VECTORIZE.query(queryVector, {
        topK: Math.min(searchLimit, 50),
        returnMetadata: "all",
        filter: Object.keys(filter).length > 0 ? filter : undefined,
      }),
      // Keyword search (if user_id provided)
      userId ? keywordSearch(body.query, userId, env, body.tag, searchLimit) : Promise.resolve({ results: new Map<string, number>(), time_ms: 0 }),
    ]);
    
    timing.parallel_search_ms = Date.now() - parallelStart;
    timing.keyword_ms = keywordResults.time_ms;
    
    console.log(`[${requestId}] Parallel search: vector=${vectorResults.matches.length}, keyword=${keywordResults.results.size} in ${timing.parallel_search_ms}ms`);
    
    // ALWAYS capture trace data for persistent logging (not just debug mode)
    traceData.vector_candidates = vectorResults.matches.map((match) => ({
      chunk_id: match.id,
      note_id: String(match.metadata?.note_id || ""),
      title: String(match.metadata?.title || ""),
      tag: match.metadata?.tag as string | undefined,
      vector_score: match.score,
      content: String(match.metadata?.content || "").substring(0, 300),
    }));
    
    // Capture keyword candidates
    keywordResults.results.forEach((score, noteId) => {
      traceData.keyword_candidates.push({
        note_id: noteId,
        keyword_score: score,
      });
      });
    
    // Transform results and add keyword scores
    let allChunks: Array<Record<string, any>> = vectorResults.matches
      .filter((match) => match.score >= MIN_VECTOR_SIMILARITY)
      .map((match) => {
        const noteId = String(match.metadata?.note_id || "");
        const keywordScore = keywordResults.results.get(noteId) || 0;
        // Combined score: 70% vector + 30% keyword (weighted average)
        const combinedScore = keywordScore > 0
          ? (match.score * 0.7) + (keywordScore * 0.3)
          : match.score;
        return {
          chunk_id: match.id,
          similarity: match.score,
          combined_score: combinedScore,
          keyword_score: keywordScore,
          ...match.metadata,
        };
      });
    
    console.log(`[${requestId}] Vector search: ${vectorResults.matches.length} raw, ${allChunks.length} after threshold ${MIN_VECTOR_SIMILARITY}`);
    
    // STEP 3: Keep TOP 3 CHUNKS per document for reranking (not just 1)
    // This allows reranker to evaluate multiple relevant sections per document
    const TOP_CHUNKS_PER_DOC = 3;
    const chunksPerNote = new Map<string, Array<typeof allChunks[0]>>();
    
    // Group chunks by note_id
    for (const chunk of allChunks) {
      const noteId = String(chunk.note_id || "");
      const existing = chunksPerNote.get(noteId) || [];
      existing.push(chunk);
      chunksPerNote.set(noteId, existing);
    }
    
    // Keep top N chunks per document (sorted by combined_score)
    let matches: Array<typeof allChunks[0]> = [];
    for (const [noteId, chunks] of chunksPerNote) {
      chunks.sort((a, b) => (b.combined_score || b.similarity) - (a.combined_score || a.similarity));
      matches.push(...chunks.slice(0, TOP_CHUNKS_PER_DOC));
    }
    
    // Sort all selected chunks by combined score
    matches.sort((a, b) => (b.combined_score || b.similarity) - (a.combined_score || a.similarity));
    
    console.log(`[${requestId}] Top-${TOP_CHUNKS_PER_DOC} chunks: ${allChunks.length} chunks → ${matches.length} (from ${chunksPerNote.size} documents)`);
    
    // ALWAYS capture combined candidates for trace logging
    traceData.combined_candidates = matches.map((m) => ({
      note_id: String(m.note_id || ""),
      title: String(m.title || ""),
      tag: m.tag as string | undefined,
      vector_score: m.similarity,
      keyword_score: m.keyword_score || 0,
      combined_score: m.combined_score,
      content: String(m.content || "").substring(0, 300),
      passed_threshold: true,  // Already passed MIN_VECTOR_SIMILARITY
    }));
    
    // Thresholds for debug response
    const thresholds = {
      min_vector_similarity: MIN_VECTOR_SIMILARITY,
      min_rerank_score: MIN_RERANK_SCORE,
      vector_weight: 0.7,
      keyword_weight: 0.3,
    };
    
    // STEP 4: Rerank if enabled and we have results
    if (doRerank && matches.length > 0) {
      timestamps.rerank_started_at = new Date().toISOString();
      const rerankStart = Date.now();
      
      // Limit candidates sent to reranker (max 30 to control costs/latency)
      const MAX_RERANK_CANDIDATES = 30;
      const matchesToRerank = matches.slice(0, MAX_RERANK_CANDIDATES);
      
      // Prepare documents for reranking (use content from metadata)
      const documents = matchesToRerank.map(m => 
        String(m.content || m.title || "")
      ).filter(d => d.length > 0);
      
      console.log(`[${requestId}] Rerank: sending ${documents.length}/${matches.length} candidates (max ${MAX_RERANK_CANDIDATES})`);
      
      if (documents.length > 0) {
        try {
          const { results: reranked, time_ms: rerankTime } = await rerank(
            body.query,
            documents,
            env,
            "rerank-2.5",
            limit
          );
          timing.rerank_ms = rerankTime;
          
          // ALWAYS capture reranked candidates for trace logging (before threshold filtering)
          traceData.reranked_candidates = reranked.map((r) => ({
            note_id: String(matchesToRerank[r.index]?.note_id || ""),
            title: String(matchesToRerank[r.index]?.title || ""),
            tag: matchesToRerank[r.index]?.tag as string | undefined,
            combined_score: matchesToRerank[r.index]?.combined_score || 0,
            rerank_score: r.score,
            passed_rerank_threshold: r.score >= MIN_RERANK_SCORE,
            content: String(matchesToRerank[r.index]?.content || "").substring(0, 300),
          }));
          
          // Reorder matches based on rerank scores and filter by threshold
          const rerankedMatches = reranked
            .filter(r => r.score >= MIN_RERANK_SCORE)
            .map(r => ({
              ...matchesToRerank[r.index],
              rerank_score: r.score,
              original_similarity: matchesToRerank[r.index].similarity,
              similarity: r.score, // Use rerank score as final score
            }));
          
          const filteredCount = reranked.length - rerankedMatches.length;
          if (filteredCount > 0) {
            console.log(`[${requestId}] Rerank: filtered ${filteredCount}/${reranked.length} results below threshold ${MIN_RERANK_SCORE}`);
          }
          
          matches = rerankedMatches;
        } catch (rerankError) {
          console.error("Rerank failed, returning unreranked results:", rerankError);
          timing.rerank_error = 1;
          matches = matches.slice(0, limit);
        }
      }
    } else {
      matches = matches.slice(0, limit);
    }
    
    timing.total_ms = Date.now() - start;
    
    console.log(`[${requestId}] Hybrid: ${matches.length} results, embed=${timing.embedding_ms}ms (cached=${cached}), parallel=${timing.parallel_search_ms}ms, keyword=${timing.keyword_ms}ms, rerank=${timing.rerank_ms || 0}ms, total=${timing.total_ms}ms`);
    
    // Capture final results for trace logging
    traceData.final_results = matches.map((m) => ({
      note_id: String(m.note_id || ""),
      title: String(m.title || ""),
      tag: m.tag as string | undefined,
      final_score: m.similarity || m.rerank_score || m.combined_score,
      rerank_score: m.rerank_score,
      original_similarity: m.original_similarity,
      content: String(m.content || "").substring(0, 300),
    }));
    
    // Build response data
    const responseData: Record<string, any> = {
      success: true,
      matches,
      request_id: requestId,
      timing: {
        embedding_ms: timing.embedding_ms,
        embedding_cached: cached,
        parallel_search_ms: timing.parallel_search_ms,
        keyword_ms: timing.keyword_ms,
        rerank_ms: timing.rerank_ms || 0,
        total_ms: timing.total_ms,
      },
      // Always include trace_data for visibility into pipeline
      trace_data: {
        vector_candidates: traceData.vector_candidates,
        keyword_candidates: traceData.keyword_candidates,
        combined_candidates: traceData.combined_candidates,
        reranked_candidates: traceData.reranked_candidates,
        chunks_before_grouping: allChunks.length,
        chunks_after_grouping: matches.length,
        unique_documents: chunksPerNote.size,
      },
    };
    
    // Add full debug data and thresholds if debug mode
    if (debugMode) {
      responseData.debug = traceData;
      responseData.thresholds = thresholds;
    }
    
    // STEP 5: Cache the search results (if user_id provided) - SKIP cache for debug mode
    if (userId && matches.length > 0 && !debugMode) {
      setCachedSearchResultsVersioned(body.query, userId, limit, body.tag, responseData, env, ctx);
    }
    
    // Log to backend
    sendLogToBackend({
      request_id: requestId,
      timestamp: new Date().toISOString(),
      endpoint: "/hybrid",
      method: "POST",
      user_id: userId,
      query: queryText,
      timing,
      result: { 
        match_count: matches.length, 
        vector_count: vectorResults.matches.length,
        keyword_count: keywordResults.results.size,
        embedding_cached: cached,
        reranked: doRerank,
        debug_mode: debugMode
      },
    }, env, ctx);
    
    // Send detailed search trace for persistent logging (if user_id provided)
    timestamps.response_sent_at = new Date().toISOString();
    if (userId && queryText) {
      sendSearchTraceToBackend({
        correlation_id: traceCorrelationId,  // Use backend's correlation_id if provided
        user_id: userId,
        query: queryText,
        // Timestamps for each phase
        request_received_at: timestamps.request_received_at,
        auth_started_at: timestamps.auth_started_at,
        auth_completed_at: timestamps.auth_completed_at,
        embedding_started_at: timestamps.embedding_started_at,
        search_started_at: timestamps.search_started_at,
        rerank_started_at: timestamps.rerank_started_at,
        response_sent_at: timestamps.response_sent_at,
        // Timing durations
        timing_total_ms: timing.total_ms,
        timing_auth_ms: authDurationMs,
        timing_embedding_ms: timing.embedding_ms,
        timing_vector_search_ms: timing.parallel_search_ms,
        timing_keyword_search_ms: timing.keyword_ms,
        timing_rerank_ms: timing.rerank_ms || 0,
        timing_worker_ms: timing.total_ms,
        // Auth details
        auth_method: authMethod,
        auth_user_email: authUserEmail,
        // Cache status
        embedding_cached: cached,
        search_cached: false,
        // Candidates
        vector_candidates: traceData.vector_candidates,
        keyword_candidates: traceData.keyword_candidates,
        combined_candidates: traceData.combined_candidates,
        reranked_candidates: traceData.reranked_candidates,
        final_results: traceData.final_results,
        // Counts
        vector_count: traceData.vector_candidates.length,
        keyword_count: traceData.keyword_candidates.length,
        combined_count: traceData.combined_candidates.length,
        reranked_count: traceData.reranked_candidates.length,
        final_count: traceData.final_results.length,
        // Thresholds
        min_vector_threshold: MIN_VECTOR_SIMILARITY,
        min_rerank_threshold: MIN_RERANK_SCORE,
        source_worker: "cloudflare-worker",
        request_path: "/hybrid",
      }, env, ctx);
    }
    
    return new Response(
      JSON.stringify(responseData),
      { 
        status: 200, 
        headers: { "Content-Type": "application/json", ...corsHeaders } 
      }
    );
    
  } catch (error) {
    timing.total_ms = Date.now() - start;
    const errorMsg = String(error);
    console.error(`[${requestId}] Hybrid error:`, error);
    
    // Log the error
    sendLogToBackend({
      request_id: requestId,
      timestamp: new Date().toISOString(),
      endpoint: "/hybrid",
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
  
  // Get note from Supabase
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
  
  const notes = await noteResponse.json() as Array<{
    id: string;
    title: string;
    blob_url?: string;
    metadata?: { blob_name?: string };
    user_id: string;
    file_type?: string;
    content_markdown?: string;
  }>;
  
  if (notes.length === 0) {
    return new Response(
      JSON.stringify({ detail: "Note not found" }),
      { status: 404, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  const note = notes[0];
  
  // For quick_notes without a blob, return the note content as HTML
  if (note.file_type === 'quick_note' && !note.blob_url) {
    const htmlContent = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${note.title || 'Quick Note'}</title>
<style>body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:700px;margin:40px auto;padding:20px;line-height:1.6;color:#1f2937;background:#fafafa;}
h1{font-size:1.5rem;border-bottom:2px solid #e5e7eb;padding-bottom:12px;margin-bottom:20px;}
.note-content{background:white;border-radius:8px;padding:24px;box-shadow:0 1px 3px rgba(0,0,0,0.1);white-space:pre-wrap;}
.meta{color:#6b7280;font-size:0.85rem;margin-top:16px;}</style></head>
<body><h1>📝 ${note.title || 'Quick Note'}</h1>
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
  
  console.log(`📄 Document view: note=${noteId.slice(0, 8)}... user=${userId.slice(0, 8)}...`);
  
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
        endpoints: ["/health", "/rag-search", "/hybrid", "/search", "/rerank", "/embed", "/embed-batch", "/upsert", "/delete", "/cache/invalidate"],
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
  user_id: string;
  tag?: string;
  limit: number;
  rerank: boolean;
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
  // Candidate data for trace logging
  trace_data?: {
    vector_candidates: Array<Record<string, any>>;
    keyword_candidates: Array<Record<string, any>>;
    combined_candidates: Array<Record<string, any>>;
    reranked_candidates: Array<Record<string, any>>;
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
    combined_candidates: Array<Record<string, any>>;
    reranked_candidates: Array<Record<string, any>>;
  } = {
    vector_candidates: [],
    keyword_candidates: [],
    combined_candidates: [],
    reranked_candidates: [],
  };

  // STEP 1: Generate embedding (with cache)
  const { embedding: queryVector, time_ms: embedTime, cached } = await generateEmbeddingCached(
    params.query,
    env,
    ctx
  );
  timing.embedding_ms = embedTime;

  // STEP 2: Run vector search and keyword search in PARALLEL
  const filter: VectorizeVectorMetadataFilter = {};
  if (params.user_id) {
    filter["user_id"] = { $eq: params.user_id };
  }
  if (params.tag) {
    filter["tag"] = { $eq: params.tag };
  }

  // Fetch more candidates - let threshold filtering determine quality, not arbitrary limits
  const VECTOR_SEARCH_LIMIT = 50;  // Get enough candidates for threshold filtering
  const KEYWORD_SEARCH_LIMIT = 30; // Keyword search is cheaper
  const parallelStart = Date.now();

  const [vectorResults, keywordResults] = await Promise.all([
    env.VECTORIZE.query(queryVector, {
      topK: VECTOR_SEARCH_LIMIT,
      returnMetadata: "all",
      filter: Object.keys(filter).length > 0 ? filter : undefined,
    }),
    params.user_id
      ? keywordSearch(params.query, params.user_id, env, params.tag, KEYWORD_SEARCH_LIMIT)
      : Promise.resolve({ results: new Map<string, number>(), time_ms: 0 }),
  ]);

  timing.parallel_search_ms = Date.now() - parallelStart;
  timing.keyword_ms = keywordResults.time_ms;

  // Capture vector candidates for trace
  trace_data.vector_candidates = vectorResults.matches.map((match) => ({
    chunk_id: match.id,
    note_id: String(match.metadata?.note_id || ""),
    title: String(match.metadata?.title || ""),
    tag: match.metadata?.tag as string | undefined,
    vector_score: match.score,
    content: String(match.metadata?.content || "").substring(0, 300),
  }));

  // Capture keyword candidates for trace
  keywordResults.results.forEach((score, noteId) => {
    trace_data.keyword_candidates.push({
      note_id: noteId,
      keyword_score: score,
    });
  });

  // Transform and combine results
  const MIN_VECTOR_SIMILARITY = 0.15;
  let allChunks: Array<Record<string, any>> = vectorResults.matches
    .filter((match) => match.score >= MIN_VECTOR_SIMILARITY)
    .map((match) => {
      const noteId = String(match.metadata?.note_id || "");
      const keywordScore = keywordResults.results.get(noteId) || 0;
      const combinedScore = keywordScore > 0
        ? (match.score * 0.7) + (keywordScore * 0.3)
        : match.score;
      return {
        chunk_id: match.id,
        similarity: match.score,
        combined_score: combinedScore,
        keyword_score: keywordScore,
        ...match.metadata,
      };
    });

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
  }));

  // STEP 3: Rerank if enabled
  const MIN_RERANK_SCORE = 0.5;
  if (params.rerank && matches.length > 0) {
    const documents = matches.map(m =>
      String(m.content || m.title || "")
    ).filter(d => d.length > 0);

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
        }));

        // Reorder and filter by threshold
        const rerankedMatches = reranked
          .filter(r => r.score >= MIN_RERANK_SCORE)
          .map(r => ({
            ...matches[r.index],
            rerank_score: r.score,
            original_similarity: matches[r.index].similarity,
            similarity: r.score,
          }));

        matches = rerankedMatches;
      } catch (rerankError) {
        console.error("Rerank failed:", rerankError);
        // On rerank failure, keep results filtered by vector threshold only
      }
    }
  }
  // No artificial limit - threshold filtering already applied

  return {
    matches,
    timing,
    embedding_cached: cached,
    trace_data,
  };
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
    
    // Health check (no auth required)
    if (path === "/health" || path === "/") {
      return handleHealth(env);
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
    if (path === "/api/v1/auth/me") {
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleAuthMe(authResult, env as ApiEnv);
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
    
    // GET /api/v1/notes/:id/view-token
    const viewTokenMatch = path.match(/^\/api\/v1\/notes\/([a-f0-9-]+)\/view-token$/);
    if (viewTokenMatch && request.method === "GET") {
      const authResult = await validateAuth(request, env as AuthEnv);
      return handleGetViewToken(viewTokenMatch[1], authResult, env as ApiEnv);
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
    
    // Debug: Test TensorLake directly
    if (path === "/api/v1/upload/test-tensorlake") {
      return handleTestTensorLake(request, env as unknown as UploadEnv);
    }
    
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
      console.log(`📄 Note view request: path="${path}"`);
      if (request.method !== "GET") {
        return new Response("Method not allowed", { status: 405, headers: corsHeaders });
      }
      const noteId = noteViewMatch[2]; // Group 2 is the note ID now
      const token = url.searchParams.get('token');
      console.log(`📄 Note view: noteId=${noteId.slice(0,8)}..., hasToken=${!!token}`);
      return handleNoteView(noteId, token, env);
    }
    
    // Also check for /view/ path (some links might have trailing content)
    if (path.startsWith('/notes/') && path.includes('/view')) {
      console.log(`📄 Unmatched notes/view path: path="${path}"`);
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
      const body = await request.json() as { query?: string; user_id?: string; max_results?: number; debug?: boolean; client_source?: string };
      
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
          // Pass auth timing data to handleRagSearch
          _auth_timing: {
            auth_started_at: authStartedAt,
            auth_completed_at: authCompletedAt,
            timing_auth_ms: authDurationMs,
            auth_method: authResult.auth_method,
            auth_user_email: authResult.user_email,
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
        
      case "/hybrid":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleHybridSearch(request, env, ctx, requestId);
        
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
            endpoints: ["/health", "/rag-search", "/hybrid", "/search", "/rerank", "/embed", "/embed-batch", "/upsert", "/delete", "/cache/invalidate", "/api/v1/upload/file", "/api/v1/upload/screenshot", "/api/v1/upload/quick-note", "/api/v1/upload/status/:id", "/api/v1/upload/quota"],
          }),
          { status: 404, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
    }
  },
};
