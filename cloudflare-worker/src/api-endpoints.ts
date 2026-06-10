/**
 * API Endpoints for Cloudflare Worker
 * 
 * Migrated from Fly.io backend to eliminate latency and improve scaling.
 * These endpoints talk directly to Supabase.
 */

import { AuthResult } from './auth';
import { chunkText, deleteAzureBlob } from './upload-routes';
import { fetchInstagramLegalEnrichment } from './social-enrichers';
import { logAudit } from './audit';

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
};

function withSearchDescription(content: string, description?: string | null): string {
  const desc = (description || '').trim();
  if (!desc) return content;
  return `User description: ${desc}\n\n${content}`;
}

export interface ApiEnv {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  SUPABASE_JWT_SECRET: string;
  GROQ_API_KEY?: string;
  AZURE_STORAGE_CONNECTION_STRING?: string;
  AZURE_STORAGE_CONTAINER?: string;
  AZURE_THUMBNAILS_CONTAINER?: string;
  INSTAGRAM_OEMBED_ACCESS_TOKEN?: string;
}

// Extended env for endpoints that need VECTORIZE and Azure storage
export interface ApiEnvWithVectorize extends ApiEnv {
  VECTORIZE: Vectorize;
  AZURE_STORAGE_CONNECTION_STRING: string;
  AI: Ai;
  EMBEDDING_MODEL: string;
}

