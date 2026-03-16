/**
 * RAG Search Module - Full RAG pipeline in Cloudflare Worker
 * 
 * Ported from Fly.io Python backend with minimal changes.
 * Uses Groq for LLM calls, reuses existing hybrid search infrastructure.
 */

// ============================================================================
// TYPES
// ============================================================================

export interface RagSearchEnv {
  VECTORIZE: Vectorize;
  AI: Ai;
  WORKER_API_KEY: string;
  VOYAGE_API_KEY: string;
  GROQ_API_KEY: string;
  EMBEDDING_MODEL: string;
  EMBEDDING_CACHE: KVNamespace;
  SEARCH_CACHE: KVNamespace;
  TAGS_CACHE: KVNamespace;
  SYNTHESIS_CACHE: KVNamespace;
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  SUPABASE_JWT_SECRET: string;  // For generating view tokens
  BACKEND_URL?: string;  // DEPRECATED: No longer used, logs go to Supabase directly
  LOG_ENABLED?: string;
}

// Search trace entry for detailed logging
interface RagSearchTraceEntry {
  correlation_id: string;
  user_id: string;
  query: string;
  query_corrected?: string;
  
  // Timestamps for each phase (ISO format)
  request_received_at?: string;
  auth_started_at?: string;
  auth_completed_at?: string;
  spell_check_started_at?: string;
  tags_fetch_started_at?: string;
  embedding_started_at?: string;
  search_started_at?: string;
  rerank_started_at?: string;
  relevance_check_started_at?: string;
  synthesis_started_at?: string;
  response_sent_at?: string;
  
  // Complete timing breakdown
  timing_total_ms?: number;
  timing_auth_ms?: number;
  timing_spell_check_ms?: number;
  timing_tags_fetch_ms?: number;
  timing_embedding_ms?: number;
  timing_vector_search_ms?: number;
  timing_keyword_search_ms?: number;
  timing_rerank_ms?: number;
  timing_relevance_check_ms?: number;
  timing_synthesis_ms?: number;
  timing_worker_ms?: number;
  
  // Auth details
  auth_method?: string;
  auth_user_email?: string;
  
  // Cache status
  embedding_cached: boolean;
  search_cached: boolean;
  tags_cached?: boolean;
  synthesis_cached?: boolean;
  // Chunk grouping info (top 3 per doc)
  chunks_before_grouping?: number;
  chunks_after_grouping?: number;
  unique_documents?: number;
  chunks_per_doc_limit?: number;
  // Dedup after LLM verification
  dedup_before_count?: number;
  dedup_after_count?: number;
  dedup_removed?: number;
  // Candidates at each stage
  vector_candidates?: Array<Record<string, any>>;
  keyword_candidates?: Array<Record<string, any>>;
  combined_candidates?: Array<Record<string, any>>;
  reranked_candidates?: Array<Record<string, any>>;
  relevance_verified_candidates?: Array<Record<string, any>>;
  final_results?: Array<Record<string, any>>;
  // Counts
  vector_count?: number;
  keyword_count?: number;
  combined_count?: number;
  reranked_count?: number;
  relevance_verified_count?: number;
  final_count?: number;
  // Thresholds
  min_vector_threshold?: number;
  min_rerank_threshold?: number;
  // Source info
  source_worker?: string;
  request_path?: string;
  client_source?: string;  // 'google-search', 'dashboard', 'extension', etc.
  
  // === AGENTIC RAG FIELDS ===
  // Intent classification (LLM Router)
  intent_classification?: string;
  intent_confidence?: string;
  intent_reasoning?: string;
  timing_intent_router_ms?: number;
  // Tool/handler invoked
  tool_invoked?: string;
  // Collection metadata (for COLLECTION_SUMMARY and EXPLORATORY)
  timing_collection_fetch_ms?: number;
  collection_doc_count?: number;
  // Path taken
  path_taken?: string;
  // Error tracking
  error_occurred?: boolean;
  error_message?: string;
  error_type?: string;
  // LLM calls log
  llm_calls?: Array<{ model: string; purpose: string; duration_ms: number }>;
  // Answer info
  answer_generated?: boolean;
  answer_preview?: string;
}

export interface RagSearchRequest {
  query: string;
  user_id: string;
  max_results?: number;
  debug?: boolean;
  client_source?: string;  // 'google-search', 'dashboard', 'extension', etc.
}

export interface RagSearchResponse {
  success: boolean;
  results: SearchResult[];
  answer?: string;
  path_taken: 'tag' | 'hybrid' | 'collection_summary' | 'exploratory' | 'tag_browse';
  metadata: RagSearchMetadata;
  request_id: string;
  worker_request_id?: string;  // Alias for Chrome extension compatibility
}

interface SearchResult {
  note_id: string;
  title: string;
  chunk_content: string;  // Full chunk content (same as passed to reranker)
  tag?: string;
  similarity_score: number;
  rerank_score?: number;
  source: string;
  blob_url?: string;
  view_url?: string;  // Signed URL for viewing the document
  file_type?: string; // Type of document: uploaded_file, screenshot, quick_note, etc.
}

interface RagSearchMetadata {
  timing: TimingBreakdown;
  spell_check: SpellCheckResult;
  tags: TagsResult;
  analysis?: QueryAnalysis;
  cache_hits: CacheHits;
  llm_calls: LLMCall[];
}

interface TimingBreakdown {
  total_ms: number;
  spell_check_ms: number;
  tags_fetch_ms: number;
  intent_router_ms?: number;
  analysis_ms?: number;
  tag_intent_ms?: number;
  embedding_ms: number;
  vector_search_ms: number;
  keyword_search_ms: number;
  rerank_ms: number;
  relevance_check_ms?: number;
  synthesis_ms?: number;
}

interface SpellCheckResult {
  original: string;
  corrected: string;
  was_corrected: boolean;
  explanation: string;
}

// ============================================================================
// VIEW TOKEN GENERATION (same algorithm as Python backend)
// ============================================================================

/**
 * Generate a signed view token for document viewing.
 * Token format: {note_id}:{user_id}:{expiry_timestamp}:{signature}
 * Matches Python backend's generate_view_token() function exactly.
 */
async function generateViewToken(
  noteId: string, 
  userId: string, 
  env: RagSearchEnv, 
  expiryMinutes: number = 1440  // 24 hours default
): Promise<string> {
  const expiryTs = Math.floor(Date.now() / 1000) + (expiryMinutes * 60);
  const message = `${noteId}:${userId}:${expiryTs}`;
  
  // IMPORTANT: Use SUPABASE_SERVICE_KEY because Fly.io backend doesn't have SUPABASE_JWT_SECRET set
  // so it falls back to service key. We must use the same secret for signature to match.
  const secret = env.SUPABASE_SERVICE_KEY;
  
  // HMAC-SHA256 signature (same as Python)
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  
  const signatureBuffer = await crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(message)
  );
  
  // Convert to hex and take first 16 chars (same as Python)
  const signatureArray = new Uint8Array(signatureBuffer);
  const signatureHex = Array.from(signatureArray)
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
    .slice(0, 16);
  
  return `${message}:${signatureHex}`;
}

/**
 * Build the full view URL with token
 */
function buildViewUrl(noteId: string, token: string, env: RagSearchEnv): string {
  // Use the Worker URL directly (no Fly.io dependency)
  const workerUrl = 'https://notesapp-vector-search.monocle0712.workers.dev';
  return `${workerUrl}/notes/${noteId}/view?token=${token}`;
}

/**
 * Filter search results to only include active notes
 * This removes results for notes that failed during upload pipeline
 */
