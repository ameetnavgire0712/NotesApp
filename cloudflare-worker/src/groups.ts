import { AuthResult } from './auth';

import { PushEnv, sendPushToUsers } from './push-notifications';
import { logAudit } from './audit';

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
};

export interface GroupsEnv {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  AZURE_STORAGE_CONNECTION_STRING?: string;
  AZURE_STORAGE_CONTAINER?: string;
  AZURE_THUMBNAILS_CONTAINER?: string;
  SENDGRID_API_KEY?: string;
  SENDGRID_FROM_EMAIL?: string;
  FIREBASE_PROJECT_ID?: string;
  FIREBASE_CLIENT_EMAIL?: string;
  FIREBASE_PRIVATE_KEY?: string;
}

type Json = Record<string, unknown>;

type GroupActivity = {
  type: string;
  userId?: string | null;
  title?: string | null;
  description?: string | null;
  fileType?: string | null;
  occurredAt?: string;
};

const baseGroupSelect = 'id,name,created_by,created_at,updated_at,avatar_url';
const extendedGroupSelect = `${baseGroupSelect},latest_activity_at,latest_activity_type,latest_activity_user_id,latest_activity_title,latest_activity_description,latest_activity_file_type`;

let supportsGroupActivityColumnsCache: boolean | null = null;

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

function unauthorized(): Response {
  return jsonResponse({ error: 'Unauthorized' }, 401);
}

function cleanEmail(email: string | null | undefined): string {
  return (email || '').trim().toLowerCase();
}

function escapeRestValue(value: string): string {
  return value.replace(/"/g, '\\"');
}

function firstString(values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === 'string' && value.trim().length > 0) {
      return value.trim();
    }
  }
  return null;
}

function parseConnectionString(connStr?: string): { accountName: string; accountKey: string } | null {
  if (!connStr) return null;
  const parts = connStr.split(';');
  let accountName = '';
  let accountKey = '';
  for (const part of parts) {
    if (part.startsWith('AccountName=')) accountName = part.substring(12);
    if (part.startsWith('AccountKey=')) accountKey = part.substring(11);
  }
  if (!accountName || !accountKey) return null;
  return { accountName, accountKey };
}

async function createSharedKeyAuth(
  accountName: string,
  accountKey: string,
  method: string,
  url: string,
  headers: Record<string, string>,
  contentLength: number,
): Promise<string> {
  const xmsHeaders = Object.entries(headers)
    .filter(([key]) => key.toLowerCase().startsWith('x-ms-'))
    .sort(([a], [b]) => a.toLowerCase().localeCompare(b.toLowerCase()))
    .map(([key, value]) => `${key.toLowerCase()}:${value}`)
    .join('\n');

  const urlObj = new URL(url);
  let canonicalResource = `/${accountName}${urlObj.pathname}`;
  const queryKeys = Array.from(new Set(Array.from(urlObj.searchParams.keys()).map(key => key.toLowerCase()))).sort();
  for (const key of queryKeys) {
    const values = urlObj.searchParams.getAll(key).sort().join(',');
    canonicalResource += `\n${key}:${values}`;
  }

  const contentType = headers['Content-Type'] || '';
  const contentLengthStr = contentLength === 0 ? '' : contentLength.toString();
  const stringToSign = [
    method, '', '', contentLengthStr, '', contentType,
    '', '', '', '', '', '', xmsHeaders, canonicalResource,
  ].join('\n');

  const keyBytes = Uint8Array.from(atob(accountKey), char => char.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign));
  const signatureB64 = btoa(String.fromCharCode(...new Uint8Array(signature)));
  return `SharedKey ${accountName}:${signatureB64}`;
}

function thumbnailContainerName(env: GroupsEnv): string {
  return (env.AZURE_THUMBNAILS_CONTAINER || 'notes-thumbnails').trim();
}

async function ensurePublicThumbnailContainer(env: GroupsEnv, container: string): Promise<void> {
  const parsed = parseConnectionString(env.AZURE_STORAGE_CONNECTION_STRING);
  if (!parsed) throw new Error('Azure storage connection string is not configured');
  const url = `https://${parsed.accountName}.blob.core.windows.net/${container}?restype=container`;
  const xmsDate = new Date().toUTCString();
  const headers: Record<string, string> = {
    'x-ms-blob-public-access': 'blob',
    'x-ms-date': xmsDate,
    'x-ms-version': '2020-10-02',
  };
  const authHeader = await createSharedKeyAuth(parsed.accountName, parsed.accountKey, 'PUT', url, headers, 0);
  const resp = await fetch(url, {
    method: 'PUT',
    headers: { ...headers, Authorization: authHeader },
  });
  if (resp.ok) return;
  if (resp.status === 409 && resp.headers.get('x-ms-error-code') === 'ContainerAlreadyExists') return;
  const text = await resp.text().catch(() => '');
  throw new Error(`Could not ensure public thumbnail container: ${resp.status} ${text.slice(0, 160)}`);
}

async function uploadGroupAvatar(
  env: GroupsEnv,
  groupId: string,
  userId: string,
  bytes: ArrayBuffer,
  filename: string,
  contentType: string,
): Promise<string> {
  const parsed = parseConnectionString(env.AZURE_STORAGE_CONNECTION_STRING);
  if (!parsed) throw new Error('Azure storage connection string is not configured');
  const container = thumbnailContainerName(env);
  await ensurePublicThumbnailContainer(env, container).catch(error => {
    console.warn('GROUP_AVATAR_CONTAINER_ENSURE_FAILED', error);
  });
  const ext = (filename.includes('.') ? filename.split('.').pop() : 'jpg') || 'jpg';
  const blobName = `groups/${groupId}/avatars/${Date.now()}_${crypto.randomUUID()}.${ext}`;
  const url = `https://${parsed.accountName}.blob.core.windows.net/${container}/${blobName}`;
  const headers: Record<string, string> = {
    'Content-Type': contentType,
    'Cache-Control': 'public, max-age=31536000, immutable',
    'x-ms-blob-type': 'BlockBlob',
    'x-ms-date': new Date().toUTCString(),
    'x-ms-version': '2020-10-02',
  };
  const authHeader = await createSharedKeyAuth(
    parsed.accountName,
    parsed.accountKey,
    'PUT',
    url,
    headers,
    bytes.byteLength,
  );
  const resp = await fetch(url, {
    method: 'PUT',
    headers: {
      ...headers,
      Authorization: authHeader,
      'Content-Length': bytes.byteLength.toString(),
    },
    body: bytes,
  });
  if (!resp.ok) {
    const text = await resp.text().catch(() => '');
    throw new Error(`Avatar upload failed: ${resp.status} ${text.slice(0, 160)}`);
  }
  return url;
}

async function supabaseFetch(
  env: GroupsEnv,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const headers = new Headers(init.headers || {});
  headers.set('apikey', env.SUPABASE_SERVICE_KEY);
  headers.set('Authorization', `Bearer ${env.SUPABASE_SERVICE_KEY}`);
  if (init.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }
  return fetch(`${env.SUPABASE_URL}${path}`, { ...init, headers });
}

async function readJson<T = any>(response: Response): Promise<T> {
  const text = await response.text();
  if (!text) return null as T;
  return JSON.parse(text) as T;
}

async function broadcastRealtime(
  env: GroupsEnv,
  topic: string,
  event: string,
  payload: Json = {}
): Promise<void> {
  try {
    await fetch(`${env.SUPABASE_URL}/realtime/v1/api/broadcast`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
      body: JSON.stringify({
        messages: [
          {
            topic,
            event,
            payload,
            private: false,
          },
        ],
      }),
    });
  } catch (error) {
    console.warn('GROUPS_REALTIME_BROADCAST_FAILED', topic, event, error);
  }
}

type UserRealtimeEnvelope =
  | { t: 'groups_list_changed' }
  | { t: 'group_changed'; g: string }
  | { t: 'reaction'; g: string; s: string; u: string; e: string | null; op: 'add' | 'remove' };

async function broadcastUserEvent(
  env: GroupsEnv,
  userId: string,
  payload: UserRealtimeEnvelope,
): Promise<void> {
  console.log(
    'GROUPS_REALTIME_USER_BROADCAST',
    payload.t,
    'g' in payload ? payload.g : '',
    's' in payload ? payload.s : '',
  );
  await broadcastRealtime(env, `user:${userId}`, 'groups', payload as Json);
}

