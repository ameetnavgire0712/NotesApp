import { AuthResult, AuthEnv } from './auth';
import { handleListNotes, handleListTags, ensureSignedAzureUrl, ApiEnv } from './api-endpoints';
import { handleBillingStatus, BillingEnv } from './billing';
import { handleListGroups, GroupsEnv } from './groups';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Key',
};

type BootstrapEnv = ApiEnv & BillingEnv & GroupsEnv & AuthEnv;

async function readJson<T>(response: Response, fallback: T): Promise<T> {
  if (!response.ok) return fallback;
  try {
    return (await response.json()) as T;
  } catch {
    return fallback;
  }
}

async function supabaseRpc<T>(
  env: BootstrapEnv,
  functionName: string,
  body: Record<string, unknown>,
): Promise<T | null> {
  const response = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${functionName}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: env.SUPABASE_SERVICE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    console.warn('APP_BOOTSTRAP_RPC_FAILED', response.status, await response.text().catch(() => ''));
    return null;
  }
  return await response.json() as T;
}

async function signBootstrapNotes(notes: any[], env: BootstrapEnv): Promise<any[]> {
  return Promise.all((notes || []).map(async (note) => {
    let thumbnailUrl = typeof note?.thumbnail_url === 'string' ? note.thumbnail_url : null;
    if (thumbnailUrl) {
      thumbnailUrl = await ensureSignedAzureUrl(thumbnailUrl, env);
    }
    return { ...note, thumbnail_url: thumbnailUrl };
  }));
}

