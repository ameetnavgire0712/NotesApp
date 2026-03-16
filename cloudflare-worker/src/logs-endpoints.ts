/**
 * Logs/Activity Dashboard Endpoints for Cloudflare Worker
 * 
 * These endpoints power the activity logs dashboard, providing
 * access to search traces and user activity data.
 */

import { AuthResult } from './auth';

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
};

// Admin email whitelist
const ADMIN_EMAILS = ['ameet.navgire@gmail.com'];

function isAdmin(authResult: AuthResult): boolean {
  return authResult.authenticated && ADMIN_EMAILS.includes(authResult.email || '');
}

function forbiddenResponse(): Response {
  return new Response(
    JSON.stringify({ error: 'Access denied. Admin privileges required.' }),
    { status: 403, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

function unauthorizedResponse(): Response {
  return new Response(
    JSON.stringify({ error: 'Unauthorized' }),
    { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

export interface LogsEnv {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
}

// ============================================================================
// GET /api/v1/logs/dashboard/users - Get users with recent activity
// ============================================================================
export async function handleDashboardUsers(
  request: Request,
  authResult: AuthResult,
  env: LogsEnv
): Promise<Response> {
  // This is an admin endpoint - require authentication and admin role
  if (!authResult.authenticated) {
    return unauthorizedResponse();
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }
  
  const url = new URL(request.url);
  const hours = parseInt(url.searchParams.get('hours') || '24');
  
  // Calculate timestamp for filtering
  const since = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();
  
  console.log(`[Dashboard Users] hours=${hours}, since=${since}`);
  
  try {
    // Query search_traces and upload_traces for unique users
    const [fallbackResponse, uploadResponse] = await Promise.all([
      fetch(
        `${env.SUPABASE_URL}/rest/v1/search_traces?select=user_id,created_at&created_at=gte.${since}&order=created_at.desc&limit=1000`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      ),
      fetch(
        `${env.SUPABASE_URL}/rest/v1/upload_traces?select=user_id,created_at&created_at=gte.${since}&order=created_at.desc&limit=1000`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      ),
    ]);
    
    console.log(`[Dashboard Users] Supabase response status: ${fallbackResponse.status}`);
    
    if (!fallbackResponse.ok) {
      const errorText = await fallbackResponse.text();
      console.error('[Dashboard Users] Failed to fetch users:', errorText);
      return new Response(
        JSON.stringify({ error: 'Failed to fetch users', detail: errorText }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    const traces = await fallbackResponse.json() as Array<{ user_id: string; created_at: string }>;
    console.log(`[Dashboard Users] Found ${traces.length} search traces`);
    
    // Also include upload traces
    let allTraces = [...traces];
    if (uploadResponse.ok) {
      const uploadTraces = await uploadResponse.json() as Array<{ user_id: string; created_at: string }>;
      console.log(`[Dashboard Users] Found ${uploadTraces.length} upload traces`);
      allTraces = [...allTraces, ...uploadTraces];
    }
    
    // Group by user_id and count
    const userMap = new Map<string, { user_id: string; activity_count: number; last_activity: string }>();
    for (const trace of allTraces) {
      if (!trace.user_id) continue;
      const existing = userMap.get(trace.user_id);
      if (existing) {
        existing.activity_count++;
        if (trace.created_at > existing.last_activity) {
          existing.last_activity = trace.created_at;
        }
      } else {
        userMap.set(trace.user_id, {
          user_id: trace.user_id,
          activity_count: 1,
          last_activity: trace.created_at,
        });
      }
    }
    
    console.log(`[Dashboard Users] Found ${userMap.size} unique users`);
    
    // Get user emails from notes table
    const users = Array.from(userMap.values());
    const userIds = users.map(u => u.user_id);
    
    if (userIds.length > 0) {
      // URL encode the user IDs for the IN clause
      const inClause = userIds.map(id => `"${id}"`).join(',');
      const notesUrl = `${env.SUPABASE_URL}/rest/v1/notes?select=user_id,user_email&user_id=in.(${inClause})&limit=1000`;
      console.log(`[Dashboard Users] Fetching emails from notes`);
      
      const notesResponse = await fetch(notesUrl, {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      });
      
      if (notesResponse.ok) {
        const notes = await notesResponse.json() as Array<{ user_id: string; user_email?: string }>;
        const emailMap = new Map<string, string>();
        for (const note of notes) {
          if (note.user_email && !emailMap.has(note.user_id)) {
            emailMap.set(note.user_id, note.user_email);
          }
        }
        
        // Add emails to users
        for (const user of users) {
          (user as any).email = emailMap.get(user.user_id) || null;
        }
        console.log(`[Dashboard Users] Added ${emailMap.size} emails`);
      }
    }
    
    // Sort by activity count
    users.sort((a, b) => b.activity_count - a.activity_count);
    
    // Return in format expected by frontend: { users: [...] }
    return new Response(
      JSON.stringify({ users }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching dashboard users:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/logs/dashboard/activities - Get activities for a user
// ============================================================================
export async function handleDashboardActivities(
  request: Request,
  authResult: AuthResult,
  env: LogsEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }
  
  const url = new URL(request.url);
  const userId = url.searchParams.get('user_id');
  const hours = parseInt(url.searchParams.get('hours') || '24');
  const limit = parseInt(url.searchParams.get('limit') || '100');
  
  if (!userId) {
    return new Response(
      JSON.stringify({ error: 'user_id parameter required' }),
      { status: 400, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  
  const since = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();
  
  try {
    // Get search traces and upload traces in parallel
    const [searchResponse, uploadResponse] = await Promise.all([
      // Search traces
      fetch(
        `${env.SUPABASE_URL}/rest/v1/search_traces?user_id=eq.${userId}&created_at=gte.${since}&order=created_at.desc&limit=${limit}`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      ),
      // Upload traces
      fetch(
        `${env.SUPABASE_URL}/rest/v1/upload_traces?user_id=eq.${userId}&created_at=gte.${since}&order=created_at.desc&limit=${limit}`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      ),
    ]);
    
    if (!searchResponse.ok) {
      const errorText = await searchResponse.text();
      return new Response(
        JSON.stringify({ error: 'Failed to fetch activities', detail: errorText }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    const traces = await searchResponse.json();
    
    // Transform search traces to activity format expected by frontend
    // Frontend expects: action, status, created_at, duration_ms, metadata, correlation_id, resource_type
    const searchActivities = (traces as any[]).map(trace => ({
      id: trace.id,
      correlation_id: trace.correlation_id,
      action: 'search',  // Frontend uses this for display
      status: trace.final_count > 0 ? 'success' : 'no_results',
      created_at: trace.created_at,
      duration_ms: trace.timing_total_ms || 0,
      resource_type: 'notes',
      metadata: {
        query: trace.query,
        query_corrected: trace.query_corrected,
        result_count: trace.final_count || 0,
        vector_count: trace.vector_count,
        keyword_count: trace.keyword_count,
        reranked_count: trace.reranked_count,
        source: trace.source_worker || 'worker',
      },
      // Include full trace data for detail view
      trace_data: trace,
    }));
    
    // Transform upload traces to activity format
    let uploadActivities: any[] = [];
    if (uploadResponse.ok) {
      const uploadTraces = await uploadResponse.json() as any[];
      uploadActivities = uploadTraces.map(trace => ({
        id: trace.id,
        correlation_id: trace.trace_id,
        trace_id: trace.trace_id,
        action: `upload_${trace.upload_type || 'file'}`,
        status: trace.status === 'completed' ? 'success' : trace.status === 'failed' ? 'error' : trace.status,
        created_at: trace.created_at,
        duration_ms: trace.timing_total_ms || 0,
        resource_type: 'upload',
        metadata: {
          filename: trace.original_filename,
          file_size_bytes: trace.file_size_bytes,
          upload_type: trace.upload_type,
          title_generated: trace.title_generated,
          chunk_count: trace.chunk_count,
          vector_count: trace.vector_count,
          conversion_method: trace.conversion_method,
          error_occurred: !!trace.error_message,
          error_message: trace.error_message,
        },
        trace_data: trace,
      }));
    }
    
    // Merge and sort by created_at desc
    const activities = [...searchActivities, ...uploadActivities]
      .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
      .slice(0, limit);
    
    // Return in format expected by frontend: { activities: [...] }
    return new Response(
      JSON.stringify({ activities }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching activities:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/logs/search-trace/:id - Get single search trace
// ============================================================================
export async function handleSearchTrace(
  traceId: string,
  authResult: AuthResult,
  env: LogsEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }
  
  try {
    // Try to find by correlation_id first, then by id
    let response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/search_traces?correlation_id=eq.${traceId}&limit=1`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );
    
    let traces = await response.json() as any[];
    
    if (!traces || traces.length === 0) {
      // Try by id
      response = await fetch(
        `${env.SUPABASE_URL}/rest/v1/search_traces?id=eq.${traceId}&limit=1`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      );
      traces = await response.json() as any[];
    }
    
    if (!traces || traces.length === 0) {
      return new Response(
        JSON.stringify({ error: 'Trace not found' }),
        { status: 404, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    return new Response(
      JSON.stringify(traces[0]),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching search trace:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/logs/trace/:id - Get trace operations (from worker_logs)
// ============================================================================
export async function handleTraceOperations(
  correlationId: string,
  authResult: AuthResult,
  env: LogsEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }
  
  try {
    // Get logs from worker_logs table for this correlation_id
    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/worker_logs?correlation_id=eq.${correlationId}&order=timestamp.asc`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );
    
    if (!response.ok) {
      // worker_logs table might not exist, return empty
      return new Response(
        JSON.stringify({ operations: [], correlation_id: correlationId }),
        { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    const logs = await response.json() as any[];
    
    return new Response(
      JSON.stringify({ operations: logs, correlation_id: correlationId }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching trace operations:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/logs/file/trace/:id - Get file trace (from file_traces)
// ============================================================================
export async function handleFileTrace(
  correlationId: string,
  request: Request,
  authResult: AuthResult,
  env: LogsEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }
  
  const url = new URL(request.url);
  const includeContext = url.searchParams.get('include_context') === 'true';
  
  try {
    // Get file trace from file_traces table
    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/file_traces?correlation_id=eq.${correlationId}&limit=1`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );
    
    if (!response.ok) {
      // file_traces table might not exist
      return new Response(
        JSON.stringify({ error: 'File trace not found' }),
        { status: 404, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    const traces = await response.json() as any[];
    
    if (!traces || traces.length === 0) {
      return new Response(
        JSON.stringify({ error: 'File trace not found' }),
        { status: 404, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
      );
    }
    
    return new Response(
      JSON.stringify(traces[0]),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching file trace:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}