async function filterActiveNotes<T extends { note_id: string }>(
  results: T[],
  env: RagSearchEnv
): Promise<{ results: T[]; filteredCount: number }> {
  if (results.length === 0) {
    return { results, filteredCount: 0 };
  }

  // Get unique note IDs
  const noteIds = [...new Set(results.map(r => r.note_id))];
  
  try {
    // Batch query to check which notes are active
    const url = new URL(`${env.SUPABASE_URL}/rest/v1/notes`);
    url.searchParams.set('select', 'id');
    url.searchParams.set('id', `in.(${noteIds.join(',')})`);
    url.searchParams.set('status', 'eq.active');

    const response = await fetch(url.toString(), {
      method: 'GET',
      headers: {
        'Content-Type': 'application/json',
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });

    if (!response.ok) {
      console.error('Failed to filter active notes:', response.status);
      return { results, filteredCount: 0 }; // Return all on error
    }

    const activeNotes = await response.json() as Array<{ id: string }>;
    const activeIds = new Set(activeNotes.map(n => n.id));

    // Filter results to only include active notes
    const filteredResults = results.filter(r => activeIds.has(r.note_id));
    const filteredCount = results.length - filteredResults.length;

    if (filteredCount > 0) {
      console.log(`[filterActiveNotes] Filtered out ${filteredCount} incomplete notes from ${results.length} results`);
    }

    return { results: filteredResults, filteredCount };
  } catch (e) {
    console.error('Error filtering active notes:', e);
    return { results, filteredCount: 0 }; // Return all on error
  }
}

interface TagsResult {
  available: string[];
  detected: string[];
  intent?: 'LIST_ALL' | 'SPECIFIC';
}

interface QueryAnalysis {
  intent: string;
  complexity: string;
  needs_synthesis: boolean;
  temporal_sort: string;
  limit_to_one: boolean;
  keywords: string[];
}

interface CacheHits {
  embedding: boolean;
  tags: boolean;
  synthesis: boolean;
}

interface LLMCall {
  model: string;
  purpose: string;
  duration_ms: number;
}

// ============================================================================
// CONSTANTS (ported from Python)
// ============================================================================

const GROQ_FAST_MODEL = "llama-3.1-8b-instant";
const GROQ_SYNTHESIS_MODEL = "llama-3.3-70b-versatile";

// Cache TTLs
const TAGS_CACHE_TTL = 1800; // 30 minutes - tags rarely change
const SYNTHESIS_CACHE_TTL = 600; // 10 minutes

// Tag detection stop words (from rag_agent.py)
const TAG_INTENT_STOP_WORDS = new Set([
  'show', 'me', 'my', 'find', 'get', 'all', 'the', 'list', 'fetch',
  'display', 'give', 'search', 'for', 'in', 'from', 'with', 'about',
  'what', 'is', 'are', 'documents', 'docs', 'files', 'notes', 'items',
  'please', 'can', 'you', 'i', 'want', 'need', 'to', 'see', 'look',
  'at', 'related', 'regarding', 'concerning', 'of', 'a', 'an'
]);

// Query intent keywords (from query_analyzer.py)
const ANSWER_KEYWORDS = new Set([
  'what', 'why', 'how', 'explain', 'describe', 'summarize',
  'compare', 'difference', 'between', 'analyze', 'tell me',
  'can you', 'could you', 'please'
]);

const LIST_KEYWORDS = new Set([
  'find', 'get', 'show', 'list', 'search', 'retrieve',
  'fetch', 'display', 'give me', 'all', 'documents', 'files', 'notes'
]);

// Temporal indicators
const NEWEST_INDICATORS = [
  'latest', 'newest', 'most recent', 'last', 'recent',
  'current', 'updated', 'new'
];

const OLDEST_INDICATORS = [
  'oldest', 'earliest', 'first', 'original', 'initial'
];

// Rerank thresholds (must match index.ts)
const MIN_VECTOR_SIMILARITY = 0.35;
const MIN_RERANK_SCORE = 0.30;

// ============================================================================
// SEARCH TRACE HELPER - Logs directly to Supabase (no Fly.io dependency)
// ============================================================================

async function sendRagSearchTrace(
  trace: RagSearchTraceEntry,
  env: RagSearchEnv,
  ctx: ExecutionContext
): Promise<void> {
  // Skip if logging disabled or no Supabase config
  if (env.LOG_ENABLED !== "true" || !env.SUPABASE_URL || !env.SUPABASE_SERVICE_KEY) {
    return;
  }

  // Use waitUntil so logging doesn't delay the response
  ctx.waitUntil(
    (async () => {
      try {
        // Insert into search_traces table (detailed trace data including candidate arrays)
        const traceResponse = await fetch(`${env.SUPABASE_URL}/rest/v1/search_traces`, {
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
            spell_check_started_at: trace.spell_check_started_at,
            tags_fetch_started_at: trace.tags_fetch_started_at,
            embedding_started_at: trace.embedding_started_at,
            search_started_at: trace.search_started_at,
            rerank_started_at: trace.rerank_started_at,
            relevance_check_started_at: trace.relevance_check_started_at,
            synthesis_started_at: trace.synthesis_started_at,
            response_sent_at: trace.response_sent_at,
            // Timing durations
            timing_total_ms: trace.timing_total_ms,
            timing_auth_ms: trace.timing_auth_ms,
            timing_spell_check_ms: trace.timing_spell_check_ms,
            timing_tags_fetch_ms: trace.timing_tags_fetch_ms,
            timing_embedding_ms: trace.timing_embedding_ms,
            timing_vector_search_ms: trace.timing_vector_search_ms,
            timing_keyword_search_ms: trace.timing_keyword_search_ms,
            timing_rerank_ms: trace.timing_rerank_ms,
            timing_relevance_check_ms: trace.timing_relevance_check_ms,
            timing_synthesis_ms: trace.timing_synthesis_ms,
            timing_worker_ms: trace.timing_worker_ms,
            // Auth details
            auth_method: trace.auth_method,
            auth_user_email: trace.auth_user_email,
            // Cache status
            embedding_cached: trace.embedding_cached,
            tags_cached: trace.tags_cached,
            synthesis_cached: trace.synthesis_cached,
            vector_count: trace.vector_count,
            keyword_count: trace.keyword_count,
            combined_count: trace.combined_count,
            reranked_count: trace.reranked_count,
            relevance_verified_count: trace.relevance_verified_count,
            final_count: trace.final_count,
            // Chunk grouping info
            chunks_before_grouping: trace.chunks_before_grouping,
            chunks_after_grouping: trace.chunks_after_grouping,
            unique_documents: trace.unique_documents,
            chunks_per_doc_limit: trace.chunks_per_doc_limit,
            // Dedup info
            dedup_before_count: trace.dedup_before_count,
            dedup_after_count: trace.dedup_after_count,
            dedup_removed: trace.dedup_removed,
            // Candidate arrays (the detailed pipeline data)
            vector_candidates: trace.vector_candidates || [],
            keyword_candidates: trace.keyword_candidates || [],
            combined_candidates: trace.combined_candidates || [],
            reranked_candidates: trace.reranked_candidates || [],
            relevance_verified_candidates: trace.relevance_verified_candidates || [],
            final_results: trace.final_results || [],
            // Thresholds
            min_vector_threshold: trace.min_vector_threshold,
            min_rerank_threshold: trace.min_rerank_threshold,
            source_worker: trace.source_worker || "cloudflare-worker",
            request_path: trace.request_path,
            client_source: trace.client_source || "unknown",
            // Agentic RAG fields
            intent_classification: trace.intent_classification,
            intent_confidence: trace.intent_confidence,
            intent_reasoning: trace.intent_reasoning,
            timing_intent_router_ms: trace.timing_intent_router_ms,
            tool_invoked: trace.tool_invoked,
            timing_collection_fetch_ms: trace.timing_collection_fetch_ms,
            collection_doc_count: trace.collection_doc_count,
            path_taken: trace.path_taken,
            error_occurred: trace.error_occurred || false,
            error_message: trace.error_message,
            error_type: trace.error_type,
            llm_calls: trace.llm_calls || [],
            answer_generated: trace.answer_generated || false,
            answer_preview: trace.answer_preview,
          }),
        });
        if (!traceResponse.ok) {
          console.error("Failed to log to search_traces:", traceResponse.status, await traceResponse.text());
        }

        // Also insert into user_activities table so it shows on activity-logs page
        // Note: user_activities.correlation_id is UUID type, so we generate a new one
        // and store the worker correlation_id in metadata for cross-reference
        const activityResponse = await fetch(`${env.SUPABASE_URL}/rest/v1/user_activities`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "apikey": env.SUPABASE_SERVICE_KEY,
            "Authorization": `Bearer ${env.SUPABASE_SERVICE_KEY}`,
            "Prefer": "return=minimal",
          },
          body: JSON.stringify({
            correlation_id: crypto.randomUUID(),
            user_id: trace.user_id,
            action: "chat_search",
            resource_type: "search",
            status: trace.error_occurred ? "error" : "success",
            duration_ms: trace.timing_total_ms || 0,
            metadata: {
              query: trace.query,
              query_corrected: trace.query_corrected,
              results_count: trace.final_count || 0,
              vector_count: trace.vector_count,
              keyword_count: trace.keyword_count,
              embedding_cached: trace.embedding_cached,
              synthesis_cached: trace.synthesis_cached,
              client_source: trace.client_source || "unknown",
              worker_request_id: trace.correlation_id, // Link to search_traces - frontend expects this key
              // Agentic RAG metadata
              intent: trace.intent_classification,
              intent_confidence: trace.intent_confidence,
              tool_invoked: trace.tool_invoked,
              path_taken: trace.path_taken,
              answer_generated: trace.answer_generated,
              error_occurred: trace.error_occurred,
              error_message: trace.error_message,
              error_type: trace.error_type,
              llm_calls_count: trace.llm_calls?.length || 0,
            },
          }),
        });
        if (!activityResponse.ok) {
          console.error("Failed to log to user_activities:", activityResponse.status, await activityResponse.text());
        }
      } catch (err) {
        console.error("Failed to send search trace to Supabase:", err);
      }
    })()
  );
}

// ============================================================================
// GROQ API HELPERS
// ============================================================================

interface GroqMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

interface GroqResponse {
  choices: Array<{
    message: {
      content: string;
    };
  }>;
}

async function callGroq(
  messages: GroqMessage[],
  env: RagSearchEnv,
  model: string = GROQ_FAST_MODEL,
  temperature: number = 0.1,
  maxTokens: number = 200
): Promise<string> {
  const response = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${env.GROQ_API_KEY}`,
    },
    body: JSON.stringify({
      model,
      messages,
      temperature,
      max_tokens: maxTokens,
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Groq API error: ${response.status} - ${error}`);
  }

  const data: GroqResponse = await response.json();
  return data.choices[0]?.message?.content?.trim() || "";
}

// ============================================================================
// SPELL CHECK (ported from rag_agent.py _spell_check_query)
// ============================================================================