// ============================================================================
// Helper: Supabase REST API call
// ============================================================================
async function supabaseQuery(
  env: ApiEnv,
  table: string,
  options: {
    method?: 'GET' | 'POST' | 'PATCH' | 'DELETE';
    select?: string;
    filters?: Record<string, string>;
    body?: any;
    order?: { column: string; ascending?: boolean };
    limit?: number;
    offset?: number;
    single?: boolean;
  } = {}
): Promise<{ data: any; error?: string }> {
  const { method = 'GET', select, filters, body, order, limit, offset, single } = options;
  
  let url = `${env.SUPABASE_URL}/rest/v1/${table}`;
  const params = new URLSearchParams();
  
  if (select) params.set('select', select);
  if (filters) {
    for (const [key, value] of Object.entries(filters)) {
      params.set(key, value);
    }
  }
  if (order) {
    params.set('order', `${order.column}.${order.ascending ? 'asc' : 'desc'}`);
  }
  if (limit) params.set('limit', limit.toString());
  if (offset) params.set('offset', offset.toString());
  
  const queryString = params.toString();
  if (queryString) url += `?${queryString}`;
  
  const headers: Record<string, string> = {
    'apikey': env.SUPABASE_SERVICE_KEY,
    'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
  };
  
  if (body) {
    headers['Content-Type'] = 'application/json';
    if (single) {
      headers['Prefer'] = 'return=representation';
    }
  }
  
  try {
    const response = await fetch(url, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
    
    if (!response.ok) {
      const text = await response.text();
      return { data: null, error: `Supabase error: ${response.status} - ${text}` };
    }
    
    const data = await response.json();
    return { data };
  } catch (e) {
    return { data: null, error: String(e) };
  }
}

// ============================================================================
// Helper: Azure Blob SAS generation for private thumbnail URLs
// ============================================================================
function parseAzureConnectionString(conn: string): { accountName: string; accountKey: string } | null {
  let accountName = '';
  let accountKey = '';
  for (const part of conn.split(';')) {
    if (part.startsWith('AccountName=')) {
      accountName = part.substring('AccountName='.length);
    } else if (part.startsWith('AccountKey=')) {
      accountKey = part.substring('AccountKey='.length);
    }
  }
  if (!accountName || !accountKey) return null;
  return { accountName, accountKey };
}

function extractBlobNameFromUrl(blobUrl: string, container: string): string | null {
  try {
    const parsed = new URL(blobUrl);
    const path = parsed.pathname.replace(/^\/+/, ''); // container/user/file
    const prefix = `${container}/`;
    if (!path.startsWith(prefix)) return null;
    return path.substring(prefix.length);
  } catch {
    return null;
  }
}

async function generateAzureSasForBlobName(
  blobName: string,
  env: ApiEnv,
  expiryMinutes: number = 60
): Promise<string | null> {
  if (!env.AZURE_STORAGE_CONNECTION_STRING || !env.AZURE_STORAGE_CONTAINER) {
    return null;
  }

  const parsed = parseAzureConnectionString(env.AZURE_STORAGE_CONNECTION_STRING);
  if (!parsed) return null;

  const { accountName, accountKey } = parsed;
  const containerName = env.AZURE_STORAGE_CONTAINER;

  const now = new Date();
  const start = new Date(now.getTime() - 5 * 60 * 1000);
  const expiry = new Date(now.getTime() + expiryMinutes * 60 * 1000);
  const fmt = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');

  const signedStart = fmt(start);
  const signedExpiry = fmt(expiry);
  const version = '2020-02-10';
  const permissions = 'r';
  const canonicalizedResource = `/blob/${accountName}/${containerName}/${blobName}`;

  const stringToSign = [
    permissions,
    signedStart,
    signedExpiry,
    canonicalizedResource,
    '',
    '',
    '',
    version,
    'b',
    '',
    '',
    '',
    '',
    '',
    '',
  ].join('\n');

  const keyBuffer = Uint8Array.from(atob(accountKey), c => c.charCodeAt(0));
  const hmacKey = await crypto.subtle.importKey(
    'raw',
    keyBuffer,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const sigBuffer = await crypto.subtle.sign('HMAC', hmacKey, new TextEncoder().encode(stringToSign));
  const signature = btoa(String.fromCharCode(...new Uint8Array(sigBuffer)));

  const qs = new URLSearchParams({
    sv: version,
    st: signedStart,
    se: signedExpiry,
    sr: 'b',
    sp: permissions,
    sig: signature,
  });

  const base = `https://${accountName}.blob.core.windows.net/${containerName}/${blobName}`;
  return `${base}?${qs.toString()}`;
}

// ----------------------------------------------------------------------------
// In-memory SAS URL cache, scoped to a single Worker isolate.
//
// Why: handleListNotes / bootstrap / recap each call ensureSignedAzureUrl once
// per note (or per collection cover, or per avatar), which used to mean a fresh
// HMAC-SHA256 signing and querystring build for every URL on every request.
// Within one isolate the same blob is signed many times in close succession
// (a single list page can produce 200 thumbnail signings).
//
// We cache the fully signed URL keyed by container/blobName. The SAS is minted
// for SAS_EXPIRY_MINUTES; we expire the cache entry SAS_CACHE_BUFFER_MINUTES
// before that so a returned URL always has at least the buffer of validity
// remaining when the client uses it.
//
// The cache is bounded to SAS_CACHE_MAX_ENTRIES; once full we drop the oldest
// 20 % (Map preserves insertion order, so iterating from the start gives us
// the oldest entries) to keep memory predictable.
// ----------------------------------------------------------------------------
const SAS_EXPIRY_MINUTES = 60;
const SAS_CACHE_BUFFER_MINUTES = 10;
const SAS_CACHE_TTL_MS = (SAS_EXPIRY_MINUTES - SAS_CACHE_BUFFER_MINUTES) * 60 * 1000;
const SAS_CACHE_MAX_ENTRIES = 5000;

type SasCacheEntry = { url: string; expiresAt: number };
const sasUrlCache: Map<string, SasCacheEntry> = new Map();

function getCachedSasUrl(key: string): string | null {
  const entry = sasUrlCache.get(key);
  if (!entry) return null;
  if (Date.now() >= entry.expiresAt) {
    sasUrlCache.delete(key);
    return null;
  }
  return entry.url;
}

function setCachedSasUrl(key: string, url: string): void {
  if (sasUrlCache.size >= SAS_CACHE_MAX_ENTRIES) {
    const dropCount = Math.floor(SAS_CACHE_MAX_ENTRIES * 0.2);
    const it = sasUrlCache.keys();
    for (let i = 0; i < dropCount; i++) {
      const next = it.next();
      if (next.done) break;
      sasUrlCache.delete(next.value as string);
    }
  }
  sasUrlCache.set(key, { url, expiresAt: Date.now() + SAS_CACHE_TTL_MS });
}

export async function ensureSignedAzureUrl(url: string, env: ApiEnv): Promise<string> {
  if (!url || !env.AZURE_STORAGE_CONTAINER) return url;
  // Already signed
  if (url.includes('sig=')) return url;
  // Only sign Azure blob URLs
  if (!url.includes('.blob.core.windows.net/')) return url;

  const publicThumbContainer = (env.AZURE_THUMBNAILS_CONTAINER || '').trim();
  if (publicThumbContainer && extractBlobNameFromUrl(url, publicThumbContainer)) return url;

  const blobName = extractBlobNameFromUrl(url, env.AZURE_STORAGE_CONTAINER);
  if (!blobName) return url;

  const cacheKey = `${env.AZURE_STORAGE_CONTAINER}/${blobName}`;
  const cached = getCachedSasUrl(cacheKey);
  if (cached) return cached;

  const sas = await generateAzureSasForBlobName(blobName, env, SAS_EXPIRY_MINUTES);
  if (sas) setCachedSasUrl(cacheKey, sas);
  return sas || url;
}

// ============================================================================
// GET /api/v1/auth/me - Get current user info
// ============================================================================
export async function handleAuthMe(
  authResult: AuthResult,
  env: ApiEnv
): Promise<Response> {
  console.log('[handleAuthMe] authResult:', JSON.stringify(authResult));
  
  if (!authResult.authenticated || !authResult.user_id) {
    // Include auth error details in response for debugging
    return new Response(
      JSON.stringify({ 
        error: 'Unauthorized',
        debug: {
          authenticated: authResult.authenticated,
          has_user_id: !!authResult.user_id,
          auth_error: authResult.error,
          auth_method: authResult.auth_method
        }
      }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  // For JWT auth, we already have the user info from the token
  // For API key auth, we looked up the user_id
  const response = {
    user_id: authResult.user_id,
    email: authResult.email || null,
    name: authResult.name || null,  // User's name from Google OAuth
    is_admin: false, // TODO: Check admin status if needed
    auth_method: authResult.auth_method,
    scopes: ['read', 'write'], // Default scopes
  };
  
  return new Response(
    JSON.stringify(response),
    { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

// ============================================================================
// GET /api/v1/auth/api-keys - List API keys
// ============================================================================
export async function handleListApiKeys(
  authResult: AuthResult,
  env: ApiEnv
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  const { data, error } = await supabaseQuery(env, 'user_api_keys', {
    select: 'id,key_prefix,name,created_at,last_used_at,expires_at,is_active,scopes',
    filters: { 'user_id': `eq.${authResult.user_id}` },
    order: { column: 'created_at', ascending: false },
  });
  
  if (error) {
    return new Response(
      JSON.stringify({ error }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  return new Response(
    JSON.stringify(data || []),
    { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

// ============================================================================
// POST /api/v1/auth/api-keys - Create API key
// ============================================================================
function generateApiKey(): { fullKey: string; hashedKey: string; keyPrefix: string } {
  // Generate random bytes and convert to base64url
  const randomBytes = new Uint8Array(32);
  crypto.getRandomValues(randomBytes);
  const randomPart = btoa(String.fromCharCode(...randomBytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  
  const fullKey = `na_${randomPart}`;
  const keyPrefix = fullKey.slice(0, 11); // "na_" + first 8 chars
  
  // Hash the key using SHA-256
  const encoder = new TextEncoder();
  const data = encoder.encode(fullKey);
  
  // Use sync approach with SubtleCrypto
  return { fullKey, hashedKey: '', keyPrefix }; // We'll hash async below
}

async function hashApiKey(apiKey: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(apiKey);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

export async function handleCreateApiKey(
  request: Request,
  authResult: AuthResult,
  env: ApiEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  let body: { name?: string; scopes?: string[]; expires_in_days?: number };
  try {
    body = await request.json();
  } catch {
    return new Response(
      JSON.stringify({ error: 'Invalid JSON body' }),
      { status: 400, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  if (!body.name || body.name.length === 0) {
    return new Response(
      JSON.stringify({ error: 'name is required' }),
      { status: 400, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  // Generate API key
  const randomBytes = new Uint8Array(32);
  crypto.getRandomValues(randomBytes);
  const randomPart = btoa(String.fromCharCode(...randomBytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  const fullKey = `na_${randomPart}`;
  const keyPrefix = fullKey.slice(0, 11);
  const hashedKey = await hashApiKey(fullKey);
  
  // Calculate expiration
  let expiresAt: string | null = null;
  if (body.expires_in_days) {
    const expiry = new Date();
    expiry.setDate(expiry.getDate() + body.expires_in_days);
    expiresAt = expiry.toISOString();
  }
  
  const scopes = body.scopes || ['read', 'write'];
  
  // Insert into database
  const record = {
    user_id: authResult.user_id,
    api_key: hashedKey,
    key_prefix: keyPrefix,
    name: body.name,
    scopes: scopes,
    is_active: true,
    expires_at: expiresAt,
  };
  
  const { data, error } = await supabaseQuery(env, 'user_api_keys', {
    method: 'POST',
    body: record,
    single: true,
  });
  
  if (error || !data || data.length === 0) {
    return new Response(
      JSON.stringify({ error: error || 'Failed to create API key' }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  const keyRecord = data[0];

  // Audit: API key minted. Capture id + name + scopes, never the secret.
  logAudit(env, ctx, request, {
    event_type: 'auth.api_key_created',
    user_id: authResult.user_id!,
    actor_email: authResult.email ?? null,
    resource_type: 'api_key',
    resource_id: String(keyRecord.id),
    details: { name: body.name, scopes, expires_at: expiresAt, key_prefix: keyPrefix },
  });

  return new Response(
    JSON.stringify({
      api_key: fullKey, // Only returned once!
      key_info: {
        id: keyRecord.id,
        key_prefix: keyRecord.key_prefix,
        name: keyRecord.name,
        scopes: keyRecord.scopes,
        is_active: keyRecord.is_active,
        created_at: keyRecord.created_at,
        last_used_at: keyRecord.last_used_at,
        expires_at: keyRecord.expires_at,
      },
    }),
    { status: 201, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

// ============================================================================
// DELETE /api/v1/auth/api-keys/:id - Delete API key
// ============================================================================
export async function handleDeleteApiKey(
  keyId: string,
  authResult: AuthResult,
  env: ApiEnv,
  ctx: ExecutionContext,
  request: Request,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  // Delete the key (only if owned by user)
  const url = `${env.SUPABASE_URL}/rest/v1/user_api_keys?id=eq.${keyId}&user_id=eq.${authResult.user_id}`;
  
  const response = await fetch(url, {
    method: 'DELETE',
    headers: {
      'apikey': env.SUPABASE_SERVICE_KEY,
      'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      'Prefer': 'return=representation',
    },
  });
  
  if (!response.ok) {
    return new Response(
      JSON.stringify({ error: 'Failed to delete API key' }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  const deleted = await response.json() as unknown[];
  if (!deleted || deleted.length === 0) {
    return new Response(
      JSON.stringify({ error: 'API key not found' }),
      { status: 404, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }

  // Audit: API key deleted.
  logAudit(env, ctx, request, {
    event_type: 'auth.api_key_deleted',
    user_id: authResult.user_id!,
    actor_email: authResult.email ?? null,
    resource_type: 'api_key',
    resource_id: keyId,
  });

  return new Response(
    JSON.stringify({ message: 'API key deleted successfully' }),
    { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

// ============================================================================
// POST /api/v1/auth/revoke-all-sessions - Sign out from all devices
// Revokes all Supabase sessions and deletes all API keys for the user
// ============================================================================
export async function handleRevokeAllSessions(
  authResult: AuthResult,
  env: ApiEnv,
  ctx: ExecutionContext,
  request: Request,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  const userId = authResult.user_id;
  
  try {
    // 1. Revoke all Supabase sessions by deleting from auth.sessions
    // Use RPC function to delete sessions (since we can't access auth schema directly)
    const logoutResponse = await fetch(
      `${env.SUPABASE_URL}/rest/v1/rpc/revoke_user_sessions`,
      {
        method: 'POST',
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ p_user_id: userId }),
      }
    );
    
    if (!logoutResponse.ok) {
      const errorText = await logoutResponse.text();
      console.error('Failed to revoke Supabase sessions:', logoutResponse.status, errorText);
      // Continue anyway - we still want to delete API keys
    } else {
      console.log('Successfully revoked all sessions for user:', userId);
    }
    
    // 2. Delete all API keys for this user
    const deleteKeysResponse = await fetch(
      `${env.SUPABASE_URL}/rest/v1/user_api_keys?user_id=eq.${userId}`,
      {
        method: 'DELETE',
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          'Prefer': 'return=representation',
        },
      }
    );
    
    if (!deleteKeysResponse.ok) {
      console.error('Failed to delete API keys:', await deleteKeysResponse.text());
    }
    
    const deletedKeys: unknown[] = deleteKeysResponse.ok ? await deleteKeysResponse.json() : [];

    const keysDeletedCount = Array.isArray(deletedKeys) ? deletedKeys.length : 0;
    // Audit: signed out of every device + wiped every API key. High-signal
    // security event — always log.
    logAudit(env, ctx, request, {
      event_type: 'auth.session_revoked',
      user_id: userId,
      actor_email: authResult.email ?? null,
      resource_type: 'user',
      resource_id: userId,
      details: { api_keys_deleted: keysDeletedCount },
    });

    return new Response(
      JSON.stringify({
        message: 'All sessions revoked successfully',
        api_keys_deleted: keysDeletedCount,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (error) {
    console.error('Error revoking sessions:', error);
    return new Response(
      JSON.stringify({ error: 'Failed to revoke sessions' }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/notes/ - List notes
// ============================================================================
export async function handleListNotes(
  request: Request,
  authResult: AuthResult,
  env: ApiEnv
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  const url = new URL(request.url);
  const tag = url.searchParams.get('tag');
  const fileType = url.searchParams.get('file_type');
  const search = url.searchParams.get('search');
  const sortBy = url.searchParams.get('sort'); // 'tag' for alphabetical tag sorting

  // Limit guardrail: clamp to [1, 200] so a missing/oversized limit can never
  // dump the whole table. The Flutter app currently uses a page size of ~20.
  const MAX_PAGE_SIZE = 200;
  const DEFAULT_PAGE_SIZE = 20;
  const rawLimit = parseInt(url.searchParams.get('limit') || String(DEFAULT_PAGE_SIZE), 10);
  const limit = Math.min(Math.max(Number.isFinite(rawLimit) ? rawLimit : DEFAULT_PAGE_SIZE, 1), MAX_PAGE_SIZE);
  const rawOffset = parseInt(url.searchParams.get('offset') || '0', 10);
  const offset = Math.max(Number.isFinite(rawOffset) ? rawOffset : 0, 0);

  // Build Supabase REST URL directly for search support
  // Include content_markdown for quick note previews (it's text, not heavy like embeddings)
  // Exclude: embedding, content_tsv
  // Note: source_url, source_domain, word_count, thumbnail_url are in metadata, not top-level columns
  const baseSelectFields = 'id,user_id,title,short_title,category,tag,file_type,original_filename,blob_url,content_markdown,metadata,created_at,updated_at,status,description';
  const fallbackSelectFields = 'id,user_id,title,tag,file_type,original_filename,blob_url,content_markdown,metadata,created_at,updated_at,status,description';

  // Tag-sort fast path: when the caller wants alphabetical-by-tag and is not
  // combining it with another filter, route through the list_notes_sorted_by_tag
  // RPC. The RPC sorts by lower(tag) and paginates inside Postgres, backed by
  // idx_notes_user_active_tag_lower_created (migration 048). This avoids the
  // legacy code path that fetched up to 10,000 rows per page and sorted in JS.
  const useTagSortRpc = sortBy === 'tag' && !tag && !fileType && !search;

  let apiUrl: string;
  let rpcRequestInit: RequestInit | null = null;

  if (useTagSortRpc) {
    apiUrl = `${env.SUPABASE_URL}/rest/v1/rpc/list_notes_sorted_by_tag?select=${baseSelectFields}`;
    rpcRequestInit = {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
      body: JSON.stringify({
        p_user_id: authResult.user_id,
        p_limit: limit,
        p_offset: offset,
      }),
    };
  } else {
    apiUrl = `${env.SUPABASE_URL}/rest/v1/notes?select=${baseSelectFields}`;
    apiUrl += `&user_id=eq.${authResult.user_id}`;
    apiUrl += `&status=in.(active,incomplete)`; // Show active + still-processing notes; failed/cancelled rows are cleaned up
    if (tag) apiUrl += `&tag=eq.${encodeURIComponent(tag)}`;
    if (fileType) apiUrl += `&file_type=eq.${encodeURIComponent(fileType)}`;

    // Add search filter (searches title and content_markdown)
    if (search) {
      const searchTerm = search.trim();
      // Use Supabase's or filter with ilike for case-insensitive partial match
      // Note: The * wildcards should NOT be encoded, only the search term itself
      const encodedTerm = encodeURIComponent(searchTerm);
      apiUrl += `&or=(title.ilike.*${encodedTerm}*,content_markdown.ilike.*${encodedTerm}*)`;
    }

    // Default: sort by created_at descending (most recent first)
    apiUrl += `&order=created_at.desc`;
    apiUrl += `&limit=${limit}`;
    apiUrl += `&offset=${offset}`;
  }
  
  try {
    console.log('[ListNotes] User ID:', authResult.user_id);
    console.log('[ListNotes] Query URL:', apiUrl.replace(env.SUPABASE_URL, 'SUPABASE_URL'));
    console.log('[ListNotes] Mode:', useTagSortRpc ? 'tag-sort RPC' : 'date-sort REST', 'limit:', limit, 'offset:', offset);

    const initialRequestInit: RequestInit = rpcRequestInit ?? {
      method: 'GET',
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    };

    let response = await fetch(apiUrl, initialRequestInit);

    if (!response.ok) {
      const firstError = await response.text();
      const missingShortTitleColumn =
        firstError.includes('short_title') &&
        (firstError.includes('column') || firstError.includes('schema cache'));
      const missingCategoryColumn =
        firstError.includes('category') &&
        (firstError.includes('column') || firstError.includes('schema cache'));

      if (missingShortTitleColumn || missingCategoryColumn) {
        const fallbackApiUrl = apiUrl.replace(`select=${baseSelectFields}`, `select=${fallbackSelectFields}`);
        response = await fetch(fallbackApiUrl, initialRequestInit);
      } else {
        console.log('[ListNotes] Error response:', response.status, firstError);
        return new Response(
          JSON.stringify({ error: `Supabase error: ${response.status} - ${firstError}` }),
          { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
        );
      }
    }
    
    if (!response.ok) {
      const text = await response.text();
      console.log('[ListNotes] Error response:', response.status, text);
      return new Response(
        JSON.stringify({ error: `Supabase error: ${response.status} - ${text}` }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    let data = await response.json() as any[];
    console.log('[ListNotes] Result count:', data?.length || 0);

    // Tag-sort + pagination both happen in Postgres now (list_notes_sorted_by_tag
    // RPC, migration 048). No worker-side sorting needed.
    
    // Compute thumbnail_url for each note.
    // Storage blob URLs (Azure/Supabase) are opaque UUIDs with no extension,
    // so we check original_filename for the image type, not the URL path.
    const imageExts = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp', '.svg'];
    const notesWithThumbnails = await Promise.all((data || []).map(async (note: any) => {
      const fileType: string = note.file_type || '';
      const blobUrl: string = note.blob_url || '';
      const origName: string = (note.original_filename || '').toLowerCase();
      const metadata = note.metadata || {};
      const shortTitle =
        (typeof note.short_title === 'string' && note.short_title.trim().length > 0)
          ? note.short_title.trim()
          : (typeof metadata.short_title === 'string' && metadata.short_title.trim().length > 0)
            ? metadata.short_title.trim()
            : null;
      let thumbnailUrl: string | null = null;

      // Prefer dedicated optimized thumbnail if available.
      if (typeof metadata.thumbnail_url === 'string' && metadata.thumbnail_url.trim().length > 0) {
        thumbnailUrl = metadata.thumbnail_url;
      }

      if ((fileType === 'screenshot' || fileType === 'image') && blobUrl) {
        // Screenshots and image uploads are themselves the thumbnail source
        thumbnailUrl = thumbnailUrl || blobUrl;
      } else if (fileType === 'uploaded_file' && blobUrl) {
        // Legacy/residual uploads: detect image via filename extension
        // (blob URL is an opaque UUID, not useful)
        if (imageExts.some(ext => origName.endsWith(ext))) {
          thumbnailUrl = thumbnailUrl || blobUrl;
        }
      }

      // Ensure private Azure blob URLs are SAS-signed for direct image loading in mobile app.
      if (thumbnailUrl) {
        thumbnailUrl = await ensureSignedAzureUrl(thumbnailUrl, env);
      }

      const computedPreview =
        (typeof note.description === 'string' && note.description.trim().length > 0)
          ? note.description
          : (typeof metadata.content_preview === 'string' && metadata.content_preview.trim().length > 0)
            ? metadata.content_preview
            : (typeof metadata.excerpt === 'string' && metadata.excerpt.trim().length > 0)
              ? metadata.excerpt
              : null;

      return { ...note, short_title: shortTitle, thumbnail_url: thumbnailUrl, content_preview: computedPreview };
    }));

    return new Response(
      JSON.stringify({ notes: notesWithThumbnails, hasMore: (notesWithThumbnails.length) >= limit }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ error: String(e) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/notes/:id/highlights - AI bullet highlights for a note
// ============================================================================
export async function handleNoteHighlights(
  noteId: string,
  authResult: AuthResult,
  env: ApiEnv
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }

  // Fetch note content from Supabase
  const noteUrl = `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${authResult.user_id}&select=id,file_type,original_filename,description,content_markdown,metadata&limit=1`;
  const noteResp = await fetch(noteUrl, {
    headers: {
      'apikey': env.SUPABASE_SERVICE_KEY,
      'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
    },
  });

  if (!noteResp.ok) {
    return new Response(JSON.stringify({ highlights: [] }), { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } });
  }

  const notes = await noteResp.json() as any[];
  if (!notes || notes.length === 0) {
    return new Response(JSON.stringify({ highlights: [] }), { status: 404, headers: { 'Content-Type': 'application/json', ...corsHeaders } });
  }

  const note = notes[0];
  const metadata = (note.metadata && typeof note.metadata === 'object') ? note.metadata : {};

  // Fast path: highlights were pre-computed at upload time. Return them
  // without any LLM call so opening a snap is instant and free.
  const cached = metadata.highlights;
  if (Array.isArray(cached) && cached.length > 0) {
    const cleaned = cached
      .map((s: unknown) => (typeof s === 'string' ? s.trim() : ''))
      .filter((s: string) => s.length > 0);
    if (cleaned.length > 0) {
      return new Response(
        JSON.stringify({ highlights: cleaned, source: 'cache' }),
        { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
  }

  const fileType = (note.file_type || '').toString();
  const originalFilename = (note.original_filename || '').toString().toLowerCase();
  const isImageNote = fileType === 'screenshot' || fileType === 'image' ||
    ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp', '.svg'].some((ext) => originalFilename.endsWith(ext));

  // Prioritize content_markdown (the full note body) over description (brief caption).
  // For screenshots and image notes, this usually contains OCR or extracted text.
  const content: string = (note.content_markdown || note.description || '').trim();

  if (!content) {
    return new Response(JSON.stringify({ highlights: [] }), { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } });
  }

  // If the stored content is very short, return it as-is instead of asking the
  // model to invent additional details.
  if (content.length < 120) {
    return new Response(
      JSON.stringify({ highlights: [content] }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }

  /** Helper: persist freshly-generated bullets onto metadata.highlights so the
   *  next open is served from cache without burning another LLM call. */
  const persist = async (bullets: string[]) => {
    if (!bullets || bullets.length === 0) return;
    try {
      const nextMetadata = { ...metadata, highlights: bullets };
      await fetch(
        `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${authResult.user_id}`,
        {
          method: 'PATCH',
          headers: {
            'Content-Type': 'application/json',
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
            'Prefer': 'return=minimal',
          },
          body: JSON.stringify({ metadata: nextMetadata }),
        }
      );
    } catch (_) { /* best-effort cache write */ }
  };

  // Try Groq for AI-generated bullets
  if (env.GROQ_API_KEY) {
    try {
      const groqResp = await fetch('https://api.groq.com/openai/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${env.GROQ_API_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          // Groq's openai/gpt-oss-120b has a 131k-token context window, so
          // we can feed it the full long-form note (transcripts, articles,
          // etc.) instead of the previous 6000-char window which lost most
          // of the content. We cap at ~400k chars (~100k tokens) to leave
          // headroom for the prompt + completion within the model context.
          model: 'openai/gpt-oss-120b',
          messages: [
            {
              role: 'system',
              content: 'You are an extractive highlighter. Use only facts explicitly stated in the source text. Do not infer, generalize, or invent anything. Preserve names, organizations, dates, roles, and numbers exactly when present.',
            },
            {
              role: 'user',
              content: `Extract ${isImageNote ? '6 to 8' : '3 to 5'} distinct highlights from the text below. Keep each line specific and information-dense. Avoid generic restatements such as "X mentions Y" or duplicated ideas. Output only the highlights, one per line, with no bullets, numbers, or markdown.\n\nText:\n${content.slice(0, 400000)}`,
            },
          ],
          max_tokens: 800,
          temperature: 0,
        }),
      });

      if (groqResp.ok) {
        const groqData = await groqResp.json() as any;
        const raw: string = groqData?.choices?.[0]?.message?.content || '';
        const bullets = raw.split('\n')
          .map((l: string) => l.replace(/^[•\-*\d.]+\s*/, '').trim())
          .filter((l: string) => l.length > 12)
          .slice(0, isImageNote ? 8 : 5);
        if (bullets.length > 0) {
          await persist(bullets);
          return new Response(JSON.stringify({ highlights: bullets, source: 'fresh' }), { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } });
        }
      }
    } catch (_) { /* fall through to sentence splitting */ }
  }

  // Fallback: split into sentences
  const sentences = content.split(/(?<=[.!?])\s+/)
    .map((s: string) => s.trim())
    .filter((s: string) => s.length > 20)
    .slice(0, 5);
  await persist(sentences);
  return new Response(JSON.stringify({ highlights: sentences, source: 'fallback' }), { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } });
}

// ============================================================================
// POST /api/v1/notes/:id/instagram-preview/refresh
// Refresh display-only Instagram oEmbed thumbnail URL for expired CDN links.
// ============================================================================
export async function handleRefreshInstagramPreview(
  noteId: string,
  authResult: AuthResult,
  env: ApiEnv
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  const noteResp = await fetch(
    `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${authResult.user_id}&select=id,metadata&limit=1`,
    {
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    }
  );
  if (!noteResp.ok) {
    return new Response(JSON.stringify({ error: await noteResp.text() }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }
  const rows = await noteResp.json() as Array<Record<string, any>>;
  const note = rows[0];
  if (!note) {
    return new Response(JSON.stringify({ error: 'Note not found' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }
  const metadata = note.metadata || {};
  const social = metadata.social || {};
  if ((social.source_app || social.source || '').toString().toLowerCase() !== 'instagram') {
    return new Response(JSON.stringify({ error: 'Not an Instagram snap' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }
  const sourceUrl = social.source_url || metadata.source_url;
  if (!sourceUrl) {
    return new Response(JSON.stringify({ error: 'Missing Instagram source URL' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  const enrichment = await fetchInstagramLegalEnrichment(String(sourceUrl), {
    accessToken: env.INSTAGRAM_OEMBED_ACCESS_TOKEN || null,
  });
  const nextSocial = {
    ...social,
    ...enrichment.metadata,
    source_app: 'instagram',
    source_url: String(sourceUrl),
  };
  const nextMetadata = {
    ...metadata,
    thumbnail_url: enrichment.thumbnailUrl || metadata.thumbnail_url || null,
    thumbnail_source_url: enrichment.thumbnailUrl || metadata.thumbnail_source_url || null,
    social: nextSocial,
  };

  const patchResp = await fetch(`${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${authResult.user_id}`, {
    method: 'PATCH',
    headers: {
      'Content-Type': 'application/json',
      'apikey': env.SUPABASE_SERVICE_KEY,
      'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      'Prefer': 'return=minimal',
    },
    body: JSON.stringify({ metadata: nextMetadata }),
  });
  if (!patchResp.ok) {
    return new Response(JSON.stringify({ error: await patchResp.text() }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }
  return new Response(JSON.stringify({
    thumbnail_url: enrichment.thumbnailUrl || null,
    metadata_source: enrichment.metadata.metadata_source,
  }), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

// ============================================================================
// GET /api/v1/notes/stats - Get user stats
// ============================================================================
export async function handleNotesStats(
  authResult: AuthResult,
  env: ApiEnv
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  // Get notes count
  const { data: notes, error } = await supabaseQuery(env, 'notes', {
    select: 'id',
    filters: { 'user_id': `eq.${authResult.user_id}` },
  });
  
  if (error) {
    return new Response(
      JSON.stringify({ error }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  const totalNotes = notes?.length || 0;
  
  // Query search_traces for search counts by client_source
  let googleSearchCount = 0;
  let dashboardSearchCount = 0;
  
  try {
    // Count Google searches (client_source = 'google-search')
    const googleResponse = await fetch(
      `${env.SUPABASE_URL}/rest/v1/search_traces?user_id=eq.${authResult.user_id}&client_source=eq.google-search&select=id`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          'Prefer': 'count=exact',
        },
      }
    );
    if (googleResponse.ok) {
      const countHeader = googleResponse.headers.get('content-range');
      if (countHeader) {
        const match = countHeader.match(/\/(\d+)$/);
        if (match) {
          googleSearchCount = parseInt(match[1], 10);
        }
      }
    }
    
    // Count dashboard searches (client_source = 'dashboard')
    const dashboardResponse = await fetch(
      `${env.SUPABASE_URL}/rest/v1/search_traces?user_id=eq.${authResult.user_id}&client_source=eq.dashboard&select=id`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          'Prefer': 'count=exact',
        },
      }
    );
    if (dashboardResponse.ok) {
      const countHeader = dashboardResponse.headers.get('content-range');
      if (countHeader) {
        const match = countHeader.match(/\/(\d+)$/);
        if (match) {
          dashboardSearchCount = parseInt(match[1], 10);
        }
      }
    }
  } catch (err) {
    console.error('Error fetching search counts:', err);
  }
  
  return new Response(
    JSON.stringify({
      total_notes: totalNotes,
      google_searches: googleSearchCount,
      dashboard_searches: dashboardSearchCount,
      total_searches: googleSearchCount + dashboardSearchCount,
    }),
    { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

// ============================================================================
// GET /api/v1/notes/tags/all - Get all tags
// ============================================================================
export async function handleListTags(
  authResult: AuthResult,
  env: ApiEnv
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  // Server-side DISTINCT via RPC (migration 026). Avoids transferring
  // every note's tag column and deduping in JS.
  try {
    const rpcUrl = `${env.SUPABASE_URL}/rest/v1/rpc/list_user_tags`;
    const rpcResp = await fetch(rpcUrl, {
      method: 'POST',
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ p_user_id: authResult.user_id }),
    });

    if (rpcResp.ok) {
      const rows = await rpcResp.json() as Array<{ tag: string }> | null;
      const tags = (rows || []).map(r => r.tag).filter(Boolean);
      return new Response(
        JSON.stringify({ tags, count: tags.length }),
        { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }

    // RPC missing (e.g. migration 026 not yet applied) -> fall through
    // to the legacy in-memory dedup so the endpoint never breaks.
    const rpcErr = await rpcResp.text();
    console.warn(`list_user_tags RPC failed (${rpcResp.status}), falling back: ${rpcErr}`);
  } catch (e) {
    console.warn(`list_user_tags RPC threw, falling back: ${e}`);
  }

  // Legacy fallback: fetch all active tag columns and dedup in JS.
  const { data: notes, error } = await supabaseQuery(env, 'notes', {
    select: 'tag',
    filters: { 'user_id': `eq.${authResult.user_id}`, 'status': 'eq.active' },
  });

  if (error) {
    return new Response(
      JSON.stringify({ error }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }

  const tags = [...new Set((notes || []).map((n: any) => n.tag).filter(Boolean))];

  return new Response(
    JSON.stringify({ tags, count: tags.length }),
    { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

// ============================================================================
// GET /api/v1/notes/:id/view-token - Generate view token
// ============================================================================
export async function handleGetViewToken(
  noteId: string,
  authResult: AuthResult,
  env: ApiEnv & { WORKER_URL?: string }
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  // Verify user owns this note, or has access through an active group.
  let { data: notes, error } = await supabaseQuery(env, 'notes', {
    select: 'id,blob_url',
    filters: {
      'id': `eq.${noteId}`,
      'user_id': `eq.${authResult.user_id}`,
    },
  });

  if (!error && (!notes || notes.length === 0)) {
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
        `${env.SUPABASE_URL}/rest/v1/group_members?group_id=in.(${groupIds})&user_id=eq.${authResult.user_id}&status=eq.active&select=id&limit=1`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        },
      );
      const memberRows = memberResp.ok ? await memberResp.json() as unknown[] : [];
      if (memberRows.length > 0) {
        const noteResp = await fetch(
          `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&select=id,blob_url&limit=1`,
          {
            headers: {
              'apikey': env.SUPABASE_SERVICE_KEY,
              'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
            },
          },
        );
        notes = noteResp.ok ? await noteResp.json() : [];
      }
    }
  }
  
  if (error || !notes || notes.length === 0) {
    return new Response(
      JSON.stringify({ error: 'Note not found' }),
      { status: 404, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  // Generate token (24 hours expiry)
  const expiryMinutes = 24 * 60;
  const expiryTs = Math.floor(Date.now() / 1000) + (expiryMinutes * 60);
  const message = `${noteId}:${authResult.user_id}:${expiryTs}`;
  
  // Sign with SUPABASE_SERVICE_KEY using HMAC-SHA256
  // IMPORTANT: Must use SERVICE_KEY to match verifyViewToken in index.ts and generateViewToken in rag-search.ts
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(env.SUPABASE_SERVICE_KEY),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const signatureBuffer = await crypto.subtle.sign('HMAC', key, encoder.encode(message));
  const signature = Array.from(new Uint8Array(signatureBuffer))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
    .slice(0, 16);
  
  const token = `${message}:${signature}`;
  
  // Build absolute URL to the Worker's note view endpoint
  const workerUrl = 'https://notesapp-vector-search.monocle0712.workers.dev';
  
  return new Response(
    JSON.stringify({
      token,
      view_url: `${workerUrl}/notes/${noteId}/view?token=${encodeURIComponent(token)}`,
      expires_in_seconds: expiryMinutes * 60,
    }),
    { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

// ============================================================================
// POST /api/v1/notes/:id/recreate - Recreate a quick note from edited content
// Quick-note only: create new note first, then delete old note
// ============================================================================
export async function handleRecreateQuickNote(
  request: Request,
  noteId: string,
  authResult: AuthResult,
  env: ApiEnvWithVectorize
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }

  const userId = authResult.user_id;
  let body: { content?: string; title?: string; tag?: string; description?: string };

  try {
    body = await request.json();
  } catch {
    return new Response(
      JSON.stringify({ error: 'Invalid JSON body' }),
      { status: 400, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }

  const editedContent = (body.content || '').trim();
  if (!editedContent) {
    return new Response(
      JSON.stringify({ error: 'content is required' }),
      { status: 400, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }

  const traceId = `ut_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
  const requestReceivedAt = new Date().toISOString();
  const operationStart = Date.now();
  let timingEmbeddingMs = 0;
  let timingDbInsertMs = 0;
  let timingVectorizeMs = 0;

  try {
    // Step 1: Fetch existing note and verify ownership
    const noteResponse = await fetch(
      `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${userId}&select=*`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!noteResponse.ok) {
      const errText = await noteResponse.text();
      return new Response(
        JSON.stringify({ error: `Failed to fetch note: ${errText}` }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }

    const notes = await noteResponse.json() as Array<Record<string, any>>;
    if (!notes || notes.length === 0) {
      return new Response(
        JSON.stringify({ error: 'Note not found or not owned by user' }),
        { status: 404, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }

    const oldNote = notes[0];
    if (oldNote.file_type !== 'quick_note') {
      return new Response(
        JSON.stringify({ error: 'Only quick_note is supported for recreate edit' }),
        { status: 409, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }

    // Step 2: Build content metadata and embeddings for the new note
    const title = (body.title || '').trim()
      || (oldNote.title || '').trim()
      || editedContent.split('\n')[0].slice(0, 120)
      || 'Quick Note';
    const tag = (body.tag || '').trim() || oldNote.tag || 'General';
    const description = (body.description || '').trim() || oldNote.description || null;

    const searchableContent = withSearchDescription(editedContent, description);
    const chunks = chunkText(searchableContent);
    const safeChunks = chunks.length > 0 ? chunks : [editedContent];

    const summary = searchableContent.split(/\s+/).slice(0, 1000).join(' ');
    const docSummary = `${title}\n\n${summary}`;
    const textsToEmbed = [docSummary, ...safeChunks];

    const embeddingStart = Date.now();
    const embeddingResponse = await env.AI.run(env.EMBEDDING_MODEL as any, {
      text: textsToEmbed,
    });
    timingEmbeddingMs = Date.now() - embeddingStart;
    const embeddings = (embeddingResponse as any)?.data as number[][];

    if (!Array.isArray(embeddings) || embeddings.length < safeChunks.length + 1) {
      return new Response(
        JSON.stringify({ error: 'Embedding generation returned unexpected shape' }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }

    // Step 3: Create new note first (safer than delete-first)
    const nowIso = new Date().toISOString();
    const newNoteData = {
      user_id: userId,
      title,
      description,
      content_markdown: editedContent,
      tag,
      file_type: 'quick_note',
      original_filename: oldNote.original_filename || null,
      blob_url: null,
      embedding: `[${embeddings[0].join(',')}]`,
      status: 'active',
      metadata: {
        ...(oldNote.metadata || {}),
        chunk_count: safeChunks.length,
        size_bytes: editedContent.length,
        recreated_from_note_id: noteId,
        recreated_at: nowIso,
        upload_source: 'worker_recreate',
      },
    };

    const dbInsertStart = Date.now();
    const insertResp = await fetch(`${env.SUPABASE_URL}/rest/v1/notes`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        'Prefer': 'return=representation',
      },
      body: JSON.stringify(newNoteData),
    });
    timingDbInsertMs = Date.now() - dbInsertStart;

    if (!insertResp.ok) {
      const errText = await insertResp.text();
      return new Response(
        JSON.stringify({ error: `Failed to create replacement note: ${errText}` }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }

    const inserted = await insertResp.json() as Array<Record<string, any>>;
    const newNote = inserted[0];
    const newNoteId = String(newNote.id);

    // Step 4: Upsert vectors for the new note
    const shortHash = (s: string): string => {
      let h = 0;
      for (let i = 0; i < s.length; i++) {
        h = ((h << 5) - h + s.charCodeAt(i)) | 0;
      }
      return (h >>> 0).toString(36).padStart(6, '0').slice(0, 6);
    };

    const vectors: VectorizeVector[] = [];
    // NOTE: `title` is intentionally NOT stored in vector metadata. Canonical
    // title lives in `notes.title` and is joined at search-result time.
    const docId = `${newNoteId}_doc`;
    vectors.push({
      id: docId,
      values: embeddings[0],
      metadata: {
        chunk_id: shortHash(docId),
        note_id: newNoteId,
        user_id: userId,
        tag,
        chunk_type: 'document',
        chunk_index: 0,
        content_preview: summary,
        description: description || '',
      } as Record<string, VectorizeVectorMetadata>,
    });

    for (let i = 0; i < safeChunks.length; i++) {
      const chunkId = `${newNoteId}_chunk_${i}`;
      vectors.push({
        id: chunkId,
        values: embeddings[i + 1],
        metadata: {
          chunk_id: shortHash(chunkId),
          note_id: newNoteId,
          user_id: userId,
          tag,
          chunk_type: 'chunk',
          chunk_index: i,
          chunk_text: safeChunks[i].substring(0, 500),
        } as Record<string, VectorizeVectorMetadata>,
      });
    }

    const vectorizeStart = Date.now();
    for (let i = 0; i < vectors.length; i += 1000) {
      await env.VECTORIZE.upsert(vectors.slice(i, i + 1000));
    }
    timingVectorizeMs = Date.now() - vectorizeStart;

    // Step 5: Insert note_chunks for chunk-level keyword search
    const chunkRows = safeChunks.map((content: string, i: number) => ({
      note_id: newNoteId,
      chunk_index: i,
      content,
      user_id: userId,
      tag,
    }));

    const chunkInsertResp = await fetch(`${env.SUPABASE_URL}/rest/v1/note_chunks`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        'Prefer': 'return=minimal',
      },
      body: JSON.stringify(chunkRows),
    });

    if (!chunkInsertResp.ok) {
      const errText = await chunkInsertResp.text();
      return new Response(
        JSON.stringify({
          error: `Replacement note created, but note_chunks insert failed: ${errText}`,
          old_note_id: noteId,
          new_note_id: newNoteId,
        }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }

    // Step 6: Delete old note and old vectors (best effort after successful create)
    const oldChunkCount = oldNote.metadata?.chunk_count || 0;
    const oldVectorIds = [noteId, `${noteId}_doc`];
    for (let i = 0; i < oldChunkCount; i++) {
      oldVectorIds.push(`${noteId}_chunk_${i}`);
    }

    // Delete DB row first to make old note disappear from user list immediately
    const oldDeleteResp = await fetch(
      `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${userId}`,
      {
        method: 'DELETE',
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!oldDeleteResp.ok) {
      const errText = await oldDeleteResp.text();
      return new Response(
        JSON.stringify({
          error: `Replacement note created, but old note deletion failed: ${errText}`,
          old_note_id: noteId,
          new_note_id: newNoteId,
        }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }

    try {
      await env.VECTORIZE.deleteByIds(oldVectorIds);
    } catch (vecErr) {
      console.error(`[Recreate] Failed to delete old vectors for ${noteId} (non-fatal): ${vecErr}`);
    }

    if (oldNote.blob_url) {
      try {
        const blobResult = await deleteAzureBlob(oldNote.blob_url, env);
        if (!blobResult.success) {
          console.error(`[Recreate] Failed to delete old blob for ${noteId} (non-fatal): ${blobResult.error}`);
        }
      } catch (blobErr) {
        console.error(`[Recreate] Failed to delete old blob for ${noteId} (non-fatal): ${blobErr}`);
      }
    }

    // Step 7: Invalidate caches
    try {
      if ('SEARCH_CACHE' in env) {
        await (env as any).SEARCH_CACHE.put(`version_${userId}`, Date.now().toString());
      }
      if ('TAGS_CACHE' in env) {
        await (env as any).TAGS_CACHE.delete(`tags_${userId}`);
      }
    } catch (cacheErr) {
      console.error(`[Recreate] Cache invalidation failed (non-fatal): ${cacheErr}`);
    }

    // Best-effort trace insert so edited quick notes show up in activity logs.
    try {
      const completedAt = new Date().toISOString();
      await fetch(`${env.SUPABASE_URL}/rest/v1/upload_traces`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          'Prefer': 'return=minimal',
        },
        body: JSON.stringify({
          trace_id: traceId,
          user_id: userId,
          upload_type: 'quick_note',
          original_filename: title,
          file_type: 'text/markdown',
          file_size_bytes: editedContent.length,
          tag,
          description,
          status: 'completed',
          current_step: 'finalize',
          request_received_at: requestReceivedAt,
          processing_started_at: requestReceivedAt,
          completed_at: completedAt,
          timing_total_ms: Date.now() - operationStart,
          timing_embedding_ms: timingEmbeddingMs,
          timing_db_insert_ms: timingDbInsertMs,
          timing_vectorize_ms: timingVectorizeMs,
          note_id: newNoteId,
          title_generated: title,
          chunk_count: safeChunks.length,
          vector_count: vectors.length,
          conversion_method: 'direct',
          auth_method: authResult.auth_method,
          pipeline_errors: [],
        }),
      });
    } catch (traceErr) {
      console.error(`[Recreate] Failed to insert upload trace (non-fatal): ${traceErr}`);
    }

    return new Response(
      JSON.stringify({
        success: true,
        old_note_id: noteId,
        new_note_id: newNoteId,
        trace_id: traceId,
        note: newNote,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (error) {
    return new Response(
      JSON.stringify({ error: `Internal server error: ${error}` }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// DELETE /api/v1/notes/:id - Delete a note (hard delete)
// Removes note from database, Azure blob, and Vectorize
// ============================================================================
export async function handleDeleteNote(
  noteId: string,
  authResult: AuthResult,
  env: ApiEnvWithVectorize,
  ctx: ExecutionContext,
  request: Request,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  const userId = authResult.user_id;
  console.log(`[Delete] Starting delete for note ${noteId} by user ${userId}`);
  
  try {
    // Step 1: Fetch the note to verify ownership and get data
    const noteResponse = await fetch(
      `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${userId}&select=*`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );
    
    if (!noteResponse.ok) {
      const errText = await noteResponse.text();
      console.error(`[Delete] Failed to fetch note: ${errText}`);
      return new Response(
        JSON.stringify({ error: 'Failed to fetch note' }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    const notes = await noteResponse.json() as Array<Record<string, any>>;
    if (!notes || notes.length === 0) {
      return new Response(
        JSON.stringify({ error: 'Note not found or not owned by user' }),
        { status: 404, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    const note = notes[0];
    const chunkCount = note.metadata?.chunk_count || 0;
    console.log(`[Delete] Found note: ${note.title}, chunks: ${chunkCount}`);
    
    // Step 2: Delete from notes table
    const deleteResponse = await fetch(
      `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${userId}`,
      {
        method: 'DELETE',
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );
    
    if (!deleteResponse.ok) {
      const errText = await deleteResponse.text();
      console.error(`[Delete] Failed to delete from notes: ${errText}`);
      return new Response(
        JSON.stringify({ error: 'Failed to delete note from database' }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    console.log(`[Delete] Deleted note from notes table`);
    
    // Step 3: Delete blob from Azure Storage (if exists)
    if (note.blob_url) {
      try {
        const blobResult = await deleteAzureBlob(note.blob_url, env);
        if (blobResult.success) {
          console.log(`[Delete] Deleted blob from Azure Storage`);
        } else {
          // Log but don't fail - note is already deleted from DB
          console.error(`[Delete] Blob deletion failed (non-fatal): ${blobResult.error}`);
        }
      } catch (blobErr) {
        // Log but don't fail - note is already deleted from DB
        console.error(`[Delete] Blob deletion error (non-fatal): ${blobErr}`);
      }
    }

    const thumbnailUrls = new Set<string>();
    const metadata = note.metadata && typeof note.metadata === 'object' ? note.metadata : {};
    const social = metadata.social && typeof metadata.social === 'object' ? metadata.social : {};
    for (const candidate of [metadata.thumbnail_url, metadata.thumbnail_blob_url, social.thumbnail_url]) {
      if (typeof candidate === 'string' && candidate.includes('.blob.core.windows.net/')) {
        thumbnailUrls.add(candidate);
      }
    }
    thumbnailUrls.delete(note.blob_url);
    for (const thumbUrl of thumbnailUrls) {
      try {
        const thumbResult = await deleteAzureBlob(thumbUrl, env);
        if (thumbResult.success) {
          console.log(`[Delete] Deleted thumbnail blob from Azure Storage`);
        } else {
          console.error(`[Delete] Thumbnail deletion failed (non-fatal): ${thumbResult.error}`);
        }
      } catch (thumbErr) {
        console.error(`[Delete] Thumbnail deletion error (non-fatal): ${thumbErr}`);
      }
    }
    
    // Step 4: Delete vectors from Vectorize
    // Vector IDs: noteId_doc (document) + noteId_chunk_0, noteId_chunk_1, etc. (chunks)
    const vectorIds = [`${noteId}_doc`]; // Document vector
    for (let i = 0; i < chunkCount; i++) {
      vectorIds.push(`${noteId}_chunk_${i}`);
    }
    
    try {
      await env.VECTORIZE.deleteByIds(vectorIds);
      console.log(`[Delete] Deleted ${vectorIds.length} vectors from Vectorize`);
    } catch (vecErr) {
      // Log but don't fail - note is already deleted from DB
      console.error(`[Delete] Vectorize deletion failed (non-fatal): ${vecErr}`);
    }
    
    // Step 5: Invalidate tags cache
    try {
      // If TAGS_CACHE exists, invalidate it
      if ('TAGS_CACHE' in env) {
        await (env as any).TAGS_CACHE.delete(`tags_${userId}`);
        console.log(`[Delete] Invalidated tags cache`);
      }
    } catch (cacheErr) {
      console.error(`[Delete] Cache invalidation failed (non-fatal): ${cacheErr}`);
    }

    // Audit: snap deleted. Title is the only payload to keep details
    // small and useful for "why is this gone?" support.
    logAudit(env, ctx, request, {
      event_type: 'note.delete',
      user_id: userId,
      actor_email: authResult.email ?? null,
      resource_type: 'note',
      resource_id: noteId,
      details: {
        title: typeof note.title === 'string' ? note.title.slice(0, 200) : null,
        file_type: note.file_type ?? null,
        vectors_deleted: vectorIds.length,
      },
    });

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Note deleted successfully',
        note_id: noteId,
        vectors_deleted: vectorIds.length,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
    
  } catch (error) {
    console.error(`[Delete] Unexpected error: ${error}`);
    return new Response(
      JSON.stringify({ error: 'Internal server error' }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// DELETE /api/v1/notes/bulk - Delete multiple notes (soft delete)
// Accepts { ids: string[] } and deletes all specified notes
// ============================================================================
export async function handleBulkDeleteNotes(
  request: Request,
  authResult: AuthResult,
  env: ApiEnvWithVectorize,
  ctx: ExecutionContext,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  const userId = authResult.user_id;
  
  // Parse request body
  let body: { ids?: string[] };
  try {
    body = await request.json();
  } catch {
    return new Response(
      JSON.stringify({ error: 'Invalid JSON body' }),
      { status: 400, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  const noteIds = body.ids;
  if (!noteIds || !Array.isArray(noteIds) || noteIds.length === 0) {
    return new Response(
      JSON.stringify({ error: 'ids array is required and must not be empty' }),
      { status: 400, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  // Limit bulk delete to 100 notes at a time
  if (noteIds.length > 100) {
    return new Response(
      JSON.stringify({ error: 'Cannot delete more than 100 notes at once' }),
      { status: 400, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  console.log(`[BulkDelete] Starting bulk delete of ${noteIds.length} notes by user ${userId}`);
  
  const results: { success: string[]; failed: { id: string; error: string }[] } = {
    success: [],
    failed: [],
  };
  
  // Process all notes in parallel for speed
  const deletePromises = noteIds.map(async (noteId) => {
    try {
      // Validate noteId format
      if (!/^[a-f0-9-]+$/.test(noteId)) {
        return { id: noteId, success: false, error: 'Invalid note ID format' };
      }
      
      // Step 1: Fetch the note to verify ownership and get data
      const noteResponse = await fetch(
        `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${userId}&select=id,user_id,title,content_markdown,tag,file_type,original_filename,blob_url,metadata,created_at`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      );
      
      if (!noteResponse.ok) {
        return { id: noteId, success: false, error: 'Failed to fetch note' };
      }
      
      const notes = await noteResponse.json() as Array<Record<string, any>>;
      if (!notes || notes.length === 0) {
        return { id: noteId, success: false, error: 'Note not found or not owned by user' };
      }
      
      const note = notes[0];
      const chunkCount = note.metadata?.chunk_count || 0;
      
      // Step 2: Delete from notes table
      const deleteResponse = await fetch(
        `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${userId}`,
        {
          method: 'DELETE',
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      );
      
      if (!deleteResponse.ok) {
        return { id: noteId, success: false, error: 'Failed to delete from database' };
      }
      
      // Step 3: Delete blob from Azure Storage (if exists)
      if (note.blob_url) {
        try {
          const blobResult = await deleteAzureBlob(note.blob_url, env);
          if (!blobResult.success) {
            // Log but don't fail - note is already deleted from DB
            console.error(`[BulkDelete] Blob deletion failed for ${noteId} (non-fatal): ${blobResult.error}`);
          }
        } catch (blobErr) {
          // Log but don't fail - note is already deleted from DB
          console.error(`[BulkDelete] Blob deletion error for ${noteId} (non-fatal): ${blobErr}`);
        }
      }
      
      // Step 4: Delete vectors from Vectorize (don't wait for it)
      const vectorIds = [`${noteId}_doc`];
      for (let i = 0; i < chunkCount; i++) {
        vectorIds.push(`${noteId}_chunk_${i}`);
      }
      
      try {
        await env.VECTORIZE.deleteByIds(vectorIds);
      } catch (vecErr) {
        // Log but don't fail - note is already deleted from DB
        console.error(`[BulkDelete] Vectorize deletion failed for ${noteId} (non-fatal): ${vecErr}`);
      }
      
      return { id: noteId, success: true };
      
    } catch (error) {
      console.error(`[BulkDelete] Error deleting note ${noteId}: ${error}`);
      return { id: noteId, success: false, error: 'Internal error' };
    }
  });
  
  // Wait for all deletions to complete
  const deleteResults = await Promise.all(deletePromises);
  
  // Collect results
  for (const result of deleteResults) {
    if (result.success) {
      results.success.push(result.id);
    } else {
      results.failed.push({ id: result.id, error: result.error || 'Unknown error' });
    }
  }
  
  // Invalidate tags cache once at the end
  try {
    if ('TAGS_CACHE' in env) {
      await (env as any).TAGS_CACHE.delete(`tags_${userId}`);
      console.log(`[BulkDelete] Invalidated tags cache`);
    }
  } catch (cacheErr) {
    console.error(`[BulkDelete] Cache invalidation failed (non-fatal): ${cacheErr}`);
  }
  
  console.log(`[BulkDelete] Completed: ${results.success.length} deleted, ${results.failed.length} failed`);

  // Audit: one row per bulk-delete invocation (NOT one per note). The list
  // of IDs is in details so we can still answer "was note X deleted in
  // bulk?" without exploding the table.
  if (results.success.length > 0) {
    logAudit(env, ctx, request, {
      event_type: 'note.bulk_delete',
      user_id: userId,
      actor_email: authResult.email ?? null,
      resource_type: 'note',
      details: {
        deleted_ids: results.success,
        deleted_count: results.success.length,
        failed_count: results.failed.length,
      },
    });
  }

  return new Response(
    JSON.stringify({
      success: true,
      deleted: results.success,
      failed: results.failed,
      total_deleted: results.success.length,
      total_failed: results.failed.length,
    }),
    { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

// ============================================================================
// GET /api/v1/newspaper?days=1 - Generate "The infoSnap Times" daily edition
//
// Pulls the user's notes from the last N days (default 1 = "yesterday"),
// feeds them to Groq with the newspaper prompt, and returns a structured
// NewspaperEdition JSON payload that the Flutter client renders.
// ============================================================================
export async function handleNewspaperEdition(
  request: Request,
  authResult: AuthResult,
  env: ApiEnv
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }

  if (!env.GROQ_API_KEY) {
    return new Response(
      JSON.stringify({ error: 'LLM not configured' }),
      { status: 503, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }

  const url = new URL(request.url);
  const days = Math.max(1, Math.min(parseInt(url.searchParams.get('days') || '1', 10) || 1, 14));

  // Compute cutoff in ISO. Notes are stored with created_at UTC.
  const cutoffDate = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
  const cutoffIso = cutoffDate.toISOString();

  // Fetch recent notes
  const selectFields = 'id,title,short_title,tag,file_type,original_filename,content_markdown,description,metadata,created_at,blob_url';
  const apiUrl =
    `${env.SUPABASE_URL}/rest/v1/notes?select=${selectFields}` +
    `&user_id=eq.${authResult.user_id}` +
    `&status=in.(active,incomplete)` +
    `&created_at=gte.${encodeURIComponent(cutoffIso)}` +
    `&order=created_at.desc&limit=200`;

  let notes: any[] = [];
  try {
    const resp = await fetch(apiUrl, {
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });
    if (!resp.ok) {
      const txt = await resp.text();
      console.log('[Newspaper] Supabase error', resp.status, txt);
      return new Response(JSON.stringify({ error: 'db_error' }), { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } });
    }
    notes = (await resp.json() as any[]) || [];
  } catch (e) {
    console.log('[Newspaper] Fetch failed', String(e));
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } });
  }

  // Empty-state edition (no notes in window)
  if (notes.length === 0) {
    const now = new Date();
    const label = now.toLocaleDateString('en-US', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
    const empty = {
      editionDate: now.toISOString().slice(0, 10),
      editionDateLabel: label,
      issueNumber: 1,
      totalSaves: 0,
      editorsNote:
        days === 1
          ? "No snaps yesterday — the presses are quiet. Save something today and tomorrow's edition will write itself."
          : `No snaps in the last ${days} days — the presses are quiet.`,
      lead: {
        kicker: "EDITOR'S DESK",
        headline: 'A quiet news day.',
        deck: 'Nothing saved in this window. The infoSnap Times will return when you do.',
        byline: 'The Editors',
        paragraphs: [
          'There is no edition today. The newsroom relies entirely on what you save — links, screenshots, quotes, ideas. Without inputs, there is no output.',
          'Tip the typesetters: share a link, snap a screen, jot a thought. By tomorrow morning, this page will be full.',
        ],
      },
      sections: [],
      dayInOneParagraph: 'Quiet.',
      stats: [],
      authorsCited: [],
    };
    return new Response(JSON.stringify(empty), {
      status: 200,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  // Build compact input for the LLM. Truncate long fields to stay within
  // context. Keep enough for the model to write 3-paragraph articles.
  // Cap to the 40 most recent so generation stays within token budget.
  const limited = notes.slice(0, 40);
  const compact = limited.map((n: any) => {
    const meta = n.metadata && typeof n.metadata === 'object' ? n.metadata : {};
    const social = (meta.social && typeof meta.social === 'object') ? meta.social : {};
    const content: string = (n.content_markdown || n.description || '').toString();
    return {
      id: n.id,
      title: n.short_title || n.title || '(untitled)',
      tag: n.tag || null,
      file_type: n.file_type || null,
      source_url: social.source_url || meta.source_url || null,
      source: social.source || null,
      author: social.author || social.uploader || null,
      thumbnail_url: meta.thumbnail_url || social.thumbnail_url || null,
      caption: typeof social.caption === 'string' ? social.caption.slice(0, 500) : null,
      description: typeof n.description === 'string' ? n.description.slice(0, 500) : null,
      content: content.slice(0, 2000),
      highlights: Array.isArray(meta.highlights) ? meta.highlights.slice(0, 5) : [],
      created_at: n.created_at,
    };
  });

  // Edition labels
  const editionForDate = new Date(Date.now() - 24 * 60 * 60 * 1000);
  const editionDate = editionForDate.toISOString().slice(0, 10);
  const editionDateLabel = editionForDate.toLocaleDateString('en-US', {
    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
  });

  const systemPrompt = [
    'You are the editor-in-chief of "The infoSnap Times" — a personal daily newspaper of everything the user saved recently.',
    '',
    'You will receive a JSON array of the user\'s recent notes. Generate ONE NewspaperEdition JSON object matching this exact schema (no extra fields, no markdown):',
    '',
    '{',
    '  "editionDate": "YYYY-MM-DD",',
    '  "editionDateLabel": "Weekday, Month D, YYYY",',
    '  "issueNumber": 1,',
    '  "totalSaves": <int>,',
    '  "editorsNote": "<2-4 sentences, wry observational voice>",',
    '  "lead": {',
    '    "kicker": "<uppercase desk label e.g. TRAVEL DESK>",',
    '    "headline": "<punchy title>",',
    '    "deck": "<one-sentence subheading>",',
    '    "byline": "<e.g. Filed 09:34 · youtube.com>",',
    '    "paragraphs": ["<para1>","<para2>","<para3>"],',
    '    "heroImage": "<thumbnail_url or null>",',
    '    "imageCaption": "<short cap or null>",',
    '    "noteId": "<the source note id>",',
    '    "sourceUrl": "<source_url or null>",',
    '    "sidebar": { "title": "<optional>", "items": ["<bullet>"] }',
    '  },',
    '  "sections": [',
    '    {',
    '      "title": "<Desk name e.g. Tech Desk>",',
    '      "meta": "<e.g. 3 saves · 2 from YouTube>",',
    '      "articles": [',
    '        {',
    '          "headline": "<title>",',
    '          "deck": "<subheading or null>",',
    '          "byline": "<e.g. Filed 14:02 · instagram.com>",',
    '          "featured": false,',
    '          "noteId": "<source note id>",',
    '          "sourceUrl": "<source_url or null>",',
    '          "heroImage": "<thumbnail_url or null>",',
    '          "imageCaption": "<cap or null>",',
    '          "blocks": [',
    '            { "type": "paragraph", "text": "<para>" },',
    '            { "type": "pullQuote", "text": "<quote>", "cite": "<source>" }',
    '          ]',
    '        }',
    '      ]',
    '    }',
    '  ],',
    '  "dayInOneParagraph": "<one-paragraph wrap of the day>",',
    '  "stats": [ { "label": "Total saves", "value": "<n>" } ],',
    '  "authorsCited": [ { "label": "<author>", "count": <n> } ]',
    '}',
    '',
    'Rules:',
    '- Every article MUST include the underlying note id in "noteId" (use the input note "id" field verbatim).',
    '- Use input thumbnail_url for heroImage; null if absent.',
    '- Render real content from caption/description/content into 2-3 paragraph prose per article. Do NOT bullet-summarise. Newspaper voice: wry, observational, NYT Sunday + The Browser.',
    '- Group articles into desks (Travel Desk, Tech Desk, Lifestyle, Careers, Arts & Entertainment, Money, Health) — only desks actually needed. Each desk gets a one-line meta.',
    '- Pick the lead for actionability/timeliness. Avoid entertainment as lead unless nothing else qualifies.',
    '- If two saves share the same source_url or near-identical title, collapse into ONE article and mention the re-save in the editor\'s note.',
    '- Pull at least one quote from a significant article into a pullQuote block when source text supports it.',
    '- Never fabricate facts not in the source notes. If content is missing for a note, say so candidly in that article.',
    '- Block types allowed: "paragraph" (text), "pullQuote" (text, cite), "contradiction" (text, cite), "numberedList" (items: string[]).',
    '- Output ONLY the JSON object. No prose, no markdown, no code fences.',
  ].join('\n');

  const userPrompt = `Edition date: ${editionDate} (${editionDateLabel})
Total notes in window: ${notes.length}
Issue #: 1

INPUT NOTES (JSON):
${JSON.stringify(compact)}`;

  let editionJson: any = null;
  try {
    const groqResp = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${env.GROQ_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'openai/gpt-oss-120b',
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userPrompt },
        ],
        response_format: { type: 'json_object' },
        max_tokens: 32000,
        temperature: 0.5,
      }),
    });

    if (!groqResp.ok) {
      const errTxt = await groqResp.text();
      console.log('[Newspaper] Groq error', groqResp.status, errTxt.slice(0, 500));
      return new Response(JSON.stringify({ error: 'llm_error', detail: errTxt.slice(0, 500) }), {
        status: 502, headers: { 'Content-Type': 'application/json', ...corsHeaders },
      });
    }

    const groqData = await groqResp.json() as any;
    const raw: string = groqData?.choices?.[0]?.message?.content || '';
    try {
      editionJson = JSON.parse(raw);
    } catch (parseErr) {
      const stripped = raw.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '').trim();
      editionJson = JSON.parse(stripped);
    }
  } catch (e) {
    console.log('[Newspaper] Generation failed', String(e));
    return new Response(JSON.stringify({ error: 'generation_failed', detail: String(e) }), {
      status: 502, headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  if (!editionJson || typeof editionJson !== 'object') {
    return new Response(JSON.stringify({ error: 'invalid_llm_output' }), {
      status: 502, headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }
  editionJson.editionDate ||= editionDate;
  editionJson.editionDateLabel ||= editionDateLabel;
  editionJson.issueNumber ||= 1;
  editionJson.totalSaves ||= notes.length;
  editionJson.sections ||= [];
  editionJson.stats ||= [];
  editionJson.authorsCited ||= [];
  editionJson.dayInOneParagraph ||= '';
  editionJson.editorsNote ||= '';

  return new Response(JSON.stringify(editionJson), {
    status: 200,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'private, max-age=300',
      ...corsHeaders,
    },
  });
}