async function broadcastGroupChanged(env: GroupsEnv, groupId: string): Promise<void> {
  const userIds = await listActiveGroupUserIds(env, groupId);
  await Promise.all(userIds.map(userId => broadcastUserEvent(env, userId, {
    t: 'group_changed',
    g: groupId,
  })));
}

async function broadcastGroupsListChanged(env: GroupsEnv, userId: string): Promise<void> {
  await broadcastUserEvent(env, userId, { t: 'groups_list_changed' });
}

async function listGroupUserIds(env: GroupsEnv, groupId: string): Promise<string[]> {
  const resp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&status=in.(active,pending)&user_id=not.is.null&select=user_id`
  );
  if (!resp.ok) return [];
  const rows = await readJson<Array<{ user_id?: string }>>(resp);
  return Array.from(new Set((rows || []).map(row => row.user_id).filter(Boolean))) as string[];
}

async function listActiveGroupUserIds(env: GroupsEnv, groupId: string): Promise<string[]> {
  const resp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&status=eq.active&user_id=not.is.null&select=user_id`
  );
  if (!resp.ok) return [];
  const rows = await readJson<Array<{ user_id?: string }>>(resp);
  return Array.from(new Set((rows || []).map(row => row.user_id).filter(Boolean))) as string[];
}

async function getGroupName(env: GroupsEnv, groupId: string): Promise<string> {
  const resp = await supabaseFetch(env, `/rest/v1/groups?id=eq.${groupId}&select=name&limit=1`);
  if (!resp.ok) return 'InfoSnap group';
  const rows = await readJson<Array<{ name?: string }>>(resp);
  return rows?.[0]?.name || 'InfoSnap group';
}

async function getGroupRecord(env: GroupsEnv, groupId: string) {
  const supportsActivityColumns = await supportsGroupActivityColumns(env);
  const resp = await supabaseFetch(
    env,
    `/rest/v1/groups?id=eq.${groupId}&select=${supportsActivityColumns ? extendedGroupSelect : baseGroupSelect}&limit=1`,
  );
  if (!resp.ok) return null;
  const rows = await readJson<any[]>(resp);
  const group = rows?.[0] || null;
  if (!group) return null;
  const enriched = await withFallbackGroupActivity(env, [group]);
  return enriched[0] || group;
}

function actorName(authResult: AuthResult): string {
  return authResult.name || authResult.email || 'Someone';
}

function pushEnv(env: GroupsEnv): PushEnv {
  return env as unknown as PushEnv;
}

async function broadcastGroupListsChanged(env: GroupsEnv, groupId: string): Promise<void> {
  const userIds = await listGroupUserIds(env, groupId);
  await Promise.all(userIds.map(userId => broadcastGroupsListChanged(env, userId)));
}

async function broadcastGroupReactionChanged(
  env: GroupsEnv,
  groupId: string,
  snapId: string,
  userId: string,
  emoji: string | null,
  op: 'add' | 'remove',
): Promise<void> {
  const userIds = await listActiveGroupUserIds(env, groupId);
  await Promise.all(userIds.map(memberId => broadcastUserEvent(env, memberId, {
    t: 'reaction',
    g: groupId,
    s: snapId,
    u: userId,
    e: emoji,
    op,
  })));
}

async function listProfilesByIds(env: GroupsEnv, userIds: string[]): Promise<Map<string, any>> {
  if (!userIds.length) return new Map();
  const inClause = userIds.map(id => `"${escapeRestValue(id)}"`).join(',');
  const resp = await supabaseFetch(
    env,
    `/rest/v1/user_profiles?user_id=in.(${inClause})&select=user_id,email,display_name,avatar_url`,
  );
  const profiles = resp.ok ? await readJson<any[]>(resp) : [];
  return new Map((profiles || []).map(profile => [profile.user_id, profile]));
}

async function supportsGroupActivityColumns(env: GroupsEnv): Promise<boolean> {
  if (supportsGroupActivityColumnsCache != null) return supportsGroupActivityColumnsCache;
  const resp = await supabaseFetch(env, '/rest/v1/groups?select=latest_activity_at&limit=1');
  supportsGroupActivityColumnsCache = resp.ok;
  if (!resp.ok) {
    const text = await resp.text().catch(() => '');
    console.warn('GROUP_ACTIVITY_COLUMNS_UNAVAILABLE', text.slice(0, 200));
  }
  return supportsGroupActivityColumnsCache;
}

async function withFallbackGroupActivity(env: GroupsEnv, groups: any[]): Promise<any[]> {
  if (!groups.length) return groups;
  const groupIds = groups.map(group => group.id).filter(Boolean);
  if (!groupIds.length) return groups;

  const inClause = groupIds.map(id => `"${escapeRestValue(id)}"`).join(',');
  const latestSnapsResp = await supabaseFetch(
    env,
    `/rest/v1/group_snaps?group_id=in.(${inClause})&select=id,group_id,shared_by,shared_at,title_snapshot,description_snapshot,file_type_snapshot&order=shared_at.desc`,
  );
  const latestSnaps = latestSnapsResp.ok ? await readJson<any[]>(latestSnapsResp) : [];
  const latestSnapByGroupId = new Map<string, any>();
  for (const snap of latestSnaps || []) {
    if (snap.group_id && !latestSnapByGroupId.has(snap.group_id)) {
      latestSnapByGroupId.set(snap.group_id, snap);
    }
  }

  return groups
    .map(group => {
      if (group.latest_activity_at) return group;
      const latestSnap = latestSnapByGroupId.get(group.id);
      if (latestSnap) {
        return {
          ...group,
          latest_activity_at: latestSnap.shared_at,
          latest_activity_type: 'group_snap',
          latest_activity_user_id: latestSnap.shared_by || null,
          latest_activity_title: latestSnap.title_snapshot || group.name,
          latest_activity_description: latestSnap.description_snapshot || null,
          latest_activity_file_type: latestSnap.file_type_snapshot || null,
        };
      }
      return {
        ...group,
        latest_activity_at: group.updated_at || group.created_at || new Date().toISOString(),
        latest_activity_type: 'group_created',
        latest_activity_user_id: group.created_by || null,
        latest_activity_title: group.name,
        latest_activity_description: null,
        latest_activity_file_type: null,
      };
    })
    .sort((left, right) => {
      const leftTime = Date.parse(left.latest_activity_at || left.updated_at || left.created_at || '') || 0;
      const rightTime = Date.parse(right.latest_activity_at || right.updated_at || right.created_at || '') || 0;
      return rightTime - leftTime;
    });
}

async function updateGroupActivity(env: GroupsEnv, groupId: string, activity: GroupActivity): Promise<void> {
  if (!(await supportsGroupActivityColumns(env))) return;
  await supabaseFetch(env, `/rest/v1/groups?id=eq.${groupId}`, {
    method: 'PATCH',
    body: JSON.stringify({
      latest_activity_at: activity.occurredAt || new Date().toISOString(),
      latest_activity_type: activity.type,
      latest_activity_user_id: activity.userId || null,
      latest_activity_title: activity.title || null,
      latest_activity_description: activity.description || null,
      latest_activity_file_type: activity.fileType || null,
    }),
  });
}

function isAdminRole(role: string | null | undefined): boolean {
  return role === 'admin' || role === 'owner';
}

async function preferredAdminRole(env: GroupsEnv): Promise<'admin' | 'owner'> {
  return (await supportsGroupActivityColumns(env)) ? 'admin' : 'owner';
}