async function spellCheck(
  query: string,
  env: RagSearchEnv
): Promise<{ corrected: string; wasChanged: boolean; explanation: string; durationMs: number }> {
  const start = Date.now();

  const prompt = `You are a spell checker. Your ONLY job is to fix typos and spelling errors in the query.

RULES:
1. ONLY fix obvious spelling mistakes and typos
2. DO NOT change the meaning or intent of the query
3. DO NOT add or remove words
4. DO NOT change proper nouns, names, or technical terms unless they are clearly misspelled
5. Preserve the original case pattern when possible
6. If the query has no spelling errors, return it EXACTLY as-is

Examples:
- "shwo my latset pan crad" → "show my latest pan card" (typo fixes)
- "waht is my PAN numbr" → "what is my PAN number" (typo fix)
- "documetns about AI" → "documents about AI" (typo fix)
- "show my resume" → "show my resume" (no change needed)
- "find centric consulting" → "find centric consulting" (no change - proper noun)

Query to check: "${query}"

Respond in this EXACT format:
CORRECTED: <the corrected query or original if no errors>
CHANGED: <YES or NO>
EXPLANATION: <brief description of changes or "No corrections needed">`;

  try {
    const response = await callGroq(
      [{ role: "user", content: prompt }],
      env,
      GROQ_FAST_MODEL,
      0.1,
      200
    );

    // Parse response
    let corrected = query;
    let wasChanged = false;
    let explanation = "No corrections needed";

    for (const line of response.split("\n")) {
      const trimmed = line.trim();
      if (trimmed.startsWith("CORRECTED:")) {
        corrected = trimmed.slice(10).trim();
        // Remove quotes if present
        if ((corrected.startsWith('"') && corrected.endsWith('"')) ||
            (corrected.startsWith("'") && corrected.endsWith("'"))) {
          corrected = corrected.slice(1, -1);
        }
      } else if (trimmed.startsWith("CHANGED:")) {
        wasChanged = trimmed.toUpperCase().includes("YES");
      } else if (trimmed.startsWith("EXPLANATION:")) {
        explanation = trimmed.slice(12).trim();
      }
    }

    return {
      corrected,
      wasChanged,
      explanation,
      durationMs: Date.now() - start,
    };
  } catch (e) {
    console.error("Spell check failed:", e);
    return {
      corrected: query,
      wasChanged: false,
      explanation: `Spell check failed: ${String(e).slice(0, 50)}`,
      error: e instanceof Error ? e.message : String(e),
      durationMs: Date.now() - start,
    };
  }
}

// ============================================================================
// TAGS FETCH WITH CACHE
// ============================================================================

async function fetchUserTags(
  userId: string,
  env: RagSearchEnv
): Promise<{ tags: string[]; cached: boolean; durationMs: number }> {
  const start = Date.now();
  const cacheKey = `tags_${userId}`;

  // Check KV cache
  try {
    const cached = await env.TAGS_CACHE.get(cacheKey, "json") as string[] | null;
    if (cached) {
      console.log(`Tags cache HIT for user ${userId.slice(0, 8)}`);
      return { tags: cached, cached: true, durationMs: Date.now() - start };
    }
  } catch (e) {
    console.error("Tags cache read error:", e);
  }

  // Fetch from Supabase
  try {
    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/rpc/get_tags_with_counts`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "apikey": env.SUPABASE_SERVICE_KEY,
          "Authorization": `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
        body: JSON.stringify({ filter_user_id: userId }),
      }
    );

    if (!response.ok) {
      throw new Error(`Supabase error: ${response.status}`);
    }

    const data = await response.json() as Array<{ tag: string; count: number }>;
    const tags = data.map(t => t.tag);

    // Cache the result
    try {
      await env.TAGS_CACHE.put(cacheKey, JSON.stringify(tags), { expirationTtl: TAGS_CACHE_TTL });
    } catch (e) {
      console.error("Tags cache write error:", e);
    }

    return { tags, cached: false, durationMs: Date.now() - start };
  } catch (e) {
    console.error("Tags fetch error:", e);
    return { tags: [], cached: false, durationMs: Date.now() - start, error: e instanceof Error ? e.message : String(e) };
  }
}

// ============================================================================
// TAG DETECTION (ported from query_analyzer.py _detect_tags)
// ============================================================================

function detectTagInQuery(query: string, availableTags: string[]): string | null {
  const queryLower = query.toLowerCase();

  for (const tag of availableTags) {
    const tagLower = tag.toLowerCase();
    // Exact word boundary match
    const pattern = new RegExp(`\\b${escapeRegExp(tagLower)}\\b`, 'i');
    if (pattern.test(queryLower)) {
      console.log(`Tag detected: "${tag}" in query`);
      return tag;
    }
  }

  return null;
}

function escapeRegExp(string: string): string {
  return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// ============================================================================
// TAG INTENT CLASSIFICATION (ported from rag_agent.py _classify_tag_intent)
// ============================================================================

function extractKeywordsBeyondTag(query: string, tag: string): string[] {
  let queryLower = query.toLowerCase();
  const tagLower = tag.toLowerCase();

  // Remove tag from query
  queryLower = queryLower.replace(new RegExp(`\\b${escapeRegExp(tagLower)}\\b`, 'gi'), '');
  queryLower = queryLower.replace(/\s+/g, ' ').trim();

  // Extract words and filter stop words
  const words = queryLower.match(/\b\w+\b/g) || [];
  return words.filter(w => !TAG_INTENT_STOP_WORDS.has(w) && w.length > 1);
}

async function classifyTagIntent(
  query: string,
  tag: string,
  remainingKeywords: string[],
  env: RagSearchEnv
): Promise<{ intent: 'LIST_ALL' | 'SPECIFIC'; durationMs: number }> {
  const start = Date.now();

  // Fast path: no meaningful keywords = LIST_ALL
  if (remainingKeywords.length === 0) {
    console.log("Tag intent: LIST_ALL (no keywords beyond tag)");
    return { intent: 'LIST_ALL', durationMs: Date.now() - start };
  }

  const prompt = `Classify this query intent. The user's query contains a document category/tag "${tag}".

Query: "${query}"
Keywords beyond the tag: ${remainingKeywords.join(', ')}

Question: Does the user want to:
A) LIST_ALL: See all documents in the "${tag}" category
B) SPECIFIC: Find specific information/document within that category

Examples:
- "show me personal docs" → LIST_ALL (just wants to see the category)
- "pan card from personal docs" → SPECIFIC (wants specific document)
- "redis documents" → LIST_ALL (just wants redis category)
- "redis pricing details" → SPECIFIC (wants specific info about pricing)

Answer with just: LIST_ALL or SPECIFIC`;

  try {
    const response = await callGroq(
      [{ role: "user", content: prompt }],
      env,
      GROQ_FAST_MODEL,
      0,
      20
    );

    const intent = response.toUpperCase().includes("LIST_ALL") ? 'LIST_ALL' : 'SPECIFIC';
    console.log(`Tag intent: ${intent} (LLM classified)`);
    return { intent, durationMs: Date.now() - start };
  } catch (e) {
    console.error("Tag intent classification failed:", e);
    return { intent: 'SPECIFIC', durationMs: Date.now() - start, error: e instanceof Error ? e.message : String(e) };
  }
}

// ============================================================================
// QUERY ANALYSIS (ported from query_analyzer.py)
// ============================================================================

function analyzeQueryLocal(query: string, availableTags: string[]): QueryAnalysis {
  const queryLower = query.toLowerCase();

  // Detect intent
  let intent = 'retrieve';
  if (queryLower.endsWith('?') || Array.from(ANSWER_KEYWORDS).some(kw => queryLower.includes(kw))) {
    intent = 'answer';
  } else if (Array.from(LIST_KEYWORDS).some(kw => queryLower.includes(kw))) {
    intent = 'list';
  }

  // Detect complexity
  const words = queryLower.split(/\s+/);
  let complexity = 'moderate';
  if (words.length <= 5) complexity = 'simple';
  else if (words.length >= 15) complexity = 'complex';

  // Needs synthesis
  const needsSynthesis = intent === 'answer' || queryLower.endsWith('?');

  // Temporal detection
  let temporalSort = 'none';
  for (const ind of NEWEST_INDICATORS) {
    if (queryLower.includes(ind)) {
      temporalSort = 'newest';
      break;
    }
  }
  if (temporalSort === 'none') {
    for (const ind of OLDEST_INDICATORS) {
      if (queryLower.includes(ind)) {
        temporalSort = 'oldest';
        break;
      }
    }
  }

  // Limit to one detection
  const singularPatterns = [
    /\b(the|my)\s+(latest|newest|most recent|oldest|earliest|first)\b/,
    /\bget\s+(me\s+)?(my\s+)?(latest|newest|most recent)\b/,
  ];
  const limitToOne = singularPatterns.some(p => p.test(queryLower));

  // Extract keywords
  const stopWords = new Set([
    'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would',
    'could', 'should', 'may', 'might', 'must', 'to', 'of', 'in',
    'for', 'on', 'with', 'at', 'by', 'from', 'i', 'me', 'my',
    'we', 'our', 'you', 'your', 'it', 'its', 'they', 'them',
    'what', 'which', 'who', 'this', 'that', 'and', 'but', 'if',
    'or', 'all', 'any', 'some', 'no', 'not', 'only', 'just',
    'find', 'get', 'show', 'tell', 'give', 'please', 'help'
  ]);
  const keywords = words.filter(w => !stopWords.has(w) && w.length > 2).slice(0, 10);

  return {
    intent,
    complexity,
    needs_synthesis: needsSynthesis,
    temporal_sort: temporalSort,
    limit_to_one: limitToOne,
    keywords,
  };
}

// ============================================================================
// LLM INTENT ROUTER (replaces analyzeQueryLocal for agentic routing)
// ============================================================================

type QueryIntent = 'CONTENT_SEARCH' | 'TAG_BROWSE' | 'COLLECTION_SUMMARY' | 'EXPLORATORY' | 'DATE_QUERY' | 'MULTI_STEP';

interface IntentClassification {
  intent: QueryIntent;
  confidence: string;
  reasoning: string;
  durationMs: number;
}

async function classifyQueryIntent(
  query: string,
  availableTags: string[],
  env: RagSearchEnv
): Promise<IntentClassification> {
  const start = Date.now();

  const prompt = `You are a search intent classifier for a personal notes/document management app. Classify the user's query into exactly ONE of these categories:

1. CONTENT_SEARCH - User wants to find specific information or a specific document. They know roughly what they're looking for.
   Examples: "show me my resume", "what is my PAN number", "find the redis pricing doc", "AWS deployment notes"

2. TAG_BROWSE - User explicitly mentions the word "tag" and wants to browse documents under a specific tag/category.
   IMPORTANT: ONLY classify as TAG_BROWSE if the user uses the word "tag" in their query.
   Examples: "show me all documents under tag resume", "list notes with tag personal", "what's in my finance tag"
   NOT TAG_BROWSE: "show me all my resumes" (no word "tag" used)

3. COLLECTION_SUMMARY - User wants an overview, summary, or count of their entire collection or a broad category.
   Examples: "summarize my notes", "how many documents do I have", "what topics do I have notes on", "give me an overview of my saved items"

4. EXPLORATORY - User is unsure or wants to discover what they have. Vague, open-ended queries.
   Examples: "do I have anything about AI?", "what do I have related to cooking?", "is there something about taxes?"

5. DATE_QUERY - User wants to find documents by date, time period, or recency (e.g., "saved last week", "notes from January").
   Examples: "what did I save yesterday", "notes from last month", "documents saved in 2024"

6. MULTI_STEP - User wants complex operations like comparing, merging, or cross-referencing multiple documents.
   Examples: "compare my 2023 and 2024 tax returns", "merge my two resume versions"

User's available tags: [${availableTags.slice(0, 20).join(', ')}]

User Query: "${query}"

Respond in this EXACT format (3 lines only):
INTENT: <one of the 6 categories>
CONFIDENCE: <HIGH or MEDIUM or LOW>
REASONING: <one sentence explanation>`;

  try {
    const response = await callGroq(
      [
        { role: "system", content: "You are a precise query classifier. Return exactly 3 lines: INTENT, CONFIDENCE, REASONING. Nothing else." },
        { role: "user", content: prompt }
      ],
      env,
      GROQ_FAST_MODEL,
      0,
      100
    );

    let intent: QueryIntent = 'CONTENT_SEARCH';
    let confidence = 'MEDIUM';
    let reasoning = '';

    for (const line of response.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.startsWith('INTENT:')) {
        const parsed = trimmed.slice(7).trim().toUpperCase();
        if (['CONTENT_SEARCH', 'TAG_BROWSE', 'COLLECTION_SUMMARY', 'EXPLORATORY', 'DATE_QUERY', 'MULTI_STEP'].includes(parsed)) {
          intent = parsed as QueryIntent;
        }
      } else if (trimmed.startsWith('CONFIDENCE:')) {
        confidence = trimmed.slice(11).trim();
      } else if (trimmed.startsWith('REASONING:')) {
        reasoning = trimmed.slice(10).trim();
      }
    }

    // Safety check: TAG_BROWSE requires the word "tag" in query
    if (intent === 'TAG_BROWSE' && !query.toLowerCase().includes('tag')) {
      console.log(`[Intent Router] Overriding TAG_BROWSE → CONTENT_SEARCH (no 'tag' keyword in query)`);
      intent = 'CONTENT_SEARCH';
      reasoning = 'Overridden: user did not use word "tag" explicitly';
    }

    console.log(`[Intent Router] ${intent} (${confidence}): ${reasoning}`);
    return { intent, confidence, reasoning, durationMs: Date.now() - start };
  } catch (e) {
    const errMsg = e instanceof Error ? e.message : String(e);
    console.error('Intent classification failed, falling back to CONTENT_SEARCH:', errMsg);
    return { intent: 'CONTENT_SEARCH', confidence: 'LOW', reasoning: `Fallback due to error: ${errMsg.slice(0, 150)}`, durationMs: Date.now() - start };
  }
}

