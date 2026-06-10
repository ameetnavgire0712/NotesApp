import { AuthResult } from './auth';

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
};

export interface PushEnv {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  FIREBASE_PROJECT_ID?: string;
  FIREBASE_CLIENT_EMAIL?: string;
  FIREBASE_PRIVATE_KEY?: string;
}

type PushData = Record<string, string | number | boolean | null | undefined>;

let cachedAccessToken: { token: string; expiresAt: number } | null = null;

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

function base64Url(input: ArrayBuffer | Uint8Array | string): string {
  let bytes: Uint8Array;
  if (typeof input === 'string') {
    bytes = new TextEncoder().encode(input);
  } else if (input instanceof Uint8Array) {
    bytes = input;
  } else {
    bytes = new Uint8Array(input);
  }
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function normalizePrivateKey(key: string): string {
  return key.replace(/\\n/g, '\n').trim();
}

async function importPrivateKey(privateKeyPem: string): Promise<CryptoKey> {
  const pem = normalizePrivateKey(privateKeyPem)
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s/g, '');
  const binary = atob(pem);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return crypto.subtle.importKey(
    'pkcs8',
    bytes,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}

async function getFirebaseAccessToken(env: PushEnv): Promise<string | null> {
  if (!env.FIREBASE_CLIENT_EMAIL || !env.FIREBASE_PRIVATE_KEY) return null;
  const now = Math.floor(Date.now() / 1000);
  if (cachedAccessToken && cachedAccessToken.expiresAt - 60 > now) {
    return cachedAccessToken.token;
  }

  const header = { alg: 'RS256', typ: 'JWT' };
  const claim = {
    iss: env.FIREBASE_CLIENT_EMAIL,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64Url(JSON.stringify(header))}.${base64Url(JSON.stringify(claim))}`;
  const key = await importPrivateKey(env.FIREBASE_PRIVATE_KEY);
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(unsigned),
  );
  const assertion = `${unsigned}.${base64Url(signature)}`;

  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!resp.ok) {
    console.warn('FCM_ACCESS_TOKEN_FAILED', resp.status, await resp.text());
    return null;
  }
  const json = await resp.json() as { access_token?: string; expires_in?: number };
  if (!json.access_token) return null;
  cachedAccessToken = {
    token: json.access_token,
    expiresAt: now + (json.expires_in || 3600),
  };
  return json.access_token;
}

async function supabaseFetch(
  env: PushEnv,
  path: string,
  init: RequestInit = {},
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

function sanitizeData(data: PushData): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [key, value] of Object.entries(data)) {
    if (value === undefined || value === null) continue;
    result[key] = String(value);
  }
  return result;
}

export async function handleRegisterDeviceToken(
  request: Request,
  authResult: AuthResult,
  env: PushEnv,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return jsonResponse({ error: 'Unauthorized' }, 401);
  }
  const body = await request.json() as {
    token?: string;
    platform?: string;
    app_version?: string;
    device_id?: string;
  };
  const token = (body.token || '').trim();
  if (!token || token.length < 20) {
    return jsonResponse({ error: 'Valid token is required' }, 400);
  }

  const resp = await supabaseFetch(env, '/rest/v1/device_tokens?on_conflict=user_id,token', {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    body: JSON.stringify({
      user_id: authResult.user_id,
      token,
      platform: (body.platform || 'android').trim().toLowerCase(),
      app_version: body.app_version || null,
      device_id: body.device_id || null,
      enabled: true,
      last_seen_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }),
  });
  if (!resp.ok) return jsonResponse({ error: await resp.text() }, 500);
  return jsonResponse({ registered: true });
}

async function disableToken(env: PushEnv, token: string): Promise<void> {
  await supabaseFetch(
    env,
    `/rest/v1/device_tokens?token=eq.${encodeURIComponent(token)}`,
    {
      method: 'PATCH',
      body: JSON.stringify({ enabled: false, updated_at: new Date().toISOString() }),
    },
  );
}

export async function sendPushToUsers(
  env: PushEnv,
  userIds: string[],
  title: string,
  body: string,
  data: PushData = {},
): Promise<void> {
  const uniqueUserIds = Array.from(new Set(userIds.filter(Boolean)));
  if (!uniqueUserIds.length) return;
  if (!env.FIREBASE_PROJECT_ID) {
    console.warn('FCM_SKIPPED_MISSING_PROJECT_ID');
    return;
  }
  const accessToken = await getFirebaseAccessToken(env);
  if (!accessToken) {
    console.warn('FCM_SKIPPED_MISSING_ACCESS_TOKEN');
    return;
  }

  const inClause = uniqueUserIds.map(id => `"${id.replace(/"/g, '\\"')}"`).join(',');
  const tokenResp = await supabaseFetch(
    env,
    `/rest/v1/device_tokens?user_id=in.(${inClause})&enabled=eq.true&select=token,user_id`,
  );
  if (!tokenResp.ok) {
    console.warn('FCM_DEVICE_TOKEN_FETCH_FAILED', await tokenResp.text());
    return;
  }
  const rows = await readJson<Array<{ token: string; user_id: string }>>(tokenResp);
  const tokens = Array.from(new Set((rows || []).map(row => row.token).filter(Boolean)));
  if (!tokens.length) return;

  const endpoint =
    `https://fcm.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/messages:send`;
  await Promise.all(tokens.map(async token => {
    try {
      const resp = await fetch(endpoint, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            token,
            notification: { title, body },
            data: sanitizeData(data),
            android: {
              priority: 'HIGH',
              notification: {
                channel_id: 'infosnap_updates',
                sound: 'default',
              },
            },
          },
        }),
      });
      if (!resp.ok) {
        const text = await resp.text();
        console.warn('FCM_SEND_FAILED', resp.status, text);
        if (resp.status === 404 || resp.status === 400) {
          await disableToken(env, token);
        }
      }
    } catch (error) {
      console.warn('FCM_SEND_EXCEPTION', error);
    }
  }));
}