async function hasAnyActiveAdmin(groupId: string, env: GroupsEnv): Promise<boolean> {
  const resp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&status=eq.active&select=id,role`
  );
  if (!resp.ok) return false;
  const rows = await readJson<any[]>(resp);
  return (rows || []).some(row => isAdminRole(row.role));
}

async function ensureGroupHasAdminForUser(groupId: string, preferredUserId: string | null | undefined, env: GroupsEnv) {
  const resp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&status=eq.active&select=id,user_id,role,created_at&order=created_at.asc`
  );
  if (!resp.ok) return null;
  const rows = await readJson<any[]>(resp);
  const activeMembers = rows || [];
  const existingAdmin = activeMembers.find(member => isAdminRole(member.role));
  if (existingAdmin) return existingAdmin;

  const preferredMember = preferredUserId
      ? activeMembers.find(member => member.user_id === preferredUserId)
      : null;
  const recoveryMember = preferredMember || activeMembers[0];
  if (!recoveryMember) return null;

  const promoteResp = await supabaseFetch(env, `/rest/v1/group_members?id=eq.${recoveryMember.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ role: await preferredAdminRole(env) }),
  });
  if (!promoteResp.ok) return null;

  return {
    ...recoveryMember,
    role: await preferredAdminRole(env),
  };
}

async function requireAdminOrRecoverableMember(groupId: string, userId: string, env: GroupsEnv) {
  const member = await requireActiveMember(groupId, userId, env);
  if (!member) return null;
  if (isAdminRole(member.role)) return member;
  const recovered = await ensureGroupHasAdminForUser(groupId, userId, env);
  if (recovered?.user_id === userId || recovered?.id === member.id) {
    return {
      ...member,
      role: recovered.role,
    };
  }
  if (!(await hasAnyActiveAdmin(groupId, env))) return member;
  return null;
}

export async function ensureUserProfileAndAcceptInvites(
  authResult: AuthResult,
  env: GroupsEnv
): Promise<void> {
  if (!authResult.authenticated || !authResult.user_id) return;
  const email = cleanEmail(authResult.email);
  if (!email) return;

  const displayName =
    (authResult.name || '').trim() ||
    email.split('@')[0];

  await supabaseFetch(env, '/rest/v1/user_profiles?on_conflict=user_id', {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({
      user_id: authResult.user_id,
      email,
      display_name: displayName,
    }),
  });

  const invitesResp = await supabaseFetch(
    env,
    `/rest/v1/group_invites?email=eq.${encodeURIComponent(email)}&status=eq.pending_signup&select=id,group_id,invited_by`
  );
  if (!invitesResp.ok) return;
  const invites = await readJson<Array<{ id: string; group_id: string; invited_by: string }>>(invitesResp);
  if (!Array.isArray(invites) || invites.length === 0) return;

  for (const invite of invites) {
    await supabaseFetch(env, '/rest/v1/group_members?on_conflict=group_id,user_id', {
      method: 'POST',
      headers: { Prefer: 'resolution=merge-duplicates' },
      body: JSON.stringify({
        group_id: invite.group_id,
        user_id: authResult.user_id,
        role: 'member',
        status: 'active',
        invited_by: invite.invited_by,
        invited_email: email,
        last_seen_at: new Date().toISOString(),
      }),
    });

    await supabaseFetch(env, `/rest/v1/group_invites?id=eq.${invite.id}`, {
      method: 'PATCH',
      body: JSON.stringify({
        status: 'accepted',
        accepted_at: new Date().toISOString(),
      }),
    });

    await supabaseFetch(env, '/rest/v1/notifications', {
      method: 'POST',
      body: JSON.stringify({
        user_id: invite.invited_by,
        type: 'group_invite_accepted',
        title: 'Group invite accepted',
        body: `${displayName} joined your InfoSnap group.`,
        data: { group_id: invite.group_id, user_id: authResult.user_id },
      }),
    });
    await sendPushToUsers(
      pushEnv(env),
      [invite.invited_by],
      'Group invite accepted',
      `${displayName} joined your InfoSnap group.`,
      { type: 'group_invite_accepted', group_id: invite.group_id, user_id: authResult.user_id },
    );
  }
}

async function requireActiveMember(groupId: string, userId: string, env: GroupsEnv) {
  const resp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&user_id=eq.${userId}&status=eq.active&select=id,role,last_seen_at&limit=1`
  );
  if (!resp.ok) return null;
  const rows = await readJson<any[]>(resp);
  return rows?.[0] || null;
}

async function requireActiveAdmin(groupId: string, userId: string, env: GroupsEnv) {
  const member = await requireActiveMember(groupId, userId, env);
  if (!member || !isAdminRole(member.role)) return null;
  return member;
}

async function getActiveMemberByUserId(groupId: string, userId: string, env: GroupsEnv) {
  const resp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&user_id=eq.${userId}&status=eq.active&select=id,user_id,role,status&limit=1`,
  );
  if (!resp.ok) return null;
  const rows = await readJson<any[]>(resp);
  return rows?.[0] || null;
}

async function transferAdminRole(
  groupId: string,
  currentAdminUserId: string,
  nextAdminUserId: string,
  env: GroupsEnv,
): Promise<{ ok: boolean; error?: string }> {
  const current = await getActiveMemberByUserId(groupId, currentAdminUserId, env);
  const target = await getActiveMemberByUserId(groupId, nextAdminUserId, env);
  if (!current) return { ok: false, error: 'Current admin not found' };
  if (!target) return { ok: false, error: 'Select an active member as the next admin' };

  const activeAdminExists = await hasAnyActiveAdmin(groupId, env);
  const currentActsAsAdmin = isAdminRole(current.role) || !activeAdminExists;
  if (!currentActsAsAdmin) return { ok: false, error: 'Current admin not found' };

  const adminRoleValue = isAdminRole(current.role)
      ? (current.role === 'owner' ? 'owner' : 'admin')
      : await preferredAdminRole(env);

  if (currentAdminUserId === nextAdminUserId) {
    if (isAdminRole(current.role)) return { ok: true };
    const selfPromoteResp = await supabaseFetch(env, `/rest/v1/group_members?id=eq.${current.id}`, {
      method: 'PATCH',
      body: JSON.stringify({ role: adminRoleValue }),
    });
    return selfPromoteResp.ok
        ? { ok: true }
        : { ok: false, error: await selfPromoteResp.text() };
  }

  const promoteResp = await supabaseFetch(env, `/rest/v1/group_members?id=eq.${target.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ role: adminRoleValue }),
  });
  if (!promoteResp.ok) return { ok: false, error: await promoteResp.text() };

  if (!isAdminRole(current.role)) return { ok: true };

  const demoteResp = await supabaseFetch(env, `/rest/v1/group_members?id=eq.${current.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ role: 'member' }),
  });
  if (demoteResp.ok) return { ok: true };

  await supabaseFetch(env, `/rest/v1/group_members?id=eq.${target.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ role: 'member' }),
  });
  return { ok: false, error: await demoteResp.text() };
}