async function signBootstrapCollections(
  collections: any,
  env: BootstrapEnv,
): Promise<{ tags: any[]; types: any[] }> {
  const signEntries = async (entries: any): Promise<any[]> => {
    if (!Array.isArray(entries)) return [];
    return Promise.all(entries.map(async (entry) => {
      let cover = typeof entry?.cover_thumb_url === 'string' ? entry.cover_thumb_url : null;
      if (cover) {
        cover = await ensureSignedAzureUrl(cover, env);
      }
      return {
        value: typeof entry?.value === 'string' ? entry.value : '',
        count: Number(entry?.count || 0),
        cover_thumb_url: cover,
      };
    }));
  };
  const src = collections && typeof collections === 'object' ? collections : {};
  const [tags, types] = await Promise.all([
    signEntries(src.tags),
    signEntries(src.types),
  ]);
  return { tags, types };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

async function fetchUserProfileRest(
  userId: string,
  env: BootstrapEnv,
): Promise<Record<string, unknown> | null> {
  try {
    const resp = await fetch(
      `${env.SUPABASE_URL}/rest/v1/user_profiles?user_id=eq.${encodeURIComponent(
        userId,
      )}&select=user_id,email,display_name,avatar_url&limit=1`,
      {
        headers: {
          apikey: env.SUPABASE_SERVICE_KEY,
          Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      },
    );
    if (!resp.ok) return null;
    const rows = (await resp.json()) as Array<Record<string, unknown>>;
    if (!Array.isArray(rows) || rows.length === 0) return null;
    const row = rows[0] || {};
    const avatar = row.avatar_url;
    return {
      user_id: row.user_id ?? userId,
      email: row.email ?? null,
      display_name: row.display_name ?? null,
      avatar_url:
        typeof avatar === 'string' && avatar.trim().length > 0 ? avatar : null,
    };
  } catch (error) {
    console.warn('APP_BOOTSTRAP_PROFILE_REST_FAILED', String(error));
    return null;
  }
}

export async function handleAppBootstrap(
  request: Request,
  authResult: AuthResult,
  env: BootstrapEnv,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return jsonResponse({ error: 'Unauthorized' }, 401);
  }

  const url = new URL(request.url);
  const notesLimit = Math.min(
    Math.max(parseInt(url.searchParams.get('notes_limit') || '80', 10), 0),
    200,
  );

  const rpcPayload = await supabaseRpc<Record<string, any>>(env, 'get_app_bootstrap', {
    p_user_id: authResult.user_id,
    p_notes_limit: notesLimit,
  });

  if (rpcPayload) {
    const [recentNotes, collections] = await Promise.all([
      Array.isArray(rpcPayload.recent_notes)
        ? signBootstrapNotes(rpcPayload.recent_notes, env)
        : Promise.resolve([] as any[]),
      signBootstrapCollections(rpcPayload.collections, env),
    ]);
    let profile: Record<string, unknown> | null =
      rpcPayload.profile && typeof rpcPayload.profile === 'object'
        ? { ...(rpcPayload.profile as Record<string, unknown>) }
        : null;
    // Fallback: if the RPC didn't include a profile (e.g. migration 047 not
    // yet applied), fetch user_profiles via REST so the persistent avatar_url
    // still reaches the client. This is the value Google sign-in does NOT
    // overwrite.
    if (!profile || !profile.avatar_url) {
      profile = await fetchUserProfileRest(authResult.user_id, env);
    }
    if (profile && typeof profile.avatar_url === 'string' && profile.avatar_url) {
      profile.avatar_url = await ensureSignedAzureUrl(profile.avatar_url as string, env);
    }
    console.log(
      'APP_BOOTSTRAP_RPC_OK',
      authResult.user_id,
      'notes', recentNotes.length,
      'tag_collections', collections.tags.length,
      'type_collections', collections.types.length,
    );
    return jsonResponse({
      tags: Array.isArray(rpcPayload.tags) ? rpcPayload.tags : [],
      billing: rpcPayload.billing ?? null,
      groups: Array.isArray(rpcPayload.groups) ? rpcPayload.groups : [],
      notification_counts: rpcPayload.notification_counts || {
        group_unread_count: 0,
        pending_group_invites: 0,
        total_group_badge_count: 0,
      },
      recent_notes: recentNotes,
      recent_notes_has_more: rpcPayload.recent_notes_has_more === true,
      collections,
      profile,
      generated_at: rpcPayload.generated_at || new Date().toISOString(),
      bootstrap_source: 'rpc',
    });
  }

  console.log('APP_BOOTSTRAP_FALLBACK_FANOUT', authResult.user_id, 'notes_limit', notesLimit);
  const notesRequest = new Request(
    `${url.origin}/api/v1/notes/?limit=${notesLimit}&offset=0`,
    { method: 'GET', headers: request.headers },
  );

  const [tagsResp, billingResp, groupsResp, notesResp] = await Promise.all([
    handleListTags(authResult, env),
    handleBillingStatus(authResult, env),
    handleListGroups(authResult, env),
    notesLimit > 0
      ? handleListNotes(notesRequest, authResult, env)
      : Promise.resolve(jsonResponse({ notes: [], hasMore: false })),
  ]);

  const tagsPayload = await readJson<{ tags?: string[]; count?: number }>(
    tagsResp,
    { tags: [], count: 0 },
  );
  const billingPayload = await readJson<Record<string, unknown> | null>(
    billingResp,
    null,
  );
  const groupsPayload = await readJson<{ groups?: any[] }>(groupsResp, {
    groups: [],
  });
  const notesPayload = await readJson<{ notes?: any[]; hasMore?: boolean }>(
    notesResp,
    { notes: [], hasMore: false },
  );

  const groups = Array.isArray(groupsPayload.groups) ? groupsPayload.groups : [];
  const groupUnreadCount = groups.reduce(
    (sum, group) => sum + Number(group?.unread_count || 0),
    0,
  );
  const pendingGroupInvites = groups.filter(
    (group) => String(group?.status || '') === 'pending',
  ).length;

  let fallbackProfile = await fetchUserProfileRest(authResult.user_id, env);
  if (
    fallbackProfile &&
    typeof fallbackProfile.avatar_url === 'string' &&
    fallbackProfile.avatar_url
  ) {
    fallbackProfile.avatar_url = await ensureSignedAzureUrl(
      fallbackProfile.avatar_url as string,
      env,
    );
  }

  return jsonResponse({
    tags: tagsPayload.tags || [],
    billing: billingPayload,
    groups,
    notification_counts: {
      group_unread_count: groupUnreadCount,
      pending_group_invites: pendingGroupInvites,
      total_group_badge_count: groupUnreadCount + pendingGroupInvites,
    },
    recent_notes: notesPayload.notes || [],
    recent_notes_has_more: notesPayload.hasMore === true,
    collections: { tags: [], types: [] },
    profile: fallbackProfile,
    generated_at: new Date().toISOString(),
  });
}