// ============================================================================
// COLLECTION SUMMARY HANDLER (fetches all doc metadata for LLM analysis)
// ============================================================================

interface CollectionDoc {
  id: string;
  title: string;
  tag: string;
  created_at: string;
  blob_url?: string;
  file_type?: string;
}

async function fetchCollectionMetadata(
  userId: string,
  env: RagSearchEnv
): Promise<{ docs: CollectionDoc[]; durationMs: number }> {
  const start = Date.now();

  try {
    const url = new URL(`${env.SUPABASE_URL}/rest/v1/notes`);
    url.searchParams.set('select', 'id,title,tag,created_at,blob_url,file_type');
    url.searchParams.set('user_id', `eq.${userId}`);
    url.searchParams.set('status', 'eq.active');  // Only fetch active notes
    url.searchParams.set('order', 'created_at.desc');
    url.searchParams.set('limit', '500'); // cap to avoid huge payloads

    const response = await fetch(url.toString(), {
      method: 'GET',
      headers: {
        'Content-Type': 'application/json',
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });

    if (!response.ok) {
      throw new Error(`Supabase error: ${response.status}`);
    }

    const data = await response.json() as CollectionDoc[];
    return { docs: data, durationMs: Date.now() - start };
  } catch (e) {
    console.error('Collection metadata fetch error:', e);
    return { docs: [], durationMs: Date.now() - start, error: e instanceof Error ? e.message : String(e) };
  }
}

async function handleCollectionSummary(
  query: string,
  userId: string,
  env: RagSearchEnv,
  ctx: ExecutionContext
): Promise<{ answer: string; results: SearchResult[]; durationMs: number }> {
  const start = Date.now();

  const { docs, durationMs: fetchMs } = await fetchCollectionMetadata(userId, env);

  if (docs.length === 0) {
    return {
      answer: "Looks like your collection is empty right now — but that's exciting because you're just getting started! 🚀 Save some articles, notes, or documents using the Chrome extension or dashboard, and I'll be ready to help you explore and discover insights from your personal knowledge base. ✨",
      results: [],
      durationMs: Date.now() - start,
    };
  }

  // Build a concise list for LLM
  const docList = docs.map((d, i) =>
    `${i + 1}. "${d.title || 'Untitled'}" | Tag: ${d.tag || 'none'} | Saved: ${new Date(d.created_at).toLocaleDateString()}`
  ).join('\n');

  const prompt = `You are a friendly, enthusiastic assistant for a personal notes & document management app called infoSnap. The user asked: "${query}"

Here is the complete list of their saved documents (${docs.length} total):

${docList}

INSTRUCTIONS:
1. Answer the user's question based on this document list.
2. If they asked for a summary/overview, organize by tags and give counts.
3. If they asked how many documents, count them accurately.
4. If they asked about topics, list the unique tags with document counts.
5. Be specific — mention actual document titles when relevant.
6. Use a warm, conversational tone — like a helpful friend who's excited to help them explore their collection.
7. Use emojis sparingly but naturally (e.g. 📂 for categories, ✨ for highlights).
8. Format with markdown: use **bold** for emphasis, bullet points for lists, and clear headings if needed.
9. End with something encouraging — like a follow-up suggestion or a fun observation about their collection.

ANSWER:`;

  try {
    const answer = await callGroq(
      [
        { role: 'system', content: 'You are a friendly, warm document assistant for a personal notes app called infoSnap. Provide well-organized, encouraging answers about the user\'s collection. Use a conversational tone, format nicely with markdown, and sprinkle in relevant emojis. Make the user feel good about their collection!' },
        { role: 'user', content: prompt }
      ],
      env,
      GROQ_SYNTHESIS_MODEL,
      0.2,
      1500
    );

    // Collection summary is answer-only — no document links (they'd be random/unhelpful)
    return { answer, results: [], durationMs: Date.now() - start };
  } catch (e) {
    console.error('Collection summary synthesis failed:', e);
    return {
      answer: `You've got ${docs.length} documents saved — nice collection! 📚 I hit a small hiccup generating a detailed summary, but try asking again and I'll do my best! ✨`,
      results: [],
      durationMs: Date.now() - start,
      error: e instanceof Error ? e.message : String(e),
    };
  }
}

// ============================================================================
// EXPLORATORY HANDLER (uses collection metadata + LLM to find relevant docs)
// ============================================================================

async function handleExploratory(
  query: string,
  userId: string,
  env: RagSearchEnv,
  ctx: ExecutionContext
): Promise<{ answer: string; results: SearchResult[]; durationMs: number }> {
  const start = Date.now();

  const { docs, durationMs: fetchMs } = await fetchCollectionMetadata(userId, env);

  if (docs.length === 0) {
    return {
      answer: "Your collection is empty right now, but don't worry — you're just getting started! 🌱 Save some articles or notes using the Chrome extension, and I'll help you discover connections and insights across everything you save. It's going to be awesome! ✨",
      results: [],
      durationMs: Date.now() - start,
    };
  }

  // Build doc list for LLM analysis
  const docList = docs.map((d, i) =>
    `${i + 1}. "${d.title || 'Untitled'}" | Tag: ${d.tag || 'none'} | Saved: ${new Date(d.created_at).toLocaleDateString()}`
  ).join('\n');

  const prompt = `You are a friendly, enthusiastic search assistant for a personal notes app called infoSnap. The user has an exploratory query and wants to discover relevant documents in their collection.

User Query: "${query}"

All saved documents (${docs.length} total):
${docList}

INSTRUCTIONS:
1. Analyze each document's TITLE and TAG to judge if it could be relevant to the user's query.
2. List the document NUMBERS (from the list above) that are potentially relevant.
3. Write a warm, helpful explanation of what you found — like a friend helping them explore.
4. If you found matches, be enthusiastic! Mention specific titles and why they're relevant.
5. If NONE are relevant, be honest but encouraging — suggest what they could search for instead.
6. Use emojis naturally and format with markdown (bold, bullets) for readability.

Respond in this EXACT format:
RELEVANT_DOCS: <comma-separated numbers, or NONE>
ANSWER: <your friendly explanation to the user about what you found>`;

  try {
    const response = await callGroq(
      [
        { role: 'system', content: 'You are a friendly, enthusiastic document discovery assistant for infoSnap. Analyze titles and tags to find relevant documents. Be warm, encouraging, and honest. Use conversational tone with emojis and markdown formatting.' },
        { role: 'user', content: prompt }
      ],
      env,
      GROQ_SYNTHESIS_MODEL,
      0.2,
      1500
    );

    // Parse response
    let relevantIndices: number[] = [];
    let answer = '';

    for (const line of response.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.startsWith('RELEVANT_DOCS:')) {
        const docsStr = trimmed.slice(14).trim();
        if (docsStr.toUpperCase() !== 'NONE') {
          for (const num of docsStr.replace(/,/g, ' ').split(/\s+/)) {
            const idx = parseInt(num.trim(), 10) - 1;
            if (!isNaN(idx) && idx >= 0 && idx < docs.length) {
              relevantIndices.push(idx);
            }
          }
        }
      } else if (trimmed.startsWith('ANSWER:')) {
        answer = trimmed.slice(7).trim();
        // Capture remaining lines as part of answer
        const answerStartIdx = response.indexOf(trimmed);
        if (answerStartIdx >= 0) {
          answer = response.slice(answerStartIdx + 7).trim();
        }
        break;
      }
    }

    // If no structured answer parsed, use the full response
    if (!answer) {
      answer = response;
    }

    // Build results from relevant docs
    const results: SearchResult[] = [];
    for (const idx of relevantIndices.slice(0, 15)) {
      const doc = docs[idx];
      const token = await generateViewToken(doc.id, userId, env, 30);
      results.push({
        note_id: doc.id,
        title: doc.title || 'Untitled',
        chunk_content: '',
        tag: doc.tag,
        similarity_score: 0.8,
        source: 'exploratory',
        blob_url: doc.blob_url,
        file_type: doc.file_type,
        view_url: buildViewUrl(doc.id, token, env),
      });
    }

    return { answer, results, durationMs: Date.now() - start };
  } catch (e) {
    console.error('Exploratory search failed:', e);
    return {
      answer: "Oops, I hit a small bump while analyzing your collection! 😅 Try rephrasing your question, or hop over to the **Your Notes** tab to browse manually — sometimes the best discoveries happen that way! 🔍✨",
      results: [],
      durationMs: Date.now() - start,
      error: e instanceof Error ? e.message : String(e),
    };
  }
}