async function ensureGroupHasCapacity(groupId: string, env: GroupsEnv): Promise<{ ok: boolean; count: number }> {
  const resp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&status=in.(active,pending)&select=id`
  );
  const rows = resp.ok ? await readJson<any[]>(resp) : [];
  return { ok: rows.length < 10, count: rows.length };
}

async function sendInviteEmail(
  env: GroupsEnv,
  toEmail: string,
  inviterName: string,
  groupName: string
): Promise<{ sent: boolean; error?: string }> {
  if (!env.SENDGRID_API_KEY) {
    return { sent: false, error: 'SENDGRID_API_KEY is not configured' };
  }

  const fromEmail = env.SENDGRID_FROM_EMAIL || 'contact@infosnap.ai';
  const resp = await fetch('https://api.sendgrid.com/v3/mail/send', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.SENDGRID_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      personalizations: [
        {
          to: [{ email: toEmail }],
          subject: `${inviterName} invited you to join an InfoSnap group`,
        },
      ],
      from: { email: fromEmail, name: 'InfoSnap.ai' },
      content: [
        {
          type: 'text/html',
          value: `
            <div style="font-family:Arial,sans-serif;line-height:1.5;color:#172033">
              <h2>You have been invited to InfoSnap.ai</h2>
              <p><strong>${inviterName}</strong> invited you to join the group <strong>${groupName}</strong>.</p>
              <p>Sign in to InfoSnap.ai with this email address and you will automatically be added to the group.</p>
            </div>
          `,
        },
      ],
    }),
  });

  if (!resp.ok) {
    return { sent: false, error: await resp.text() };
  }
  return { sent: true };
}

export async function handleSearchUsers(request: Request, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  await ensureUserProfileAndAcceptInvites(authResult, env);

  const url = new URL(request.url);
  const q = (url.searchParams.get('q') || '').trim();
  if (q.length < 2) return jsonResponse({ users: [] });

  const encoded = encodeURIComponent(`*${q}*`);
  const resp = await supabaseFetch(
    env,
    `/rest/v1/user_profiles?select=user_id,email,display_name,avatar_url&or=(email.ilike.${encoded},display_name.ilike.${encoded})&user_id=neq.${authResult.user_id}&limit=10`
  );
  if (!resp.ok) return jsonResponse({ error: await resp.text() }, 500);
  const profileRows = await readJson<any[]>(resp);
  const byId = new Map<string, any>();
  for (const row of profileRows || []) {
    byId.set(row.user_id, row);
  }

  // Existing users created before this feature may not have user_profiles yet.
  // Fall back to Supabase Auth admin list, then backfill matching profiles.
  const adminResp = await supabaseFetch(env, '/auth/v1/admin/users?page=1&per_page=1000');
  if (adminResp.ok) {
    const adminData = await readJson<{ users?: any[] }>(adminResp);
    const needle = q.toLowerCase();
    for (const user of adminData.users || []) {
      const userId = String(user.id || '');
      const email = cleanEmail(user.email);
      if (!userId || !email || userId === authResult.user_id) continue;
      const meta = user.user_metadata || {};
      const displayName = firstString([meta.full_name, meta.name, email.split('@')[0]]) || email;
      const haystack = `${email} ${displayName}`.toLowerCase();
      if (!haystack.includes(needle)) continue;
      const row = {
        user_id: userId,
        email,
        display_name: displayName,
        avatar_url: firstString([meta.avatar_url, meta.picture]),
      };
      byId.set(userId, row);
      await supabaseFetch(env, '/rest/v1/user_profiles?on_conflict=user_id', {
        method: 'POST',
        headers: { Prefer: 'resolution=merge-duplicates' },
        body: JSON.stringify(row),
      });
      if (byId.size >= 10) break;
    }
  }

  return jsonResponse({ users: Array.from(byId.values()).slice(0, 10) });
}

export async function handleListGroups(authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  await ensureUserProfileAndAcceptInvites(authResult, env);

  const membershipsResp = await supabaseFetch(
    env,
    `/rest/v1/group_members?user_id=eq.${authResult.user_id}&status=in.(active,pending)&select=group_id,last_seen_at,role,status,invited_by`
  );
  if (!membershipsResp.ok) return jsonResponse({ error: await membershipsResp.text() }, 500);
  const memberships = await readJson<Array<{ group_id: string; last_seen_at: string | null; role: string; status: string; invited_by?: string }>>(membershipsResp);
  if (!memberships.length) return jsonResponse({ groups: [] });

  const ids = memberships.map(m => m.group_id);
  const inClause = ids.map(id => `"${escapeRestValue(id)}"`).join(',');
  const supportsActivityColumns = await supportsGroupActivityColumns(env);
  const groupsResp = await supabaseFetch(
    env,
    `/rest/v1/groups?id=in.(${inClause})&select=${supportsActivityColumns ? extendedGroupSelect : baseGroupSelect}${supportsActivityColumns ? '&order=latest_activity_at.desc' : ''}`
  );
  if (!groupsResp.ok) return jsonResponse({ error: await groupsResp.text() }, 500);
  const groups = await withFallbackGroupActivity(env, await readJson<any[]>(groupsResp));

  const profileIds = Array.from(new Set([
    ...memberships.map(m => m.invited_by).filter(Boolean),
    ...groups.map(group => group.latest_activity_user_id).filter(Boolean),
  ])) as string[];
  const profilesById = await listProfilesByIds(env, profileIds);

  const result = await Promise.all(groups.map(async group => {
    const membership = memberships.find(m => m.group_id === group.id);
    const memberCountResp = await supabaseFetch(
      env,
      `/rest/v1/group_members?group_id=eq.${group.id}&status=in.(active,pending)&select=id`
    );
    const memberRows = memberCountResp.ok ? await readJson<any[]>(memberCountResp) : [];

    const lastSeen = membership?.last_seen_at || '1970-01-01T00:00:00.000Z';
    const unreadResp = await supabaseFetch(
      env,
      `/rest/v1/group_snaps?group_id=eq.${group.id}&shared_at=gt.${encodeURIComponent(lastSeen)}&shared_by=neq.${authResult.user_id}&select=id`
    );
    const unreadRows = unreadResp.ok ? await readJson<any[]>(unreadResp) : [];

    return {
      ...group,
      role: membership?.role || 'member',
      status: membership?.status || 'active',
      member_count: memberRows.length,
      unread_count: membership?.status === 'active' ? unreadRows.length : 0,
      invited_by_profile: membership?.invited_by ? profilesById.get(membership.invited_by) || null : null,
      latest_activity_actor_profile: group.latest_activity_user_id
          ? profilesById.get(group.latest_activity_user_id) || null
          : null,
    };
  }));

  return jsonResponse({ groups: result });
}

export async function handleCreateGroup(request: Request, authResult: AuthResult, env: GroupsEnv, ctx: ExecutionContext): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  await ensureUserProfileAndAcceptInvites(authResult, env);
  const body = await request.json() as { name?: string };
  const name = (body.name || '').trim();
  if (name.length < 2) return jsonResponse({ error: 'Group name is required' }, 400);
  if (name.length > 20) return jsonResponse({ error: 'Group name can be at most 20 characters' }, 400);

  const groupResp = await supabaseFetch(env, '/rest/v1/groups', {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify(
      (await supportsGroupActivityColumns(env))
          ? {
              name,
              created_by: authResult.user_id,
              latest_activity_at: new Date().toISOString(),
              latest_activity_type: 'group_created',
              latest_activity_user_id: authResult.user_id,
              latest_activity_title: name,
            }
          : {
              name,
              created_by: authResult.user_id,
            },
    ),
  });
  if (!groupResp.ok) return jsonResponse({ error: await groupResp.text() }, 500);
  const group = (await readJson<any[]>(groupResp))[0];

  const memberResp = await supabaseFetch(env, '/rest/v1/group_members', {
    method: 'POST',
    body: JSON.stringify({
      group_id: group.id,
      user_id: authResult.user_id,
      role: await preferredAdminRole(env),
      status: 'active',
      last_seen_at: new Date().toISOString(),
    }),
  });
  if (!memberResp.ok) return jsonResponse({ error: await memberResp.text() }, 500);
  await broadcastGroupsListChanged(env, authResult.user_id);

  // Audit: new group created. The actor is also the first admin.
  logAudit(env, ctx, request, {
    event_type: 'group.created',
    user_id: authResult.user_id,
    actor_email: authResult.email ?? null,
    resource_type: 'group',
    resource_id: String(group.id),
    details: { name },
  });

  return jsonResponse({ group }, 201);
}

export async function handleGetGroup(groupId: string, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  let member = await requireActiveMember(groupId, authResult.user_id, env);
  if (!member) return jsonResponse({ error: 'Group not found' }, 404);
  const recoveredAdmin = await ensureGroupHasAdminForUser(groupId, authResult.user_id, env);
  if (recoveredAdmin?.user_id === authResult.user_id && !isAdminRole(member.role)) {
    member = { ...member, role: recoveredAdmin.role };
  }

  const supportsActivityColumns = await supportsGroupActivityColumns(env);
  const [groupResp, membersResp, snapsResp, requestsResp] = await Promise.all([
    supabaseFetch(env, `/rest/v1/groups?id=eq.${groupId}&select=${supportsActivityColumns ? extendedGroupSelect : baseGroupSelect}&limit=1`),
    supabaseFetch(env, `/rest/v1/group_members?group_id=eq.${groupId}&status=in.(active,pending)&select=id,user_id,role,status,invited_email,created_at`),
    supabaseFetch(env, `/rest/v1/group_snaps?group_id=eq.${groupId}&select=id,note_id,shared_by,shared_at,title_snapshot,file_type_snapshot,tag_snapshot,thumbnail_url_snapshot,description_snapshot,source_url_snapshot,original_filename_snapshot,blob_url_snapshot,content_preview_snapshot&order=shared_at.desc&limit=20`),
    isAdminRole(member.role)
        ? supabaseFetch(env, `/rest/v1/group_members?group_id=eq.${groupId}&status=eq.requested&select=id,user_id,role,status,invited_email,created_at`)
        : Promise.resolve(new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } })),
  ]);

  if (!groupResp.ok || !membersResp.ok || !snapsResp.ok || !requestsResp.ok) {
    return jsonResponse({ error: 'Failed to fetch group' }, 500);
  }

  const group = (await withFallbackGroupActivity(env, [(await readJson<any[]>(groupResp))[0]].filter(Boolean)))[0];
  const members = await readJson<any[]>(membersResp);
  const snaps = await readJson<any[]>(snapsResp);
  const joinRequests = await readJson<any[]>(requestsResp);

  const userIds = Array.from(new Set([
    ...members.map(m => m.user_id).filter(Boolean),
    ...snaps.map(s => s.shared_by).filter(Boolean),
    ...joinRequests.map(r => r.user_id).filter(Boolean),
    group?.latest_activity_user_id,
  ]));
  const profileById = await listProfilesByIds(env, userIds.filter(Boolean));
  const hydratedMembers = members.map(m => ({ ...m, profile: m.user_id ? profileById.get(m.user_id) || null : null }));
  const hydratedJoinRequests = joinRequests.map(request => ({
    ...request,
    profile: request.user_id ? profileById.get(request.user_id) || null : null,
  }));
  const hydratedSnaps = snaps.map(snap => ({
    ...snap,
    thumbnail_url: snap.thumbnail_url_snapshot || null,
    shared_by_profile: snap.shared_by ? profileById.get(snap.shared_by) || null : null,
  }));

  const snapIds = snaps.map(s => s.id).filter(Boolean);
  let reactionRows: any[] = [];
  if (snapIds.length) {
    const snapIn = snapIds.map(id => `"${escapeRestValue(id)}"`).join(',');
    const reactionsResp = await supabaseFetch(env, `/rest/v1/group_snap_reactions?group_snap_id=in.(${snapIn})&select=group_snap_id,user_id,emoji`);
    reactionRows = reactionsResp.ok ? await readJson<any[]>(reactionsResp) : [];
  }
  const reactionsBySnap = new Map<string, any[]>();
  for (const reaction of reactionRows) {
    const list = reactionsBySnap.get(reaction.group_snap_id) || [];
    list.push(reaction);
    reactionsBySnap.set(reaction.group_snap_id, list);
  }
  for (const snap of hydratedSnaps) {
    const rows = reactionsBySnap.get(snap.id) || [];
    snap.my_reaction = rows.find(r => r.user_id === authResult.user_id)?.emoji || null;
    const counts: Record<string, number> = {};
    for (const row of rows) counts[row.emoji] = (counts[row.emoji] || 0) + 1;
    snap.reactions = counts;
  }

  await supabaseFetch(env, `/rest/v1/group_members?id=eq.${member.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ last_seen_at: new Date().toISOString() }),
  });

  return jsonResponse({
    group: {
      ...group,
      role: member.role,
      status: 'active',
      latest_activity_actor_profile: group?.latest_activity_user_id
          ? profileById.get(group.latest_activity_user_id) || null
          : null,
    },
    members: hydratedMembers,
    join_requests: hydratedJoinRequests,
    snaps: hydratedSnaps,
  });
}

