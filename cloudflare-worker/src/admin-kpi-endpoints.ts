/**
 * Admin KPI Dashboard Endpoints for Cloudflare Worker
 * 
 * These endpoints provide aggregated metrics for the admin KPI dashboard:
 * - User counts (total, new users by period)
 * - Search metrics (by source, by time)
 * - Latency statistics
 * - System health indicators
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

function unauthorizedResponse(message: string = 'Unauthorized'): Response {
  return new Response(
    JSON.stringify({ error: message }),
    { status: 401, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

function forbiddenResponse(): Response {
  return new Response(
    JSON.stringify({ error: 'Access denied. Admin privileges required.' }),
    { status: 403, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
  );
}

export interface AdminEnv {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
}

// ============================================================================
// GET /api/v1/admin/kpi/summary - Complete KPI summary for dashboard
// ============================================================================
export async function handleKpiSummary(
  request: Request,
  authResult: AuthResult,
  env: AdminEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return unauthorizedResponse();
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }

  try {
    const now = new Date();
    const day_ago = new Date(now.getTime() - 24 * 60 * 60 * 1000).toISOString();
    const week_ago = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000).toISOString();
    const month_ago = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000).toISOString();

    // Fetch all data in parallel
    const [usersResponse, searchesResponse, uploadsResponse, notesResponse] = await Promise.all([
      // Get all users from auth.users via admin API
      fetch(`${env.SUPABASE_URL}/auth/v1/admin/users?page=1&per_page=1000`, {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }),
      // Get recent searches
      fetch(`${env.SUPABASE_URL}/rest/v1/search_traces?select=user_id,client_source,timing_total_ms,created_at,error_occurred&created_at=gte.${month_ago}&order=created_at.desc&limit=5000`, {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }),
      // Get upload traces
      fetch(`${env.SUPABASE_URL}/rest/v1/upload_traces?select=user_id,status,created_at&created_at=gte.${month_ago}&order=created_at.desc&limit=1000`, {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }),
      // Get notes count
      fetch(`${env.SUPABASE_URL}/rest/v1/notes?select=user_id,created_at&limit=5000`, {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }),
    ]);

    // Process users - include full user list with emails
    let userStats = { 
      total: 0, 
      new_24h: 0, 
      new_7d: 0, 
      new_30d: 0,
      users_list: [] as Array<{ id: string; email: string; created_at: string }>,
      new_users_24h_list: [] as Array<{ id: string; email: string; created_at: string }>,
      new_users_7d_list: [] as Array<{ id: string; email: string; created_at: string }>,
      new_users_30d_list: [] as Array<{ id: string; email: string; created_at: string }>,
    };
    
    // Map user IDs to emails for lookup
    const userIdToEmail = new Map<string, string>();
    
    if (usersResponse.ok) {
      const userData = await usersResponse.json() as { users: Array<{ id: string; email: string; created_at: string }> };
      const users = userData.users || [];
      userStats.total = users.length;
      
      // Store all users with email
      userStats.users_list = users.map(u => ({ 
        id: u.id, 
        email: u.email || 'No email', 
        created_at: u.created_at 
      })).sort((a, b) => b.created_at.localeCompare(a.created_at));
      
      // Build lookup map
      for (const user of users) {
        userIdToEmail.set(user.id, user.email || 'Unknown');
      }
      
      for (const user of users) {
        const created = user.created_at;
        const userInfo = { id: user.id, email: user.email || 'No email', created_at: user.created_at };
        if (created > day_ago) {
          userStats.new_24h++;
          userStats.new_users_24h_list.push(userInfo);
        }
        if (created > week_ago) {
          userStats.new_7d++;
          userStats.new_users_7d_list.push(userInfo);
        }
        if (created > month_ago) {
          userStats.new_30d++;
          userStats.new_users_30d_list.push(userInfo);
        }
      }
    }

    // Process searches
    let searchStats = {
      total_30d: 0,
      total_7d: 0,
      total_24h: 0,
      by_source: {} as Record<string, number>,
      by_source_24h: {} as Record<string, number>,
      latency_avg: 0,
      latency_p50: 0,
      latency_p95: 0,
      error_count: 0,
      error_rate: 0,
      active_users_24h: 0,
      active_users_7d: 0,
      active_users_24h_list: [] as Array<{ id: string; email: string }>,
      active_users_7d_list: [] as Array<{ id: string; email: string }>,
    };

    if (searchesResponse.ok) {
      const searches = await searchesResponse.json() as Array<{
        user_id: string;
        client_source: string | null;
        timing_total_ms: number | null;
        created_at: string;
        error_occurred: boolean | null;
      }>;

      const latencies: number[] = [];
      const activeUsers24h = new Set<string>();
      const activeUsers7d = new Set<string>();

      for (const s of searches) {
        const source = s.client_source || 'unknown';
        searchStats.by_source[source] = (searchStats.by_source[source] || 0) + 1;
        searchStats.total_30d++;

        if (s.created_at > week_ago) {
          searchStats.total_7d++;
          if (s.user_id) activeUsers7d.add(s.user_id);
        }
        if (s.created_at > day_ago) {
          searchStats.total_24h++;
          searchStats.by_source_24h[source] = (searchStats.by_source_24h[source] || 0) + 1;
          if (s.user_id) activeUsers24h.add(s.user_id);
        }

        if (s.timing_total_ms) latencies.push(s.timing_total_ms);
        if (s.error_occurred) searchStats.error_count++;
      }

      // Calculate latency percentiles
      if (latencies.length > 0) {
        latencies.sort((a, b) => a - b);
        searchStats.latency_avg = Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length);
        searchStats.latency_p50 = latencies[Math.floor(latencies.length * 0.5)];
        searchStats.latency_p95 = latencies[Math.floor(latencies.length * 0.95)];
      }

      searchStats.error_rate = searches.length > 0 
        ? Math.round((searchStats.error_count / searches.length) * 100 * 100) / 100
        : 0;
      searchStats.active_users_24h = activeUsers24h.size;
      searchStats.active_users_7d = activeUsers7d.size;
      
      // Convert to lists with emails
      searchStats.active_users_24h_list = Array.from(activeUsers24h).map(id => ({
        id,
        email: userIdToEmail.get(id) || 'Unknown'
      }));
      searchStats.active_users_7d_list = Array.from(activeUsers7d).map(id => ({
        id,
        email: userIdToEmail.get(id) || 'Unknown'
      }));
    }

    // Process uploads
    let uploadStats = { total: 0, completed: 0, failed: 0, success_rate: 0 };
    if (uploadsResponse.ok) {
      const uploads = await uploadsResponse.json() as Array<{ status: string }>;
      uploadStats.total = uploads.length;
      uploadStats.completed = uploads.filter(u => u.status === 'completed').length;
      uploadStats.failed = uploads.filter(u => u.status === 'error' || u.status === 'failed').length;
      uploadStats.success_rate = uploadStats.total > 0
        ? Math.round((uploadStats.completed / uploadStats.total) * 100)
        : 0;
    }

    // Process notes
    let notesStats = { total: 0, new_24h: 0, new_7d: 0 };
    if (notesResponse.ok) {
      const notes = await notesResponse.json() as Array<{ created_at: string }>;
      notesStats.total = notes.length;
      for (const n of notes) {
        if (n.created_at > day_ago) notesStats.new_24h++;
        if (n.created_at > week_ago) notesStats.new_7d++;
      }
    }

    return new Response(
      JSON.stringify({
        generated_at: now.toISOString(),
        users: userStats,
        searches: searchStats,
        uploads: uploadStats,
        notes: notesStats,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching KPI summary:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/admin/kpi/search-timeseries - Search counts grouped by time
// ============================================================================
export async function handleKpiSearchTimeseries(
  request: Request,
  authResult: AuthResult,
  env: AdminEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return unauthorizedResponse();
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }

  const url = new URL(request.url);
  const hours = parseInt(url.searchParams.get('hours') || '24');
  const interval = url.searchParams.get('interval') || 'hour'; // 'minute', 'hour', 'day'

  try {
    const since = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();

    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/search_traces?select=client_source,timing_total_ms,created_at&created_at=gte.${since}&order=created_at.asc&limit=10000`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!response.ok) {
      throw new Error(`Supabase error: ${response.status}`);
    }

    const searches = await response.json() as Array<{
      client_source: string | null;
      timing_total_ms: number | null;
      created_at: string;
    }>;

    // Group by time bucket
    const buckets = new Map<string, { 
      timestamp: string;
      total: number;
      google: number;
      dashboard: number;
      other: number;
      avg_latency: number;
      latencies: number[];
    }>();

    for (const s of searches) {
      const date = new Date(s.created_at);
      let bucketKey: string;
      
      if (interval === 'minute') {
        bucketKey = date.toISOString().slice(0, 16); // YYYY-MM-DDTHH:MM
      } else if (interval === 'hour') {
        bucketKey = date.toISOString().slice(0, 13); // YYYY-MM-DDTHH
      } else {
        bucketKey = date.toISOString().slice(0, 10); // YYYY-MM-DD
      }

      if (!buckets.has(bucketKey)) {
        buckets.set(bucketKey, {
          timestamp: bucketKey,
          total: 0,
          google: 0,
          dashboard: 0,
          other: 0,
          avg_latency: 0,
          latencies: [],
        });
      }

      const bucket = buckets.get(bucketKey)!;
      bucket.total++;
      
      const source = s.client_source || 'unknown';
      if (source === 'google-search') {
        bucket.google++;
      } else if (source === 'dashboard') {
        bucket.dashboard++;
      } else {
        bucket.other++;
      }

      if (s.timing_total_ms) {
        bucket.latencies.push(s.timing_total_ms);
      }
    }

    // Calculate avg latency and convert to array
    const timeseries = Array.from(buckets.values()).map(b => ({
      timestamp: b.timestamp,
      total: b.total,
      google: b.google,
      dashboard: b.dashboard,
      other: b.other,
      avg_latency: b.latencies.length > 0 
        ? Math.round(b.latencies.reduce((a, c) => a + c, 0) / b.latencies.length)
        : 0,
    }));

    return new Response(
      JSON.stringify({ 
        hours,
        interval,
        data: timeseries,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching search timeseries:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/admin/kpi/latency-timeseries - Latency stats grouped by time
// ============================================================================
export async function handleKpiLatencyTimeseries(
  request: Request,
  authResult: AuthResult,
  env: AdminEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return unauthorizedResponse();
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }

  const url = new URL(request.url);
  const hours = parseInt(url.searchParams.get('hours') || '24');

  try {
    const since = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();

    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/search_traces?select=timing_total_ms,timing_embedding_ms,timing_vector_search_ms,timing_rerank_ms,timing_synthesis_ms,created_at&created_at=gte.${since}&order=created_at.asc&limit=10000`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!response.ok) {
      throw new Error(`Supabase error: ${response.status}`);
    }

    const searches = await response.json() as Array<{
      timing_total_ms: number | null;
      timing_embedding_ms: number | null;
      timing_vector_search_ms: number | null;
      timing_rerank_ms: number | null;
      timing_synthesis_ms: number | null;
      created_at: string;
    }>;

    // Group by hour
    const buckets = new Map<string, {
      timestamp: string;
      count: number;
      total_latencies: number[];
      embedding_latencies: number[];
      vector_latencies: number[];
      rerank_latencies: number[];
      synthesis_latencies: number[];
    }>();

    for (const s of searches) {
      const date = new Date(s.created_at);
      const bucketKey = date.toISOString().slice(0, 13); // YYYY-MM-DDTHH

      if (!buckets.has(bucketKey)) {
        buckets.set(bucketKey, {
          timestamp: bucketKey,
          count: 0,
          total_latencies: [],
          embedding_latencies: [],
          vector_latencies: [],
          rerank_latencies: [],
          synthesis_latencies: [],
        });
      }

      const bucket = buckets.get(bucketKey)!;
      bucket.count++;
      
      if (s.timing_total_ms) bucket.total_latencies.push(s.timing_total_ms);
      if (s.timing_embedding_ms) bucket.embedding_latencies.push(s.timing_embedding_ms);
      if (s.timing_vector_search_ms) bucket.vector_latencies.push(s.timing_vector_search_ms);
      if (s.timing_rerank_ms) bucket.rerank_latencies.push(s.timing_rerank_ms);
      if (s.timing_synthesis_ms) bucket.synthesis_latencies.push(s.timing_synthesis_ms);
    }

    const calcStats = (arr: number[]) => {
      if (arr.length === 0) return { avg: 0, p50: 0, p95: 0 };
      arr.sort((a, b) => a - b);
      return {
        avg: Math.round(arr.reduce((a, b) => a + b, 0) / arr.length),
        p50: arr[Math.floor(arr.length * 0.5)],
        p95: arr[Math.floor(arr.length * 0.95)],
      };
    };

    const timeseries = Array.from(buckets.values()).map(b => ({
      timestamp: b.timestamp,
      count: b.count,
      total: calcStats(b.total_latencies),
      embedding: calcStats(b.embedding_latencies),
      vector: calcStats(b.vector_latencies),
      rerank: calcStats(b.rerank_latencies),
      synthesis: calcStats(b.synthesis_latencies),
    }));

    return new Response(
      JSON.stringify({ hours, data: timeseries }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching latency timeseries:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/admin/kpi/upload-details - Detailed upload status breakdown
// ============================================================================
export async function handleKpiUploadDetails(
  request: Request,
  authResult: AuthResult,
  env: AdminEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return unauthorizedResponse();
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }

  const url = new URL(request.url);
  const hours = parseInt(url.searchParams.get('hours') || '720'); // Default 30 days

  try {
    const since = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();

    // Fetch users first to get email mapping
    const usersResponse = await fetch(`${env.SUPABASE_URL}/auth/v1/admin/users?page=1&per_page=1000`, {
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });
    
    const userIdToEmail = new Map<string, string>();
    if (usersResponse.ok) {
      const userData = await usersResponse.json() as { users: Array<{ id: string; email: string }> };
      for (const user of userData.users || []) {
        userIdToEmail.set(user.id, user.email || 'Unknown');
      }
    }

    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/upload_traces?select=trace_id,user_id,status,original_filename,chunk_count,timing_total_ms,error_message,created_at,completed_at&created_at=gte.${since}&order=created_at.desc&limit=500`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!response.ok) {
      throw new Error(`Supabase error: ${response.status}`);
    }

    const uploads = await response.json() as Array<{
      trace_id: string;
      user_id: string;
      status: string;
      original_filename: string | null;
      chunk_count: number | null;
      timing_total_ms: number | null;
      error_message: string | null;
      created_at: string;
      completed_at: string | null;
    }>;

    // Separate by status
    const completed = uploads.filter(u => u.status === 'completed');
    const failed = uploads.filter(u => u.status === 'error' || u.status === 'failed');
    const pending = uploads.filter(u => !['completed', 'error', 'failed'].includes(u.status));

    // Get summary stats
    const stats = {
      total: uploads.length,
      completed: completed.length,
      failed: failed.length,
      pending: pending.length,
      success_rate: uploads.length > 0 
        ? Math.round((completed.length / uploads.length) * 100)
        : 0,
    };

    // Top error messages
    const errorCounts = new Map<string, number>();
    for (const f of failed) {
      const msg = f.error_message || 'Unknown error';
      const shortMsg = msg.slice(0, 100);
      errorCounts.set(shortMsg, (errorCounts.get(shortMsg) || 0) + 1);
    }
    const topErrors = Array.from(errorCounts.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, 5)
      .map(([message, count]) => ({ message, count }));

    return new Response(
      JSON.stringify({
        hours,
        stats,
        top_errors: topErrors,
        recent_completed: completed.slice(0, 20).map(u => ({
          user_id: u.user_id,
          user_email: userIdToEmail.get(u.user_id) || 'Unknown',
          filename: u.original_filename,
          chunks: u.chunk_count,
          latency_ms: u.timing_total_ms,
          created_at: u.created_at,
          completed_at: u.completed_at,
        })),
        recent_failed: failed.map(u => ({
          user_id: u.user_id,
          user_email: userIdToEmail.get(u.user_id) || 'Unknown',
          filename: u.original_filename,
          error: u.error_message?.slice(0, 200),
          created_at: u.created_at,
        })),
      }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching upload details:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/admin/kpi/search-sources - Search sources by time period
// ============================================================================
export async function handleKpiSearchSources(
  request: Request,
  authResult: AuthResult,
  env: AdminEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return unauthorizedResponse();
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }

  const url = new URL(request.url);
  const hours = parseInt(url.searchParams.get('hours') || '24');

  try {
    const since = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();

    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/search_traces?select=client_source&created_at=gte.${since}&limit=10000`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!response.ok) {
      throw new Error(`Supabase error: ${response.status}`);
    }

    const searches = await response.json() as Array<{ client_source: string | null }>;

    const byCounts: Record<string, number> = {};
    for (const s of searches) {
      const source = s.client_source || 'unknown';
      byCounts[source] = (byCounts[source] || 0) + 1;
    }

    return new Response(
      JSON.stringify({
        hours,
        total: searches.length,
        by_source: byCounts,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching search sources:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/admin/kpi/error-details - Detailed error breakdown with user info
// ============================================================================
export async function handleKpiErrorDetails(
  request: Request,
  authResult: AuthResult,
  env: AdminEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return unauthorizedResponse();
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }

  const url = new URL(request.url);
  const hours = parseInt(url.searchParams.get('hours') || '720'); // Default 30 days

  try {
    const since = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();

    // Fetch users first to get email mapping
    const usersResponse = await fetch(`${env.SUPABASE_URL}/auth/v1/admin/users?page=1&per_page=1000`, {
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });
    
    const userIdToEmail = new Map<string, string>();
    if (usersResponse.ok) {
      const userData = await usersResponse.json() as { users: Array<{ id: string; email: string }> };
      for (const user of userData.users || []) {
        userIdToEmail.set(user.id, user.email || 'Unknown');
      }
    }

    // Fetch search traces with errors
    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/search_traces?select=user_id,query,error_message,error_occurred,created_at,client_source&created_at=gte.${since}&error_occurred=eq.true&order=created_at.desc&limit=200`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!response.ok) {
      throw new Error(`Supabase error: ${response.status}`);
    }

    const errors = await response.json() as Array<{
      user_id: string;
      query: string | null;
      error_message: string | null;
      error_occurred: boolean;
      created_at: string;
      client_source: string | null;
    }>;

    // Get total searches in same period for rate calculation
    const totalResponse = await fetch(
      `${env.SUPABASE_URL}/rest/v1/search_traces?select=id&created_at=gte.${since}`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          'Prefer': 'count=exact',
        },
      }
    );
    
    const totalCount = parseInt(totalResponse.headers.get('content-range')?.split('/')[1] || '0');
    const errorRate = totalCount > 0 ? Math.round((errors.length / totalCount) * 100 * 100) / 100 : 0;

    // Group by error type
    const errorCounts = new Map<string, number>();
    for (const e of errors) {
      const msg = e.error_message || 'Unknown error';
      const shortMsg = msg.slice(0, 80);
      errorCounts.set(shortMsg, (errorCounts.get(shortMsg) || 0) + 1);
    }
    const topErrors = Array.from(errorCounts.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, 5)
      .map(([message, count]) => ({ message, count }));

    return new Response(
      JSON.stringify({
        hours,
        stats: {
          total_errors: errors.length,
          total_searches: totalCount,
          error_rate: errorRate,
        },
        top_errors: topErrors,
        recent_errors: errors.slice(0, 20).map(e => ({
          user_id: e.user_id,
          user_email: userIdToEmail.get(e.user_id) || 'Unknown',
          query: e.query?.slice(0, 100),
          error: e.error_message?.slice(0, 200),
          source: e.client_source,
          created_at: e.created_at,
        })),
      }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching error details:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/admin/kpi/latency-stats - Latency stats with time filter
// ============================================================================
export async function handleKpiLatencyStats(
  request: Request,
  authResult: AuthResult,
  env: AdminEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return unauthorizedResponse();
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }

  const url = new URL(request.url);
  const hours = parseInt(url.searchParams.get('hours') || '720'); // Default 30 days

  try {
    const since = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();

    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/search_traces?select=timing_total_ms&created_at=gte.${since}&timing_total_ms=not.is.null&limit=5000`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!response.ok) {
      throw new Error(`Supabase error: ${response.status}`);
    }

    const searches = await response.json() as Array<{ timing_total_ms: number }>;
    const latencies = searches.map(s => s.timing_total_ms).filter(l => l > 0);

    let stats = { avg: 0, p50: 0, p95: 0, min: 0, max: 0, count: 0 };
    
    if (latencies.length > 0) {
      latencies.sort((a, b) => a - b);
      stats = {
        avg: Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length),
        p50: latencies[Math.floor(latencies.length * 0.5)],
        p95: latencies[Math.floor(latencies.length * 0.95)],
        min: latencies[0],
        max: latencies[latencies.length - 1],
        count: latencies.length,
      };
    }

    return new Response(
      JSON.stringify({ hours, stats }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching latency stats:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/admin/kpi/upload-latency-stats - Upload latency stats with time filter
// ============================================================================
export async function handleKpiUploadLatencyStats(
  request: Request,
  authResult: AuthResult,
  env: AdminEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return unauthorizedResponse();
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }

  const url = new URL(request.url);
  const hours = parseInt(url.searchParams.get('hours') || '720'); // Default 30 days

  try {
    const since = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();

    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/upload_traces?select=timing_total_ms&status=eq.completed&created_at=gte.${since}&timing_total_ms=not.is.null&limit=2000`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!response.ok) {
      throw new Error(`Supabase error: ${response.status}`);
    }

    const uploads = await response.json() as Array<{ timing_total_ms: number }>;
    const latencies = uploads.map(u => u.timing_total_ms).filter(l => l > 0);

    let stats = { avg: 0, p50: 0, p95: 0, min: 0, max: 0, count: 0 };
    
    if (latencies.length > 0) {
      latencies.sort((a, b) => a - b);
      stats = {
        avg: Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length),
        p50: latencies[Math.floor(latencies.length * 0.5)],
        p95: latencies[Math.floor(latencies.length * 0.95)],
        min: latencies[0],
        max: latencies[latencies.length - 1],
        count: latencies.length,
      };
    }

    return new Response(
      JSON.stringify({ hours, stats }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching upload latency stats:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}

// ============================================================================
// GET /api/v1/admin/kpi/upload-error-details - Upload errors with details
// ============================================================================
export async function handleKpiUploadErrorDetails(
  request: Request,
  authResult: AuthResult,
  env: AdminEnv
): Promise<Response> {
  if (!authResult.authenticated) {
    return unauthorizedResponse();
  }
  if (!isAdmin(authResult)) {
    return forbiddenResponse();
  }

  const url = new URL(request.url);
  const hours = parseInt(url.searchParams.get('hours') || '720'); // Default 30 days

  try {
    const since = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();

    // Fetch users first to get email mapping
    const usersResponse = await fetch(`${env.SUPABASE_URL}/auth/v1/admin/users?page=1&per_page=1000`, {
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });
    
    const userIdToEmail = new Map<string, string>();
    if (usersResponse.ok) {
      const userData = await usersResponse.json() as { users: Array<{ id: string; email: string }> };
      for (const user of userData.users || []) {
        userIdToEmail.set(user.id, user.email || 'Unknown');
      }
    }

    // Fetch all uploads to calculate error rate  
    const [allResponse, failedResponse] = await Promise.all([
      fetch(
        `${env.SUPABASE_URL}/rest/v1/upload_traces?select=status&created_at=gte.${since}&limit=5000`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      ),
      fetch(
        `${env.SUPABASE_URL}/rest/v1/upload_traces?select=trace_id,user_id,original_filename,error_message,created_at&created_at=gte.${since}&or=(status.eq.error,status.eq.failed)&order=created_at.desc&limit=100`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      ),
    ]);

    if (!allResponse.ok || !failedResponse.ok) {
      throw new Error(`Supabase error: ${allResponse.status}/${failedResponse.status}`);
    }

    const allUploads = await allResponse.json() as Array<{ status: string }>;
    const failedUploads = await failedResponse.json() as Array<{
      trace_id: string;
      user_id: string;
      original_filename: string | null;
      error_message: string | null;
      created_at: string;
    }>;

    const totalUploads = allUploads.length;
    const errorUploads = allUploads.filter(u => u.status === 'error' || u.status === 'failed').length;
    const errorRate = totalUploads > 0 ? Math.round((errorUploads / totalUploads) * 100 * 10) / 10 : 0;

    // Top error messages
    const errorCounts = new Map<string, number>();
    for (const f of failedUploads) {
      const msg = f.error_message || 'Unknown error';
      const shortMsg = msg.slice(0, 100);
      errorCounts.set(shortMsg, (errorCounts.get(shortMsg) || 0) + 1);
    }
    const topErrors = Array.from(errorCounts.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, 10)
      .map(([message, count]) => ({ message, count }));

    return new Response(
      JSON.stringify({
        hours,
        stats: {
          total_uploads: totalUploads,
          total_errors: errorUploads,
          error_rate: errorRate,
        },
        top_errors: topErrors,
        recent_errors: failedUploads.slice(0, 20).map(u => ({
          user_email: userIdToEmail.get(u.user_id) || 'Unknown',
          filename: u.original_filename,
          error: u.error_message?.slice(0, 200),
          created_at: u.created_at,
        })),
      }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  } catch (err) {
    console.error('Error fetching upload error details:', err);
    return new Response(
      JSON.stringify({ error: 'Internal server error', detail: String(err) }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders } }
    );
  }
}