// ============================================================================
// TAG BROWSE HANDLER (explicit tag keyword required)
// ============================================================================

async function handleTagBrowse(
  query: string,
  userId: string,
  availableTags: string[],
  env: RagSearchEnv,
  ctx: ExecutionContext
): Promise<{ answer: string; results: SearchResult[]; tag: string | null; durationMs: number }> {
  const start = Date.now();

  // Detect which tag the user is referring to
  const detectedTag = detectTagInQuery(query, availableTags);

  if (!detectedTag) {
    // No matching tag found — tell user what tags are available
    const tagList = availableTags.length > 0
      ? availableTags.map(t => `**${t}**`).join(', ')
      : 'none yet';
    return {
      answer: `Hmm, I couldn't match a tag in your query! 🤔 Here are your available tags: ${tagList}.\n\nTry something like “show me docs tagged **resume**” and I'll pull them right up! 🎯`,
      results: [],
      tag: null,
      durationMs: Date.now() - start,
    };
  }

  // Fetch all docs under this tag
  const { results: tagResults, durationMs: searchMs } = await searchByTag(detectedTag, userId, 50, env);

  // Add view URLs
  for (const result of tagResults) {
    const token = await generateViewToken(result.note_id, userId, env, 30);
    result.view_url = buildViewUrl(result.note_id, token, env);
  }

  const answer = tagResults.length > 0
    ? `🎯 Found **${tagResults.length}** document${tagResults.length > 1 ? 's' : ''} under the tag **"${detectedTag}"** — here they are!`
    : `No documents found under the tag **"${detectedTag}"** yet. You can tag new documents when saving them! 🏷️`;

  return { answer, results: tagResults, tag: detectedTag, durationMs: Date.now() - start };
}

// ============================================================================
// SEARCH BY TAG (ported from retrieval_tools.py)
// ============================================================================

async function searchByTag(
  tag: string,
  userId: string,
  limit: number,
  env: RagSearchEnv
): Promise<{ results: SearchResult[]; durationMs: number }> {
  const start = Date.now();

  try {
    // Use direct REST query to ensure we get all fields including blob_url
    // The RPC function may not return blob_url
    const url = new URL(`${env.SUPABASE_URL}/rest/v1/notes`);
    url.searchParams.set('select', 'id,title,content_markdown,tag,created_at,blob_url,file_type');
    url.searchParams.set('user_id', `eq.${userId}`);
    url.searchParams.set('tag', `eq.${tag}`);
    url.searchParams.set('status', 'eq.active');  // Only fetch active notes
    url.searchParams.set('order', 'created_at.desc');
    url.searchParams.set('limit', String(limit));

    const response = await fetch(url.toString(), {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
        "apikey": env.SUPABASE_SERVICE_KEY,
        "Authorization": `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });

    if (!response.ok) {
      throw new Error(`Supabase error: ${response.status}`);
    }

    const data = await response.json() as Array<{
      id: string;
      title: string;
      content_markdown: string;
      tag: string;
      created_at: string;
      blob_url?: string;
      file_type?: string;
    }>;

    const results: SearchResult[] = data.map(r => ({
      note_id: r.id,
      title: r.title || "Untitled",
      chunk_content: r.content_markdown || "",  // Full content for relevance verification
      tag: r.tag,
      similarity_score: 1.0, // Exact tag match
      source: "tag",
      blob_url: r.blob_url,
      file_type: r.file_type,
    }));

    return { results, durationMs: Date.now() - start };
  } catch (e) {
    console.error("Search by tag error:", e);
    return { results: [], durationMs: Date.now() - start, error: e instanceof Error ? e.message : String(e) };
  }
}

// ============================================================================
// RELEVANCE VERIFICATION (ported from rag_agent.py _verify_relevance_with_llm)
// ============================================================================

interface RelevanceResult {
  verified: SearchResult[];
  durationMs: number;
  verificationDetails: Array<{
    note_id: string;
    title: string;
    rerank_score?: number;
    passed_verification: boolean;
  }>;
}

async function verifyRelevance(
  query: string,
  results: SearchResult[],
  env: RagSearchEnv
): Promise<RelevanceResult> {
  if (results.length === 0) {
    return { verified: [], durationMs: 0, verificationDetails: [] };
  }

  const start = Date.now();

  // Use full chunk content (same as what was passed to reranker) for accurate relevance verification
  const candidatesText = results.slice(0, 10).map((r, i) =>
    `${i + 1}. Title: ${r.title}\n   Content: ${r.chunk_content || "No content"}`
  ).join("\n\n");

  const prompt = `You are a search relevance validator. Given the user's search query, identify which documents are ACTUALLY RELEVANT.

User's Search Query: "${query}"

Available Documents:
${candidatesText}

Instructions:
1. Analyze semantic relevance between the query and each document
2. A document is relevant ONLY if it directly answers or relates to the user's query
3. Return the numbers of ALL relevant documents
4. Format: comma-separated numbers (e.g., "1, 3, 5")
5. If NONE of the documents are relevant to the query, return "NONE"
6. Be STRICT - if a document doesn't match the query intent, exclude it

Relevant document numbers:`;

  try {
    const response = await callGroq(
      [
        { role: "system", content: "You are a search relevance expert. Return only document numbers, nothing else." },
        { role: "user", content: prompt }
      ],
      env,
      GROQ_FAST_MODEL,
      0,
      30
    );

    // Track which indices passed
    const passedIndices = new Set<number>();
    
    if (response.toUpperCase() !== "NONE") {
      // Parse numbers
      for (const num of response.replace(/,/g, ' ').split(/\s+/)) {
        const idx = parseInt(num.trim(), 10) - 1;
        if (!isNaN(idx) && idx >= 0 && idx < results.length) {
          passedIndices.add(idx);
        }
      }
    }

    // Build verification details for all candidates
    const verificationDetails = results.slice(0, 10).map((r, i) => ({
      note_id: r.note_id,
      title: r.title,
      rerank_score: r.rerank_score,
      passed_verification: passedIndices.has(i),
    }));

    const verified = Array.from(passedIndices).map(i => results[i]);
    console.log(`Relevance check: ${verified.length}/${results.length} verified as relevant`);
    return { verified, durationMs: Date.now() - start, verificationDetails };
  } catch (e) {
    console.error("Relevance verification failed:", e);
    // On error, all pass verification
    const verificationDetails = results.slice(0, 10).map(r => ({
      note_id: r.note_id,
      title: r.title,
      rerank_score: r.rerank_score,
      passed_verification: true,
    }));
    return { verified: results, durationMs: Date.now() - start, verificationDetails, error: e instanceof Error ? e.message : String(e) };
  }
}

// ============================================================================
// SYNTHESIS (ported from rag_agent.py _synthesize_answer_with_full_content)
// ============================================================================

async function synthesizeAnswer(
  query: string,
  results: SearchResult[],
  env: RagSearchEnv,
  ctx: ExecutionContext
): Promise<{ answer: string | null; cached: boolean; durationMs: number }> {
  if (results.length === 0) {
    return { answer: null, cached: false, durationMs: 0 };
  }

  const start = Date.now();

  // Check synthesis cache
  const noteIds = results.map(r => r.note_id).sort();
  const cacheKey = `synth_${hashString(query.toLowerCase() + ':' + noteIds.join(','))}`;

  try {
    const cached = await env.SYNTHESIS_CACHE.get(cacheKey);
    if (cached) {
      console.log("Synthesis cache HIT");
      return { answer: cached, cached: true, durationMs: Date.now() - start };
    }
  } catch (e) {
    console.error("Synthesis cache read error:", e);
  }

  // Fetch full content for documents
  const fullContents: Array<{ title: string; content: string }> = [];
  
  for (const result of results.slice(0, 5)) {
    try {
      const response = await fetch(
        `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${result.note_id}&status=eq.active&select=title,content_markdown`,
        {
          headers: {
            "apikey": env.SUPABASE_SERVICE_KEY,
            "Authorization": `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      );

      if (response.ok) {
        const data = await response.json() as Array<{ title: string; content_markdown: string }>;
        if (data.length > 0) {
          let content = data[0].content_markdown || "";
          // Truncate if too long
          if (content.length > 8000) {
            content = content.slice(0, 8000) + "\n... [content truncated]";
          }
          fullContents.push({
            title: data[0].title || result.title,
            content,
          });
        }
      }
    } catch (e) {
      console.error(`Failed to fetch full content for ${result.note_id}:`, e);
      // Fall back to chunk content
      fullContents.push({
        title: result.title,
        content: result.chunk_content,
      });
    }
  }

  if (fullContents.length === 0) {
    return { answer: null, cached: false, durationMs: Date.now() - start };
  }

  // Build context
  const contextText = fullContents.map((fc, i) =>
    `=== DOCUMENT ${i + 1}: ${fc.title} ===\n${fc.content}`
  ).join("\n\n");

  const synthesisPrompt = `You are a friendly, knowledgeable assistant that answers questions based on the user's saved documents in infoSnap.

QUESTION: ${query}

DOCUMENTS:
${contextText}

INSTRUCTIONS:
1. Answer the question directly and specifically based on the document content.
2. If the documents contain the specific information asked for (names, dates, numbers, etc.), extract and state it clearly.
3. Do NOT give vague or hedging answers like "you may need to check" — if the information is in the documents, state it confidently.
4. If the information is NOT in any of the documents, say something like "Hmm, I couldn't find this in your saved documents — you might want to save a relevant article about this topic! 📝"
5. Use a warm, conversational tone — like a smart friend who read all their documents.
6. Format nicely with markdown: **bold** key facts, use bullet points for lists.
7. Keep the answer concise but complete.

ANSWER:`;

  try {
    const answer = await callGroq(
      [
        { role: "system", content: "You are a friendly, precise document Q&A assistant for infoSnap. Extract and state information from documents in a warm, conversational tone. Use markdown formatting and emojis sparingly. Be confident and direct with your answers." },
        { role: "user", content: synthesisPrompt }
      ],
      env,
      GROQ_SYNTHESIS_MODEL,
      0.1,
      1000
    );

    // Cache the result (async)
    ctx.waitUntil(
      env.SYNTHESIS_CACHE.put(cacheKey, answer, { expirationTtl: SYNTHESIS_CACHE_TTL })
        .catch(e => console.error("Synthesis cache write error:", e))
    );

    return { answer, cached: false, durationMs: Date.now() - start };
  } catch (e) {
    console.error("Synthesis failed:", e);
    return { answer: null, cached: false, durationMs: Date.now() - start, error: e instanceof Error ? e.message : String(e) };
  }
}