export async function handleDiscoverGroups(request: Request, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const url = new URL(request.url);
  const q = (url.searchParams.get('q') || '').trim();
  if (q.length < 2) return jsonResponse({ groups: [] });

  const encoded = encodeURIComponent(`*${q}*`);
  const supportsActivityColumns = await supportsGroupActivityColumns(env);
  const groupsResp = await supabaseFetch(
    env,
    `/rest/v1/groups?name=ilike.${encoded}&select=${supportsActivityColumns ? extendedGroupSelect : baseGroupSelect}${supportsActivityColumns ? '&order=latest_activity_at.desc' : ''}&limit=20`,
  );
  if (!groupsResp.ok) return jsonResponse({ error: await groupsResp.text() }, 500);
  const groups = await withFallbackGroupActivity(env, await readJson<any[]>(groupsResp));
  if (!groups.length) return jsonResponse({ groups: [] });

  const groupIds = groups.map(group => group.id);
  const inClause = groupIds.map(id => `"${escapeRestValue(id)}"`).join(',');
  const [myMembershipsResp, membersResp, profilesById] = await Promise.all([
    supabaseFetch(
      env,
      `/rest/v1/group_members?group_id=in.(${inClause})&user_id=eq.${authResult.user_id}&select=group_id,status,role`,
    ),
    supabaseFetch(
      env,
      `/rest/v1/group_members?group_id=in.(${inClause})&status=in.(active,pending)&select=group_id,id`,
    ),
    listProfilesByIds(env, Array.from(new Set(groups.map(group => group.latest_activity_user_id).filter(Boolean))) as string[]),
  ]);
  const myMemberships = myMembershipsResp.ok ? await readJson<any[]>(myMembershipsResp) : [];
  const memberRows = membersResp.ok ? await readJson<any[]>(membersResp) : [];
  const membershipByGroupId = new Map((myMemberships || []).map(row => [row.group_id, row]));
  const memberCountByGroupId = new Map<string, number>();
  for (const row of memberRows || []) {
    memberCountByGroupId.set(row.group_id, (memberCountByGroupId.get(row.group_id) || 0) + 1);
  }

  return jsonResponse({
    groups: groups
      .map(group => ({
        ...group,
        member_count: memberCountByGroupId.get(group.id) || 0,
        relationship_status: membershipByGroupId.get(group.id)?.status || 'none',
        latest_activity_actor_profile: group.latest_activity_user_id
            ? profilesById.get(group.latest_activity_user_id) || null
            : null,
      }))
      .filter(group => (group.member_count || 0) > 0),
  });
}

export async function handleRequestToJoinGroup(groupId: string, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  await ensureUserProfileAndAcceptInvites(authResult, env);
  const group = await getGroupRecord(env, groupId);
  if (!group) return jsonResponse({ error: 'Group not found' }, 404);

  const existingResp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&user_id=eq.${authResult.user_id}&select=id,status&limit=1`,
  );
  const existingRows = existingResp.ok ? await readJson<any[]>(existingResp) : [];
  const existing = existingRows?.[0];
  if (existing && existing.status === 'active') {
    return jsonResponse({ requested: false, already_member: true, relationship_status: 'active' });
  }
  if (existing && ['pending', 'requested'].includes(existing.status)) {
    return jsonResponse({ requested: true, relationship_status: 'requested' });
  }

  if (existing) {
    const patchResp = await supabaseFetch(env, `/rest/v1/group_members?id=eq.${existing.id}`, {
      method: 'PATCH',
      body: JSON.stringify({ status: 'requested' }),
    });
    if (!patchResp.ok) return jsonResponse({ error: await patchResp.text() }, 400);
  } else {
    const insertResp = await supabaseFetch(env, '/rest/v1/group_members', {
      method: 'POST',
      body: JSON.stringify({
        group_id: groupId,
        user_id: authResult.user_id,
        role: 'member',
        status: 'requested',
      }),
    });
    if (!insertResp.ok) return jsonResponse({ error: await insertResp.text() }, 400);
  }

  const adminsResp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&status=eq.active&select=user_id,role`,
  );
  const admins = adminsResp.ok ? await readJson<Array<{ user_id?: string; role?: string }>>(adminsResp) : [];
  const adminIds = admins.filter(row => isAdminRole(row.role)).map(row => row.user_id).filter(Boolean) as string[];
  const requesterName = actorName(authResult);
  if (adminIds.length) {
    await Promise.all(adminIds.map(async adminId => {
      await supabaseFetch(env, '/rest/v1/notifications', {
        method: 'POST',
        body: JSON.stringify({
          user_id: adminId,
          type: 'group_join_request',
          title: 'Group join request',
          body: `${requesterName} wants to join ${group.name}.`,
          data: { group_id: groupId, requester_user_id: authResult.user_id },
        }),
      });
    }));
    await sendPushToUsers(
      pushEnv(env),
      adminIds,
      'Group join request',
      `${requesterName} wants to join ${group.name}.`,
      { type: 'group_join_request', group_id: groupId, requester_user_id: authResult.user_id },
    );
  }
  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_join_request',
      userId: authResult.user_id,
      title: group.name,
      description: `${requesterName} requested to join`,
    }),
    broadcastGroupChanged(env, groupId),
    broadcastGroupListsChanged(env, groupId),
  ]);
  return jsonResponse({ requested: true });
}

