/**
 * API Endpoints for Cloudflare Worker
 * 
 * Migrated from Fly.io backend to eliminate latency and improve scaling.
 * These endpoints talk directly to Supabase.
 */

import { AuthResult } from './auth';

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
};

export interface ApiEnv {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  SUPABASE_JWT_SECRET: string;
}

// Extended env for endpoints that need VECTORIZE
export interface ApiEnvWithVectorize extends ApiEnv {
  VECTORIZE: Vectorize;
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
  env: ApiEnv
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
  env: ApiEnv
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
  
  const deleted = await response.json();
  if (!deleted || deleted.length === 0) {
    return new Response(
      JSON.stringify({ error: 'API key not found' }),
      { status: 404, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
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
  env: ApiEnv
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
    
    return new Response(
      JSON.stringify({ 
        message: 'All sessions revoked successfully',
        api_keys_deleted: Array.isArray(deletedKeys) ? deletedKeys.length : 0,
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
  const limit = parseInt(url.searchParams.get('limit') || '50');
  const offset = parseInt(url.searchParams.get('offset') || '0');
  
  // Build filters
  const filters: Record<string, string> = {
    'user_id': `eq.${authResult.user_id}`,
  };
  if (tag) filters['tag'] = `eq.${tag}`;
  if (fileType) filters['file_type'] = `eq.${fileType}`;
  
  const { data, error } = await supabaseQuery(env, 'notes', {
    select: '*',
    filters,
    order: { column: 'created_at', ascending: false },
    limit,
    offset,
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
  
  // Get all notes and extract unique tags
  const { data: notes, error } = await supabaseQuery(env, 'notes', {
    select: 'tag',
    filters: { 'user_id': `eq.${authResult.user_id}` },
  });
  
  if (error) {
    return new Response(
      JSON.stringify({ error }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  // Extract unique tags
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
  
  // Verify user owns this note
  const { data: notes, error } = await supabaseQuery(env, 'notes', {
    select: 'id,blob_url',
    filters: {
      'id': `eq.${noteId}`,
      'user_id': `eq.${authResult.user_id}`,
    },
  });
  
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
// DELETE /api/v1/notes/:id - Delete a note (soft delete)
// Moves note to notes_deleted table and removes vectors from Vectorize
// ============================================================================
export async function handleDeleteNote(
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
    
    // Step 2: Insert into notes_deleted (only copy essential columns)
    const deletedNote = {
      original_note_id: note.id,
      user_id: note.user_id,
      title: note.title,
      content_markdown: note.content_markdown,
      tag: note.tag || 'General',
      file_type: note.file_type,
      original_filename: note.original_filename,
      blob_url: note.blob_url,
      status: 'deleted',
      metadata: note.metadata || {},
      created_at: note.created_at,
      deleted_at: new Date().toISOString(),
    };
    
    const insertResponse = await fetch(
      `${env.SUPABASE_URL}/rest/v1/notes_deleted`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          'Prefer': 'return=representation',
        },
        body: JSON.stringify(deletedNote),
      }
    );
    
    if (!insertResponse.ok) {
      const errText = await insertResponse.text();
      console.error(`[Delete] Failed to insert into notes_deleted: ${errText}`);
      return new Response(
        JSON.stringify({ error: 'Failed to archive note' }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    console.log(`[Delete] Archived note to notes_deleted`);
    
    // Step 3: Delete from notes table
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
    
    // Step 4: Delete vectors from Vectorize
    // Vector IDs: noteId (document) + noteId_chunk_0, noteId_chunk_1, etc. (chunks)
    const vectorIds = [noteId]; // Document vector
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