function hashString(str: string): string {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash;
  }
  return hash.toString(16);
}

// ============================================================================
// MAIN RAG SEARCH HANDLER
// ============================================================================

export async function handleRagSearch(
  request: Request,
  env: RagSearchEnv,
  ctx: ExecutionContext,
  requestId: string,
  // Functions from main Worker to reuse
  hybridSearchFn: (params: {
    query: string;
    user_id: string;
    tag?: string;
    limit: number;
    rerank: boolean;
  }, env: any, ctx: ExecutionContext) => Promise<{
    matches: Array<{
      note_id?: string;
      title?: string;
      content?: string;
      tag?: string;
      similarity?: number;
      rerank_score?: number;
      blob_url?: string;
      [key: string]: any;
    }>;
    timing: { embedding_ms: number; parallel_search_ms: number; keyword_ms: number; rerank_ms: number };
    embedding_cached: boolean;
    trace_data?: {
      vector_candidates: Array<Record<string, any>>;
      keyword_candidates: Array<Record<string, any>>;
      combined_candidates: Array<Record<string, any>>;
      reranked_candidates: Array<Record<string, any>>;
    };
  }>
): Promise<Response> {
  const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
  };

  const start = Date.now();
  const llmCalls: LLMCall[] = [];
  const pipelineErrors: Array<{ stage: string; error: string }> = [];
  
  // Timestamp tracking for detailed trace logging - ALL phases
  const timestamps: {
    request_received_at: string;
    auth_started_at?: string;
    auth_completed_at?: string;
    spell_check_started_at?: string;
    tags_fetch_started_at?: string;
    embedding_started_at?: string;
    search_started_at?: string;
    rerank_started_at?: string;
    relevance_check_started_at?: string;
    synthesis_started_at?: string;
    response_sent_at?: string;
  } = {
    request_received_at: new Date(start).toISOString(),
  };

  try {
    const body: RagSearchRequest & { _auth_timing?: {
      auth_started_at?: string;
      auth_completed_at?: string;
      timing_auth_ms?: number;
      auth_method?: string;
      auth_user_email?: string;
    }} = await request.json();

    if (!body.query || !body.user_id) {
      return new Response(
        JSON.stringify({ error: "Must provide 'query' and 'user_id'" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }

    // Extract auth timing if passed from /rag-search-auth handler
    const authTiming = body._auth_timing;
    if (authTiming) {
      timestamps.auth_started_at = authTiming.auth_started_at;
      timestamps.auth_completed_at = authTiming.auth_completed_at;
    }

    // max_results is now only used as a final cap on returned results (after all threshold filtering)
    // The pipeline uses quality thresholds, not arbitrary limits
    const finalResultsCap = body.max_results || 10;
    const debug = body.debug === true;

    console.log(`[${requestId}] RAG search: query="${body.query.slice(0, 50)}...", user=${body.user_id.slice(0, 8)}`);

    // ========================================================================
    // STEP 1: AUTH (already validated in main handler)
    // ========================================================================

    // ========================================================================
    // STEP 2: SPELL CHECK (DISABLED - was incorrectly correcting technical terms like "rag" to "tag")
    // ========================================================================
    timestamps.spell_check_started_at = new Date().toISOString();
    // const spellResult = await spellCheck(body.query, env);
    // llmCalls.push({ model: GROQ_FAST_MODEL, purpose: "spell_check", duration_ms: spellResult.durationMs });
    const spellResult = { original: body.query, corrected: body.query, wasChanged: false, explanation: 'Spell check disabled', durationMs: 0 };

    const correctedQuery = spellResult.corrected;
    console.log(`[${requestId}] Spell check: DISABLED (using original query)`);

    // ========================================================================
    // STEP 3: FETCH TAGS + CLASSIFY INTENT (parallel)
    // ========================================================================
    timestamps.tags_fetch_started_at = new Date().toISOString();
    const tagsResult = await fetchUserTags(body.user_id, env);
    if ((tagsResult as any).error) {
      pipelineErrors.push({ stage: 'tags_fetch', error: (tagsResult as any).error });
    }
    console.log(`[${requestId}] Tags: ${tagsResult.tags.length} available`);

    // LLM Intent Router — replaces old analyzeQueryLocal()
    const intentResult = await classifyQueryIntent(correctedQuery, tagsResult.tags, env);
    llmCalls.push({ model: GROQ_FAST_MODEL, purpose: "intent_router", duration_ms: intentResult.durationMs });
    if (intentResult.confidence === 'LOW' && intentResult.reasoning.startsWith('Fallback due to error')) {
      pipelineErrors.push({ stage: 'intent_router', error: intentResult.reasoning });
    }
    console.log(`[${requestId}] Intent: ${intentResult.intent} (${intentResult.confidence}) — ${intentResult.reasoning}`);

    // ========================================================================
    // STEP 4: ROUTE TO HANDLER BASED ON INTENT
    // ========================================================================
    let results: SearchResult[] = [];
    let pathTaken: 'tag' | 'hybrid' | 'collection_summary' | 'exploratory' | 'tag_browse' = 'hybrid';
    let tagIntent: 'LIST_ALL' | 'SPECIFIC' | undefined;
    let analysis: QueryAnalysis | undefined;
    let hybridTiming = { embedding_ms: 0, parallel_search_ms: 0, keyword_ms: 0, rerank_ms: 0 };
    let embeddingCached = false;
    let tagIntentMs = 0;
    let analysisMs = 0;
    let answer: string | undefined;
    let synthesisCached = false;
    let synthesisMs = 0;
    let collectionFetchMs = 0;
    let collectionDocCount = 0;
    
    // Trace data for pipeline visibility
    let traceData: {
      vector_candidates: Array<Record<string, any>>;
      keyword_candidates: Array<Record<string, any>>;
      combined_candidates: Array<Record<string, any>>;
      reranked_candidates: Array<Record<string, any>>;
    } | undefined;

    // Track relevance result for trace logging
    let relevanceResult: { verified: SearchResult[], durationMs: number, verificationDetails?: any[] } = { 
      verified: [], 
      durationMs: 0,
      verificationDetails: undefined 
    };

    if (intentResult.intent === 'DATE_QUERY') {
      // ======================================================================
      // DATE_QUERY — Canned response directing user to Your Notes tab
      // ======================================================================
      pathTaken = 'hybrid';
      answer = "Great question! 📅 For browsing by date, head over to the **Your Notes** section and sort by Date — you'll get a beautiful chronological timeline of everything you've saved. It's the fastest way to find recent saves! \n\nPro tip: You can also filter by tag there to narrow things down even further. Happy browsing! ✨";
      console.log(`[${requestId}] DATE_QUERY: returning guidance response`);

    } else if (intentResult.intent === 'MULTI_STEP') {
      // ======================================================================
      // MULTI_STEP — Canned response (not supported)
      // ======================================================================
      pathTaken = 'hybrid';
      answer = "I appreciate the ambition! 😄 I can't handle complex multi-step operations like comparing or merging documents just yet — but that's definitely on the roadmap!\n\nIn the meantime, here's a workaround: search for each document individually, then open them side by side from the **Your Notes** section. Works like a charm! 🔍✨";
      console.log(`[${requestId}] MULTI_STEP: returning guidance response`);

    } else if (intentResult.intent === 'TAG_BROWSE') {
      // ======================================================================
      // TAG_BROWSE — Explicit tag browsing (user used word "tag")
      // ======================================================================
      pathTaken = 'tag_browse' as any;
      const tagBrowseResult = await handleTagBrowse(correctedQuery, body.user_id, tagsResult.tags, env, ctx);
      results = tagBrowseResult.results;
      answer = tagBrowseResult.answer;
      llmCalls.push({ model: 'none', purpose: 'tag_browse', duration_ms: tagBrowseResult.durationMs });
      console.log(`[${requestId}] TAG_BROWSE: tag=${tagBrowseResult.tag}, ${results.length} results`);

    } else if (intentResult.intent === 'COLLECTION_SUMMARY') {
      // ======================================================================
      // COLLECTION_SUMMARY — Overview/count of all docs
      // ======================================================================
      pathTaken = 'collection_summary' as any;
      timestamps.synthesis_started_at = new Date().toISOString();
      const summaryResult = await handleCollectionSummary(correctedQuery, body.user_id, env, ctx);
      results = summaryResult.results;
      answer = summaryResult.answer;
      synthesisMs = summaryResult.durationMs;
      collectionDocCount = results.length;
      if ((summaryResult as any).error) {
        pipelineErrors.push({ stage: 'collection_summary', error: (summaryResult as any).error });
      }
      llmCalls.push({ model: GROQ_SYNTHESIS_MODEL, purpose: 'collection_summary', duration_ms: summaryResult.durationMs });
      console.log(`[${requestId}] COLLECTION_SUMMARY: ${results.length} doc references, answer length=${answer?.length}`);

    } else if (intentResult.intent === 'EXPLORATORY') {
      // ======================================================================
      // EXPLORATORY — Vague/discovery queries, LLM analyzes titles+tags
      // ======================================================================
      pathTaken = 'exploratory' as any;
      timestamps.synthesis_started_at = new Date().toISOString();
      const exploratoryResult = await handleExploratory(correctedQuery, body.user_id, env, ctx);
      results = exploratoryResult.results;
      answer = exploratoryResult.answer;
      synthesisMs = exploratoryResult.durationMs;
      collectionDocCount = results.length;
      if ((exploratoryResult as any).error) {
        pipelineErrors.push({ stage: 'exploratory', error: (exploratoryResult as any).error });
      }
      llmCalls.push({ model: GROQ_SYNTHESIS_MODEL, purpose: 'exploratory', duration_ms: exploratoryResult.durationMs });
      console.log(`[${requestId}] EXPLORATORY: ${results.length} relevant docs found`);

    } else {
      // ======================================================================
      // CONTENT_SEARCH — Default: existing hybrid search pipeline (untouched)
      // ======================================================================
      pathTaken = 'hybrid';

      // Check if a tag is detected in the query for filtered hybrid search
      const detectedTag = detectTagInQuery(correctedQuery, tagsResult.tags);
      
      if (detectedTag) {
        // Tag detected — classify if LIST_ALL or SPECIFIC
        const remainingKeywords = extractKeywordsBeyondTag(correctedQuery, detectedTag);
        const tagClassifyResult = await classifyTagIntent(correctedQuery, detectedTag, remainingKeywords, env);
        tagIntent = tagClassifyResult.intent;
        tagIntentMs = tagClassifyResult.durationMs;
        if ((tagClassifyResult as any).error) {
          pipelineErrors.push({ stage: 'tag_intent', error: (tagClassifyResult as any).error });
        }
        llmCalls.push({ model: GROQ_FAST_MODEL, purpose: "tag_intent", duration_ms: tagIntentMs });
        pathTaken = 'tag';

        if (tagIntent === 'LIST_ALL') {
          const tagSearchResult = await searchByTag(detectedTag, body.user_id, 50, env);
          if ((tagSearchResult as any).error) {
            pipelineErrors.push({ stage: 'tag_search', error: (tagSearchResult as any).error });
          }
          results = tagSearchResult.results;
          console.log(`[${requestId}] CONTENT_SEARCH → TAG PATH (LIST_ALL): ${results.length} results`);
        } else {
          timestamps.embedding_started_at = new Date().toISOString();
          timestamps.search_started_at = new Date().toISOString();
          const hybridResult = await hybridSearchFn({
            query: correctedQuery,
            user_id: body.user_id,
            tag: detectedTag,
            limit: 50,
            rerank: true,
          }, env, ctx);

          results = hybridResult.matches.map(m => ({
            note_id: String(m.note_id || ""),
            title: String(m.title || "Untitled"),
            chunk_content: String(m.content || ""),
            tag: m.tag as string | undefined,
            similarity_score: m.similarity || m.rerank_score || 0,
            rerank_score: m.rerank_score,
            source: "hybrid",
            blob_url: m.blob_url as string | undefined,
          }));

          hybridTiming = hybridResult.timing;
          embeddingCached = hybridResult.embedding_cached;
          traceData = hybridResult.trace_data;
          
          if (hybridTiming.rerank_ms > 0 && timestamps.search_started_at) {
            const searchStartTime = new Date(timestamps.search_started_at).getTime();
            const rerankStartTime = searchStartTime + hybridTiming.embedding_ms + hybridTiming.parallel_search_ms;
            timestamps.rerank_started_at = new Date(rerankStartTime).toISOString();
          }
          
          console.log(`[${requestId}] CONTENT_SEARCH → TAG PATH (SPECIFIC): ${results.length} results`);
        }
      } else {
        // No tag detected — full hybrid search
        const analysisStart = Date.now();
        analysis = analyzeQueryLocal(correctedQuery, tagsResult.tags);
        analysisMs = Date.now() - analysisStart;

        timestamps.embedding_started_at = new Date().toISOString();
        timestamps.search_started_at = new Date().toISOString();
        const hybridResult = await hybridSearchFn({
          query: correctedQuery,
          user_id: body.user_id,
          limit: 50,
          rerank: true,
        }, env, ctx);

        results = hybridResult.matches.map(m => ({
          note_id: String(m.note_id || ""),
          title: String(m.title || "Untitled"),
          chunk_content: String(m.content || ""),
          tag: m.tag as string | undefined,
          similarity_score: m.similarity || m.rerank_score || 0,
          rerank_score: m.rerank_score,
          source: "hybrid",
          blob_url: m.blob_url as string | undefined,
        }));

        hybridTiming = hybridResult.timing;
        embeddingCached = hybridResult.embedding_cached;
        traceData = hybridResult.trace_data;
        
        if (hybridTiming.rerank_ms > 0 && timestamps.search_started_at) {
          const searchStartTime = new Date(timestamps.search_started_at).getTime();
          const rerankStartTime = searchStartTime + hybridTiming.embedding_ms + hybridTiming.parallel_search_ms;
          timestamps.rerank_started_at = new Date(rerankStartTime).toISOString();
        }
        
        console.log(`[${requestId}] CONTENT_SEARCH → HYBRID PATH: ${results.length} results`);
      }

      // ====================================================================
      // RELEVANCE VERIFICATION (only for CONTENT_SEARCH path)
      // Skip for LIST_ALL tag queries
      // ====================================================================
      timestamps.relevance_check_started_at = new Date().toISOString();
      
      if (pathTaken === 'tag' && tagIntent === 'LIST_ALL') {
        console.log(`[${requestId}] Skipping relevance check for LIST_ALL tag query`);
        relevanceResult = { verified: results, durationMs: 0, verificationDetails: undefined };
        llmCalls.push({ model: GROQ_FAST_MODEL, purpose: "relevance_check", duration_ms: 0 });
      } else {
        relevanceResult = await verifyRelevance(correctedQuery, results, env);
        if ((relevanceResult as any).error) {
          pipelineErrors.push({ stage: 'relevance_check', error: (relevanceResult as any).error });
        }
        results = relevanceResult.verified;
        llmCalls.push({ model: GROQ_FAST_MODEL, purpose: "relevance_check", duration_ms: relevanceResult.durationMs });
      }

      // ====================================================================
      // DEDUPLICATE by note_id
      // ====================================================================
      const uniqueDocsMap = new Map<string, SearchResult>();
      for (const result of results) {
        const noteId = result.note_id;
        const existing = uniqueDocsMap.get(noteId);
        const currentScore = result.rerank_score || result.similarity_score || 0;
        const existingScore = existing ? (existing.rerank_score || existing.similarity_score || 0) : -1;
        
        if (!existing || currentScore > existingScore) {
          uniqueDocsMap.set(noteId, result);
        }
      }
      const beforeDedup = results.length;
      results = Array.from(uniqueDocsMap.values());
      
      results.sort((a, b) => {
        const scoreA = a.rerank_score || a.similarity_score || 0;
        const scoreB = b.rerank_score || b.similarity_score || 0;
        return scoreB - scoreA;
      });
      
      const dedupRemoved = beforeDedup - results.length;
      if (traceData) {
        (traceData as any).dedup_before_count = beforeDedup;
        (traceData as any).dedup_after_count = results.length;
        (traceData as any).dedup_removed = dedupRemoved;
      }
      
      if (beforeDedup !== results.length) {
        console.log(`[${requestId}] Dedup: ${beforeDedup} → ${results.length} unique documents`);
      }

      // ====================================================================
      // FILTER OUT INCOMPLETE NOTES (failed uploads)
      // ====================================================================
      const { results: activeResults, filteredCount } = await filterActiveNotes(results, env);
      if (filteredCount > 0) {
        console.log(`[${requestId}] Filtered out ${filteredCount} incomplete notes`);
      }
      results = activeResults;

      // ====================================================================
      // APPLY FINAL RESULTS CAP
      // ====================================================================
      if (results.length > finalResultsCap) {
        console.log(`[${requestId}] Applying final cap: ${results.length} → ${finalResultsCap} results`);
        results = results.slice(0, finalResultsCap);
      }

      // ====================================================================
      // ADD VIEW URLS (signed tokens for document access)
      // ====================================================================
      const viewUrlPromises = results.map(async (result) => {
        const token = await generateViewToken(result.note_id, body.user_id, env, 30);
        result.view_url = buildViewUrl(result.note_id, token, env);
        return result;
      });
      results = await Promise.all(viewUrlPromises);
      console.log(`[${requestId}] Added view URLs for ${results.length} results`);

      // ====================================================================
      // SYNTHESIS (for CONTENT_SEARCH only, if query needs it)
      // ====================================================================
      if (analysis?.needs_synthesis && results.length > 0) {
        timestamps.synthesis_started_at = new Date().toISOString();
        const synthesisResult = await synthesizeAnswer(correctedQuery, results, env, ctx);
        answer = synthesisResult.answer || undefined;
        synthesisCached = synthesisResult.cached;
        synthesisMs = synthesisResult.durationMs;
        if ((synthesisResult as any).error) {
          pipelineErrors.push({ stage: 'synthesis', error: (synthesisResult as any).error });
        }

        if (!synthesisResult.cached) {
          llmCalls.push({ model: GROQ_SYNTHESIS_MODEL, purpose: "synthesis", duration_ms: synthesisMs });
        }
      }
    } // end CONTENT_SEARCH

    // ========================================================================
    // BUILD RESPONSE
    // ========================================================================
    const totalMs = Date.now() - start;

    const metadata: RagSearchMetadata = {
      timing: {
        total_ms: totalMs,
        spell_check_ms: spellResult.durationMs,
        tags_fetch_ms: tagsResult.durationMs,
        intent_router_ms: intentResult.durationMs,
        analysis_ms: analysisMs || undefined,
        tag_intent_ms: tagIntentMs || undefined,
        embedding_ms: hybridTiming.embedding_ms,
        vector_search_ms: hybridTiming.parallel_search_ms,
        keyword_search_ms: hybridTiming.keyword_ms,
        rerank_ms: hybridTiming.rerank_ms,
        relevance_check_ms: relevanceResult.durationMs,
        synthesis_ms: synthesisMs || undefined,
      },
      spell_check: {
        original: body.query,
        corrected: correctedQuery,
        was_corrected: spellResult.wasChanged,
        explanation: spellResult.explanation,
      },
      tags: {
        available: tagsResult.tags,
        detected: [],
        intent: tagIntent,
      },
      analysis,
      cache_hits: {
        embedding: embeddingCached,
        tags: tagsResult.cached,
        synthesis: synthesisCached,
      },
      llm_calls: llmCalls,
    };

    const response: RagSearchResponse = {
      success: true,
      results,
      answer,
      path_taken: pathTaken,
      metadata,
      request_id: requestId,
      worker_request_id: requestId,  // Alias for Chrome extension compatibility
    };

    console.log(`[${requestId}] RAG search complete: ${results.length} results, path=${pathTaken}, total=${totalMs}ms`);

    // ========================================================================
    // SEND SEARCH TRACE (fire and forget)
    // ========================================================================
    timestamps.response_sent_at = new Date().toISOString();
    sendRagSearchTrace({
      correlation_id: requestId,
      user_id: body.user_id,
      query: body.query,
      query_corrected: spellResult.wasChanged ? correctedQuery : undefined,
      // Timestamps for each phase
      request_received_at: timestamps.request_received_at,
      auth_started_at: timestamps.auth_started_at,
      auth_completed_at: timestamps.auth_completed_at,
      spell_check_started_at: timestamps.spell_check_started_at,
      tags_fetch_started_at: timestamps.tags_fetch_started_at,
      embedding_started_at: timestamps.embedding_started_at,
      search_started_at: timestamps.search_started_at,
      rerank_started_at: timestamps.rerank_started_at,
      relevance_check_started_at: timestamps.relevance_check_started_at,
      synthesis_started_at: timestamps.synthesis_started_at,
      response_sent_at: timestamps.response_sent_at,
      // Complete timing breakdown
      timing_total_ms: totalMs,
      timing_auth_ms: authTiming?.timing_auth_ms,
      timing_spell_check_ms: spellResult.durationMs,
      timing_tags_fetch_ms: tagsResult.durationMs,
      timing_embedding_ms: hybridTiming.embedding_ms,
      timing_vector_search_ms: hybridTiming.parallel_search_ms,
      timing_keyword_search_ms: hybridTiming.keyword_ms,
      timing_rerank_ms: hybridTiming.rerank_ms,
      timing_relevance_check_ms: relevanceResult.durationMs,
      timing_synthesis_ms: synthesisMs || undefined,
      timing_worker_ms: totalMs,
      // Auth details
      auth_method: authTiming?.auth_method,
      auth_user_email: authTiming?.auth_user_email,
      // Cache status
      embedding_cached: embeddingCached,
      search_cached: false,
      tags_cached: tagsResult.cached,
      synthesis_cached: synthesisCached,
      // Chunk grouping info (top 3 per doc)
      chunks_before_grouping: (traceData as any)?.chunks_before_grouping,
      chunks_after_grouping: (traceData as any)?.chunks_after_grouping,
      unique_documents: (traceData as any)?.unique_documents,
      chunks_per_doc_limit: (traceData as any)?.chunks_per_doc_limit,
      // Dedup after LLM verification
      dedup_before_count: (traceData as any)?.dedup_before_count,
      dedup_after_count: (traceData as any)?.dedup_after_count,
      dedup_removed: (traceData as any)?.dedup_removed,
      // Include candidate data from hybrid search
      vector_candidates: traceData?.vector_candidates || [],
      keyword_candidates: traceData?.keyword_candidates || [],
      combined_candidates: traceData?.combined_candidates || [],
      reranked_candidates: traceData?.reranked_candidates || [],
      relevance_verified_candidates: relevanceResult.verificationDetails || [],
      vector_count: traceData?.vector_candidates?.length || 0,
      keyword_count: traceData?.keyword_candidates?.length || 0,
      combined_count: traceData?.combined_candidates?.length || 0,
      reranked_count: traceData?.reranked_candidates?.length || 0,
      relevance_verified_count: relevanceResult.verificationDetails?.filter(v => v.passed_verification).length || results.length,
      final_results: results.map(r => ({
        note_id: r.note_id,
        title: r.title,
        rerank_score: r.rerank_score,
        similarity_score: r.similarity_score,
        source: r.source,
      })),
      final_count: results.length,
      min_vector_threshold: MIN_VECTOR_SIMILARITY,
      min_rerank_threshold: MIN_RERANK_SCORE,
      source_worker: "cloudflare-worker",
      request_path: "/rag-search",
      client_source: body.client_source || "unknown",
      // Agentic RAG fields
      intent_classification: intentResult.intent,
      intent_confidence: intentResult.confidence,
      intent_reasoning: intentResult.reasoning,
      timing_intent_router_ms: intentResult.durationMs,
      tool_invoked: pathTaken === 'hybrid' && !answer ? 'hybrid_search'
        : pathTaken === 'tag' ? 'tag_filtered_search'
        : pathTaken === 'tag_browse' ? 'tag_browse'
        : pathTaken === 'collection_summary' ? 'collection_summary'
        : pathTaken === 'exploratory' ? 'exploratory'
        : intentResult.intent === 'DATE_QUERY' ? 'date_query_canned'
        : intentResult.intent === 'MULTI_STEP' ? 'multi_step_canned'
        : 'hybrid_search',
      path_taken: pathTaken,
      error_occurred: pipelineErrors.length > 0,
      error_message: pipelineErrors.length > 0
        ? pipelineErrors.map(e => `[${e.stage}] ${e.error}`).join(' | ')
        : undefined,
      error_type: pipelineErrors.length > 0
        ? (pipelineErrors.length === 1 ? pipelineErrors[0].stage : 'multiple_pipeline_errors')
        : undefined,
      collection_doc_count: collectionDocCount ?? undefined,
      llm_calls: llmCalls,
      answer_generated: !!answer,
      answer_preview: answer ? answer.slice(0, 200) : undefined,
    }, env, ctx);

    return new Response(
      JSON.stringify(response),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );

  } catch (error) {
    const totalMs = Date.now() - start;
    console.error(`[${requestId}] RAG search error:`, error);

    // Log the error to the search trace
    timestamps.response_sent_at = new Date().toISOString();
    sendRagSearchTrace({
      correlation_id: requestId,
      user_id: '', // may not have been parsed yet
      query: '', // may not have been parsed yet
      request_received_at: timestamps.request_received_at,
      response_sent_at: timestamps.response_sent_at,
      timing_total_ms: totalMs,
      timing_worker_ms: totalMs,
      embedding_cached: false,
      search_cached: false,
      error_occurred: true,
      error_message: String(error),
      error_type: (error as Error)?.constructor?.name || 'UnknownError',
      source_worker: "cloudflare-worker",
      request_path: "/rag-search",
      final_count: 0,
    }, env, ctx);

    return new Response(
      JSON.stringify({ error: String(error), request_id: requestId }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}