export async function handleApproveJoinRequest(groupId: string, requestId: string, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const admin = await requireActiveAdmin(groupId, authResult.user_id, env);
  if (!admin) return jsonResponse({ error: 'Only the group admin can approve requests' }, 403);
  const capacity = await ensureGroupHasCapacity(groupId, env);
  if (!capacity.ok) return jsonResponse({ error: 'A group can have at most 10 members' }, 400);

  const reqResp = await supabaseFetch(
    env,
    `/rest/v1/group_members?id=eq.${requestId}&group_id=eq.${groupId}&status=eq.requested&select=id,user_id&limit=1`,
  );
  const rows = reqResp.ok ? await readJson<any[]>(reqResp) : [];
  const joinRequest = rows?.[0];
  if (!joinRequest) return jsonResponse({ error: 'Join request not found' }, 404);

  const patchResp = await supabaseFetch(env, `/rest/v1/group_members?id=eq.${requestId}`, {
    method: 'PATCH',
    body: JSON.stringify({ status: 'active', last_seen_at: new Date().toISOString() }),
  });
  if (!patchResp.ok) return jsonResponse({ error: await patchResp.text() }, 400);

  if (joinRequest.user_id) {
    await supabaseFetch(env, '/rest/v1/notifications', {
      method: 'POST',
      body: JSON.stringify({
        user_id: joinRequest.user_id,
        type: 'group_join_request_accepted',
        title: 'Join request accepted',
        body: `You are now a member of ${(await getGroupName(env, groupId))}.`,
        data: { group_id: groupId },
      }),
    });
    await sendPushToUsers(
      pushEnv(env),
      [joinRequest.user_id],
      'Join request accepted',
      `You are now a member of ${(await getGroupName(env, groupId))}.`,
      { type: 'group_join_request_accepted', group_id: groupId },
    );
  }

  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_join_accepted',
      userId: authResult.user_id,
      title: 'Join request accepted',
    }),
    broadcastGroupChanged(env, groupId),
    broadcastGroupListsChanged(env, groupId),
    joinRequest.user_id ? broadcastGroupsListChanged(env, joinRequest.user_id) : Promise.resolve(),
  ]);
  return jsonResponse({ approved: true });
}

export async function handleDenyJoinRequest(groupId: string, requestId: string, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const admin = await requireActiveAdmin(groupId, authResult.user_id, env);
  if (!admin) return jsonResponse({ error: 'Only the group admin can deny requests' }, 403);

  const reqResp = await supabaseFetch(
    env,
    `/rest/v1/group_members?id=eq.${requestId}&group_id=eq.${groupId}&status=eq.requested&select=id,user_id&limit=1`,
  );
  const rows = reqResp.ok ? await readJson<any[]>(reqResp) : [];
  const joinRequest = rows?.[0];
  if (!joinRequest) return jsonResponse({ error: 'Join request not found' }, 404);

  const patchResp = await supabaseFetch(env, `/rest/v1/group_members?id=eq.${requestId}`, {
    method: 'PATCH',
    body: JSON.stringify({ status: 'declined' }),
  });
  if (!patchResp.ok) return jsonResponse({ error: await patchResp.text() }, 400);

  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_join_denied',
      userId: authResult.user_id,
      title: 'Join request denied',
    }),
    broadcastGroupChanged(env, groupId),
    broadcastGroupListsChanged(env, groupId),
    joinRequest.user_id ? broadcastGroupsListChanged(env, joinRequest.user_id) : Promise.resolve(),
  ]);
  return jsonResponse({ denied: true });
}

export async function handleTransferGroupAdmin(groupId: string, request: Request, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const admin = await requireAdminOrRecoverableMember(groupId, authResult.user_id, env);
  if (!admin) return jsonResponse({ error: 'Only the group admin can transfer admin role' }, 403);

  const body = await request.json() as { user_id?: string };
  const nextAdminUserId = (body.user_id || '').trim();
  if (!nextAdminUserId) return jsonResponse({ error: 'user_id is required' }, 400);

  const result = await transferAdminRole(groupId, authResult.user_id, nextAdminUserId, env);
  if (!result.ok) return jsonResponse({ error: result.error || 'Could not transfer admin role' }, 400);
  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_admin_transfer',
      userId: authResult.user_id,
      title: 'Admin transferred',
    }),
    broadcastGroupChanged(env, groupId),
    broadcastGroupListsChanged(env, groupId),
  ]);
  return jsonResponse({ transferred: true });
}

async function uploadUserAvatar(
  env: GroupsEnv,
  userId: string,
  bytes: ArrayBuffer,
  filename: string,
  contentType: string,
): Promise<string> {
  const parsed = parseConnectionString(env.AZURE_STORAGE_CONNECTION_STRING);
  if (!parsed) throw new Error('Azure storage connection string is not configured');
  const container = thumbnailContainerName(env);
  await ensurePublicThumbnailContainer(env, container).catch(error => {
    console.warn('USER_AVATAR_CONTAINER_ENSURE_FAILED', error);
  });
  const ext = (filename.includes('.') ? filename.split('.').pop() : 'jpg') || 'jpg';
  const blobName = `users/${userId}/avatars/${Date.now()}_${crypto.randomUUID()}.${ext}`;
  const url = `https://${parsed.accountName}.blob.core.windows.net/${container}/${blobName}`;
  const headers: Record<string, string> = {
    'Content-Type': contentType,
    'Cache-Control': 'public, max-age=31536000, immutable',
    'x-ms-blob-type': 'BlockBlob',
    'x-ms-date': new Date().toUTCString(),
    'x-ms-version': '2020-10-02',
  };
  const authHeader = await createSharedKeyAuth(
    parsed.accountName,
    parsed.accountKey,
    'PUT',
    url,
    headers,
    bytes.byteLength,
  );
  const resp = await fetch(url, {
    method: 'PUT',
    headers: { ...headers, Authorization: authHeader, 'Content-Length': bytes.byteLength.toString() },
    body: bytes,
  });
  if (!resp.ok) {
    const text = await resp.text().catch(() => '');
    throw new Error(`User avatar upload failed: ${resp.status} ${text.slice(0, 160)}`);
  }
  return url;
}

export async function handleUploadUserAvatar(request: Request, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  await ensureUserProfileAndAcceptInvites(authResult, env);

  const body = await request.json() as {
    filename?: string;
    content_type?: string;
    bytes_base64?: string;
  };
  const filename = firstString([body.filename]) || 'avatar.jpg';
  const contentType = firstString([body.content_type]) || 'image/jpeg';
  const base64 = firstString([body.bytes_base64]);
  if (!base64) return jsonResponse({ error: 'Image bytes are required' }, 400);
  if (!contentType.startsWith('image/')) return jsonResponse({ error: 'Only image uploads are supported' }, 400);

  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  if (bytes.byteLength > 5 * 1024 * 1024) {
    return jsonResponse({ error: 'Profile image must be 5MB or smaller' }, 400);
  }

  const avatarUrl = await uploadUserAvatar(env, authResult.user_id, bytes.buffer, filename, contentType);
  const patchResp = await supabaseFetch(env, `/rest/v1/user_profiles?user_id=eq.${authResult.user_id}`, {
    method: 'PATCH',
    body: JSON.stringify({ avatar_url: avatarUrl }),
  });
  if (!patchResp.ok) return jsonResponse({ error: await patchResp.text() }, 400);
  return jsonResponse({ avatar_url: avatarUrl });
}

export async function handleUploadGroupAvatar(groupId: string, request: Request, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const admin = await requireAdminOrRecoverableMember(groupId, authResult.user_id, env);
  if (!admin) return jsonResponse({ error: 'Only the group admin can update the group image' }, 403);

  const body = await request.json() as {
    filename?: string;
    content_type?: string;
    bytes_base64?: string;
  };
  const filename = firstString([body.filename]) || 'group-avatar.jpg';
  const contentType = firstString([body.content_type]) || 'image/jpeg';
  const base64 = firstString([body.bytes_base64]);
  if (!base64) return jsonResponse({ error: 'Image bytes are required' }, 400);
  if (!contentType.startsWith('image/')) return jsonResponse({ error: 'Only image uploads are supported' }, 400);

  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  if (bytes.byteLength > 5 * 1024 * 1024) {
    return jsonResponse({ error: 'Group image must be 5MB or smaller' }, 400);
  }

  const avatarUrl = await uploadGroupAvatar(env, groupId, authResult.user_id, bytes.buffer, filename, contentType);
  const patchResp = await supabaseFetch(env, `/rest/v1/groups?id=eq.${groupId}`, {
    method: 'PATCH',
    body: JSON.stringify({ avatar_url: avatarUrl }),
  });
  if (!patchResp.ok) return jsonResponse({ error: await patchResp.text() }, 400);

  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_avatar_updated',
      userId: authResult.user_id,
      title: 'Group image updated',
    }),
    broadcastGroupChanged(env, groupId),
    broadcastGroupListsChanged(env, groupId),
  ]);
  return jsonResponse({ avatar_url: avatarUrl });
}

export async function handleInviteToGroup(groupId: string, request: Request, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const currentMember = await requireActiveMember(groupId, authResult.user_id, env);
  if (!currentMember) return jsonResponse({ error: 'Group not found' }, 404);

  const body = await request.json() as { user_id?: string; email?: string };
  const email = cleanEmail(body.email);
  const userId = (body.user_id || '').trim();

  const groupResp = await supabaseFetch(env, `/rest/v1/groups?id=eq.${groupId}&select=id,name&limit=1`);
  const group = groupResp.ok ? (await readJson<any[]>(groupResp))[0] : null;
  if (!group) return jsonResponse({ error: 'Group not found' }, 404);

  if (userId) {
    const capacity = await ensureGroupHasCapacity(groupId, env);
    if (!capacity.ok) {
      return jsonResponse({ error: 'A group can have at most 10 members' }, 400);
    }
    const insertResp = await supabaseFetch(env, '/rest/v1/group_members', {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      body: JSON.stringify({
        group_id: groupId,
        user_id: userId,
        role: 'member',
        status: 'pending',
        invited_by: authResult.user_id,
      }),
    });
    if (!insertResp.ok) return jsonResponse({ error: await insertResp.text() }, 400);

    await supabaseFetch(env, '/rest/v1/notifications', {
      method: 'POST',
      body: JSON.stringify({
        user_id: userId,
        type: 'group_invite',
        title: 'Group invite',
        body: `${authResult.name || authResult.email || 'Someone'} invited you to join ${group.name}.`,
        data: { group_id: groupId },
      }),
    });
    await sendPushToUsers(
      pushEnv(env),
      [userId],
      'Group invite',
      `${actorName(authResult)} invited you to join ${group.name}.`,
      { type: 'group_invite', group_id: groupId },
    );
    await Promise.all([
      updateGroupActivity(env, groupId, {
        type: 'group_invite',
        userId: authResult.user_id,
        title: group.name,
        description: `Invited ${userId}`,
      }),
      broadcastGroupChanged(env, groupId),
      broadcastGroupsListChanged(env, userId),
      broadcastGroupsListChanged(env, authResult.user_id),
    ]);
    return jsonResponse({ invited: true });
  }

  if (!email) return jsonResponse({ error: 'Provide user_id or email' }, 400);

  const capacity = await ensureGroupHasCapacity(groupId, env);
  if (!capacity.ok) {
    return jsonResponse({ error: 'A group can have at most 10 members' }, 400);
  }

  const inviteResp = await supabaseFetch(env, '/rest/v1/group_invites', {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify({
      group_id: groupId,
      email,
      invited_by: authResult.user_id,
      status: 'pending_signup',
    }),
  });
  if (!inviteResp.ok) return jsonResponse({ error: await inviteResp.text() }, 400);

  await supabaseFetch(env, '/rest/v1/group_members', {
    method: 'POST',
    body: JSON.stringify({
      group_id: groupId,
      role: 'member',
      status: 'pending',
      invited_by: authResult.user_id,
      invited_email: email,
    }),
  });

  const emailResult = await sendInviteEmail(
    env,
    email,
    authResult.name || authResult.email || 'An InfoSnap user',
    group.name
  );
  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_invite',
      userId: authResult.user_id,
      title: group.name,
      description: `Invited ${email}`,
    }),
    broadcastGroupChanged(env, groupId),
    broadcastGroupsListChanged(env, authResult.user_id),
  ]);
  return jsonResponse({ invited: true, email_sent: emailResult.sent, email_error: emailResult.error || null });
}

export async function handleAcceptGroupInvite(groupId: string, authResult: AuthResult, env: GroupsEnv, ctx: ExecutionContext, request: Request): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const resp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&user_id=eq.${authResult.user_id}&status=eq.pending&select=id,invited_by&limit=1`
  );
  const rows = resp.ok ? await readJson<any[]>(resp) : [];
  const member = rows[0];
  if (!member) return jsonResponse({ error: 'Invite not found' }, 404);

  await supabaseFetch(env, `/rest/v1/group_members?id=eq.${member.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ status: 'active', last_seen_at: new Date().toISOString() }),
  });
  if (member.invited_by) {
    await supabaseFetch(env, '/rest/v1/notifications', {
      method: 'POST',
      body: JSON.stringify({
        user_id: member.invited_by,
        type: 'group_invite_accepted',
        title: 'Group invite accepted',
        body: `${authResult.name || authResult.email || 'A user'} accepted your group invite.`,
        data: { group_id: groupId },
      }),
    });
    await sendPushToUsers(
      pushEnv(env),
      [member.invited_by],
      'Group invite accepted',
      `${actorName(authResult)} accepted your group invite.`,
      { type: 'group_invite_accepted', group_id: groupId },
    );
  }
  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_invite_accepted',
      userId: authResult.user_id,
      title: 'Invite accepted',
    }),
    broadcastGroupChanged(env, groupId),
    broadcastGroupsListChanged(env, authResult.user_id),
    member.invited_by ? broadcastGroupsListChanged(env, member.invited_by) : Promise.resolve(),
  ]);

  // Audit: invite accepted. Records both who accepted and who invited
  // (the latter via details since resource_id is the group itself).
  logAudit(env, ctx, request, {
    event_type: 'group.invite_accepted',
    user_id: authResult.user_id,
    actor_email: authResult.email ?? null,
    resource_type: 'group',
    resource_id: groupId,
    details: { invited_by: member.invited_by ?? null },
  });

  return jsonResponse({ accepted: true });
}

export async function handleDeclineGroupInvite(groupId: string, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const existingResp = await supabaseFetch(
    env,
    `/rest/v1/group_members?group_id=eq.${groupId}&user_id=eq.${authResult.user_id}&status=eq.pending&select=invited_by&limit=1`
  );
  const existingRows = existingResp.ok ? await readJson<any[]>(existingResp) : [];
  const invitedBy = existingRows[0]?.invited_by as string | undefined;
  await supabaseFetch(env, `/rest/v1/group_members?group_id=eq.${groupId}&user_id=eq.${authResult.user_id}&status=eq.pending`, {
    method: 'PATCH',
    body: JSON.stringify({ status: 'declined' }),
  });
  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_invite_declined',
      userId: authResult.user_id,
      title: 'Invite declined',
    }),
    broadcastGroupChanged(env, groupId),
    broadcastGroupsListChanged(env, authResult.user_id),
    invitedBy ? broadcastGroupsListChanged(env, invitedBy) : Promise.resolve(),
  ]);
  return jsonResponse({ declined: true });
}

export async function handleShareSnapToGroup(groupId: string, request: Request, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const member = await requireActiveMember(groupId, authResult.user_id, env);
  if (!member) return jsonResponse({ error: 'Group not found' }, 404);

  const body = await request.json() as { note_id?: string };
  const noteId = (body.note_id || '').trim();
  if (!noteId) return jsonResponse({ error: 'note_id is required' }, 400);

  const noteResp = await supabaseFetch(
    env,
    `/rest/v1/notes?id=eq.${noteId}&user_id=eq.${authResult.user_id}&status=eq.active&select=id,title,short_title,file_type,tag,metadata,description,original_filename,blob_url,content_markdown&limit=1`
  );
  const notes = noteResp.ok ? await readJson<any[]>(noteResp) : [];
  const note = notes[0];
  if (!note) return jsonResponse({ error: 'Snap not found or not shareable' }, 404);

  const metadata = note.metadata || {};
  const social = metadata.social || {};
  const redditCanonicalUrl =
    (social.source || social.source_app) === 'reddit' &&
    social.post_id &&
    social.subreddit
      ? `https://www.reddit.com/r/${social.subreddit}/comments/${social.post_id}/`
      : null;
  const sourceUrl = firstString([
    redditCanonicalUrl,
    social.source_url,
    social.url,
    social.permalink,
    social.web_url,
    metadata.source_url,
    metadata.url,
  ]);
  const description = firstString([
    note.description,
    metadata.content_preview,
    metadata.excerpt,
    social.caption,
    social.description,
  ]);
  const preview = firstString([
    note.description,
    metadata.content_preview,
    metadata.excerpt,
    note.content_markdown,
  ]);
  const originalFilename = String(note.original_filename || '').toLowerCase();
  const isImageUpload =
    note.file_type === 'image' ||
    note.file_type === 'screenshot' ||
    (note.file_type === 'uploaded_file' &&
      /\.(jpg|jpeg|png|gif|webp|heic|bmp|svg)$/i.test(originalFilename));
  const thumbnailUrl = firstString([
    metadata.thumbnail_url,
    metadata.preview_image_url,
    metadata.thumbnail_blob_url,
    metadata.screenshot_url,
    social.thumbnail_url,
    isImageUpload ? note.blob_url : null,
  ]);
  const insertResp = await supabaseFetch(env, '/rest/v1/group_snaps', {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify({
      group_id: groupId,
      note_id: noteId,
      shared_by: authResult.user_id,
      title_snapshot: note.short_title || note.title || 'Untitled snap',
      file_type_snapshot: note.file_type,
      tag_snapshot: note.tag,
      thumbnail_url_snapshot: thumbnailUrl || null,
      description_snapshot: description,
      source_url_snapshot: sourceUrl,
      original_filename_snapshot: note.original_filename || null,
      blob_url_snapshot: note.blob_url || null,
      content_preview_snapshot: preview,
    }),
  });
  if (!insertResp.ok) return jsonResponse({ error: await insertResp.text() }, 400);

  const snap = (await readJson<any[]>(insertResp))[0];
  const recipients = (await listActiveGroupUserIds(env, groupId))
    .filter(userId => userId !== authResult.user_id);
  if (recipients.length) {
    const groupName = await getGroupName(env, groupId);
    await sendPushToUsers(
      pushEnv(env),
      recipients,
      'New snap shared',
      `${actorName(authResult)} shared "${snap.title_snapshot || 'a snap'}" in ${groupName}.`,
      { type: 'group_snap', group_id: groupId, snap_id: snap.id, note_id: noteId },
    );
  }
  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_snap',
      userId: authResult.user_id,
      title: snap.title_snapshot || 'Untitled snap',
      description: description,
      fileType: note.file_type || null,
      occurredAt: snap.shared_at || new Date().toISOString(),
    }),
    broadcastGroupChanged(env, groupId),
    broadcastGroupListsChanged(env, groupId),
  ]);
  return jsonResponse({ shared: true, snap });
}

export async function handleReactToGroupSnap(groupId: string, snapId: string, request: Request, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const member = await requireActiveMember(groupId, authResult.user_id, env);
  if (!member) return jsonResponse({ error: 'Group not found' }, 404);

  const body = await request.json() as { emoji?: string | null };
  const emoji = (body.emoji || '').trim();
  const allowed = new Set(['👍', '❤️', '😂', '😮', '🔥']);

  const snapResp = await supabaseFetch(env, `/rest/v1/group_snaps?id=eq.${snapId}&group_id=eq.${groupId}&select=id,shared_by,title_snapshot&limit=1`);
  const snapRows = snapResp.ok ? await readJson<any[]>(snapResp) : [];
  if (!snapRows.length) return jsonResponse({ error: 'Snap not found' }, 404);
  const previousResp = await supabaseFetch(
    env,
    `/rest/v1/group_snap_reactions?group_snap_id=eq.${snapId}&user_id=eq.${authResult.user_id}&select=emoji&limit=1`,
  );
  const previousRows = previousResp.ok ? await readJson<any[]>(previousResp) : [];
  const previousEmoji = (previousRows[0]?.emoji || '').toString().trim() || null;

  if (!emoji) {
    await supabaseFetch(env, `/rest/v1/group_snap_reactions?group_snap_id=eq.${snapId}&user_id=eq.${authResult.user_id}`, {
      method: 'DELETE',
    });
    if (previousEmoji) {
      await broadcastGroupReactionChanged(env, groupId, snapId, authResult.user_id, previousEmoji, 'remove');
    }
    return jsonResponse({ reacted: false, emoji: null });
  }
  if (!allowed.has(emoji)) return jsonResponse({ error: 'Unsupported reaction' }, 400);
  if (previousEmoji === emoji) {
    return jsonResponse({ reacted: true, emoji });
  }

  const upsertResp = await supabaseFetch(env, '/rest/v1/group_snap_reactions?on_conflict=group_snap_id,user_id', {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates,return=representation' },
    body: JSON.stringify({
      group_snap_id: snapId,
      user_id: authResult.user_id,
      emoji,
      updated_at: new Date().toISOString(),
    }),
  });
  if (!upsertResp.ok) return jsonResponse({ error: await upsertResp.text() }, 400);
  const ownerId = snapRows[0]?.shared_by as string | undefined;
  if (ownerId && ownerId !== authResult.user_id) {
    await sendPushToUsers(
      pushEnv(env),
      [ownerId],
      'New reaction',
      `${actorName(authResult)} reacted ${emoji} to your snap.`,
      { type: 'group_reaction', group_id: groupId, snap_id: snapId, emoji },
    );
  }
  const broadcasts: Promise<void>[] = [];
  if (previousEmoji && previousEmoji !== emoji) {
    broadcasts.push(broadcastGroupReactionChanged(env, groupId, snapId, authResult.user_id, previousEmoji, 'remove'));
  }
  broadcasts.push(broadcastGroupReactionChanged(env, groupId, snapId, authResult.user_id, emoji, 'add'));

  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_reaction',
      userId: authResult.user_id,
      title: snapRows[0]?.title_snapshot || 'a snap',
      fileType: snapRows[0]?.file_type_snapshot || null,
      description: `${emoji} reaction`,
    }),
    ...broadcasts,
  ]);
  return jsonResponse({ reacted: true, emoji });
}

export async function handleMarkGroupSeen(groupId: string, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const member = await requireActiveMember(groupId, authResult.user_id, env);
  if (!member) return jsonResponse({ error: 'Group not found' }, 404);
  await supabaseFetch(env, `/rest/v1/group_members?id=eq.${member.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ last_seen_at: new Date().toISOString() }),
  });
  return jsonResponse({ seen: true });
}

export async function handleLeaveGroup(groupId: string, request: Request, authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const member = await requireActiveMember(groupId, authResult.user_id, env);
  if (!member) return jsonResponse({ error: 'Group not found' }, 404);
  if (isAdminRole(member.role)) {
    const groupMembersResp = await supabaseFetch(
      env,
      `/rest/v1/group_members?group_id=eq.${groupId}&status=eq.active&select=user_id,role`,
    );
    const activeMembers = groupMembersResp.ok ? await readJson<any[]>(groupMembersResp) : [];
    const otherActiveMembers = activeMembers.filter(activeMember => activeMember.user_id !== authResult.user_id);
    if (!otherActiveMembers.length) {
      return jsonResponse({ error: 'Add another member before the admin can leave the group' }, 400);
    }

    const url = new URL(request.url);
    let successorUserId = url.searchParams.get('successor_user_id') || '';
    if (!successorUserId) {
      const bodyText = await request.text();
      if (bodyText) {
        try {
          const body = JSON.parse(bodyText) as { successor_user_id?: string };
          successorUserId = (body.successor_user_id || '').trim();
        } catch {
          successorUserId = '';
        }
      }
    }
    if (!successorUserId) {
      return jsonResponse({ error: 'The admin must select the next admin before leaving' }, 400);
    }
    const transferResult = await transferAdminRole(groupId, authResult.user_id, successorUserId, env);
    if (!transferResult.ok) {
      return jsonResponse({ error: transferResult.error || 'Could not transfer admin role' }, 400);
    }
  }
  const leaveResp = await supabaseFetch(env, `/rest/v1/group_members?id=eq.${member.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ status: 'left' }),
  });
  if (!leaveResp.ok) return jsonResponse({ error: await leaveResp.text() }, 400);
  await Promise.all([
    updateGroupActivity(env, groupId, {
      type: 'group_member_left',
      userId: authResult.user_id,
      title: 'Member left',
    }),
    broadcastGroupChanged(env, groupId),
    broadcastGroupListsChanged(env, groupId),
    broadcastGroupsListChanged(env, authResult.user_id),
  ]);
  return jsonResponse({ left: true });
}

export async function handleListNotifications(authResult: AuthResult, env: GroupsEnv): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) return unauthorized();
  const resp = await supabaseFetch(
    env,
    `/rest/v1/notifications?user_id=eq.${authResult.user_id}&select=id,type,title,body,data,read_at,created_at&order=created_at.desc&limit=50`
  );
  if (!resp.ok) return jsonResponse({ error: await resp.text() }, 500);
  return jsonResponse({ notifications: await readJson(resp) });
}
