/**
 * Authentication Module for Cloudflare Worker
 * 
 * Validates Supabase JWT tokens and API keys for direct frontend calls.
 * This enables frontend to call Worker directly, bypassing Fly.io for better performance.
 */

import { maskEmail, maskId, redact } from './log-redact';

export interface AuthEnv {
  SUPABASE_JWT_SECRET: string;
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  WORKER_API_KEY: string;
}

export interface AuthResult {
  authenticated: boolean;
  user_id?: string;
  email?: string;
  name?: string;  // User's full name from Google OAuth
  auth_method?: 'jwt' | 'api_key' | 'worker_key';
  error?: string;
}

/**
 * Validate authentication from request headers
 * Supports:
 * 1. Supabase JWT (Authorization: Bearer <token>)
 * 2. API Key (X-API-Key header) - validated against Supabase
 * 3. Worker API Key (X-API-Key header) - for server-to-server calls
 * 
 * @param request - The incoming request
 * @param env - Environment variables
 * @returns AuthResult with user_id if authenticated
 */
export async function validateAuth(request: Request, env: AuthEnv): Promise<AuthResult> {
  const authHeader = request.headers.get('Authorization');
  const apiKey = request.headers.get('X-API-Key');
  
  // PII/secret hygiene: log only presence + auth scheme, never token bytes.
  console.log('[Auth] Headers - Authorization:', authHeader ? 'Bearer <present>' : 'none');
  console.log('[Auth] Headers - X-API-Key:', apiKey ? `<present:${apiKey.startsWith('na_') ? 'na' : apiKey.startsWith('ina_') ? 'ina' : 'other'}>` : 'none');
  
  // Priority 1: Check for Worker API key (server-to-server, requires user_id in body)
  if (apiKey === env.WORKER_API_KEY) {
    console.log('[Auth] Matched Worker API key');
    return {
      authenticated: true,
      auth_method: 'worker_key',
      // user_id will be extracted from request body for worker_key auth
    };
  }
  
  // Priority 2: Check for Supabase JWT
  if (authHeader?.startsWith('Bearer ')) {
    const token = authHeader.slice(7);
    console.log('[Auth] Validating JWT token, length:', token.length);
    const jwtResult = await validateSupabaseJWT(token, env);
    console.log('[Auth] JWT result:', jwtResult.authenticated ? 'SUCCESS' : `FAILED: ${redact(jwtResult.error || '')}`);
    if (jwtResult.authenticated) {
      return jwtResult;
    }
    // Return the JWT error so we know what went wrong
    return jwtResult;
  }
  
  // Priority 3: Check for user API key (na_ or ina_ prefix)
  if (apiKey && (apiKey.startsWith('na_') || apiKey.startsWith('ina_'))) {
    const apiKeyResult = await validateApiKey(apiKey, env);
    if (apiKeyResult.authenticated) {
      return apiKeyResult;
    }
    // Return the specific error from API key validation
    return apiKeyResult;
  }
  
  // No valid auth found
  return {
    authenticated: false,
    error: 'No valid authentication provided. Use Authorization: Bearer <jwt> or X-API-Key header.'
  };
}

/**
 * Validate Supabase JWT token by calling Supabase API
 * This works for both HS256 and ES256 algorithms
 * Also validates that the session has not been revoked
 */
async function validateSupabaseJWT(token: string, env: AuthEnv): Promise<AuthResult> {
  try {
    console.log('[Auth] Calling Supabase URL:', env.SUPABASE_URL);
    // SECURITY: never log any prefix of the service key — it ends up in
    // Logpush -> Azure blob storage. Logging only presence here.
    console.log('[Auth] Service key configured:', Boolean(env.SUPABASE_SERVICE_KEY));
    
    // Call Supabase auth API to verify token and get user info
    const response = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, {
      headers: {
        'Authorization': `Bearer ${token}`,
        'apikey': env.SUPABASE_SERVICE_KEY
      }
    });
    
    console.log('[Auth] Supabase response status:', response.status);
    
    if (!response.ok) {
      const errorText = await response.text();
      // Error bodies from Supabase often echo back our Authorization header.
      console.log('[Auth] Supabase API error response:', redact(errorText));
      // Session was likely revoked - return specific error for extension to handle
      if (response.status === 401 || response.status === 403) {
        return { authenticated: false, error: 'SESSION_REVOKED' };
      }
      return { authenticated: false, error: `Invalid token: ${response.status} - ${redact(errorText)}` };
    }
    
    const user = await response.json() as { 
      id?: string; 
      email?: string;
      user_metadata?: { full_name?: string; name?: string };
    };
    console.log('[Auth] Supabase API verified user:', maskId(user.id), 'email:', maskEmail(user.email));
    
    // Extract user's name from OAuth metadata
    const userName = user.user_metadata?.full_name || user.user_metadata?.name;
    
    if (!user.id) {
      return { authenticated: false, error: 'Invalid token: no user ID' };
    }
    
    // Extract session_id from JWT to verify session is still valid
    // JWT format: header.payload.signature
    try {
      const parts = token.split('.');
      if (parts.length === 3) {
        // JWT uses base64url encoding, need to convert to regular base64
        const base64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
        const payload = JSON.parse(atob(base64));
        const sessionId = payload.session_id;
        
        console.log('[Auth] JWT session_id:', sessionId);
        
        if (sessionId) {
          // Check if session still exists using Supabase RPC function
          console.log('[Auth] Checking session exists via RPC...');
          const sessionResponse = await fetch(
            `${env.SUPABASE_URL}/rest/v1/rpc/check_session_exists`,
            {
              method: 'POST',
              headers: {
                'apikey': env.SUPABASE_SERVICE_KEY,
                'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
                'Content-Type': 'application/json',
              },
              body: JSON.stringify({ p_session_id: sessionId })
            }
          );
          
          console.log('[Auth] Session check response status:', sessionResponse.status);
          
          if (sessionResponse.ok) {
            const exists = await sessionResponse.json();
            console.log('[Auth] Session exists result:', exists);
            if (exists === false) {
              console.log('[Auth] Session revoked - session_id not found:', sessionId);
              return { authenticated: false, error: 'SESSION_REVOKED' };
            }
          } else {
            const errorText = await sessionResponse.text();
            console.log('[Auth] Session check RPC failed:', sessionResponse.status, redact(errorText));
          }
        } else {
          console.log('[Auth] No session_id in JWT payload');
        }
      }
    } catch (sessionCheckError) {
      // If session check fails, continue with auth (don't block valid users)
      console.log('[Auth] Session check error:', redact(sessionCheckError));
      console.log('[Auth] Session check skipped:', redact(sessionCheckError));
    }
    
    return {
      authenticated: true,
      user_id: user.id,
      email: user.email,
      name: userName,
      auth_method: 'jwt'
    };
    
  } catch (error) {
    console.error('[Auth] JWT validation error:', redact(error));
    return { authenticated: false, error: `JWT validation failed: ${redact(error)}` };
  }
}

/**
 * Validate user API key against Supabase
 * API keys are stored in the user_api_keys table
 */
async function validateApiKey(apiKey: string, env: AuthEnv): Promise<AuthResult> {
  try {
    // Hash the API key (stored as SHA256 hash in database)
    const encoder = new TextEncoder();
    const data = encoder.encode(apiKey);
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const keyHash = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
    
    console.log('[Auth] API key hash computed:', keyHash.slice(0, 16) + '...');
    
    // Query Supabase for the API key
    const queryUrl = `${env.SUPABASE_URL}/rest/v1/user_api_keys?api_key=eq.${keyHash}&is_active=eq.true&select=user_id`;
    console.log('[Auth] Querying:', queryUrl.replace(keyHash, keyHash.slice(0, 8) + '...'));
    
    const response = await fetch(queryUrl, {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        }
      }
    );
    
    console.log('[Auth] DB response status:', response.status);
    
    if (!response.ok) {
      const errorText = await response.text();
      console.error('[Auth] API key lookup failed:', response.status, redact(errorText));
      return { authenticated: false, error: `API key validation failed: ${response.status}` };
    }
    
    const keys = await response.json() as Array<{ user_id: string }>;
    console.log('[Auth] Keys found:', keys.length);
    
    if (!keys || keys.length === 0) {
      return { authenticated: false, error: 'Invalid or inactive API key' };
    }
    
    const userId = keys[0].user_id;
    
    // Fetch user email and name from Supabase Auth admin API
    let userEmail: string | undefined;
    let userName: string | undefined;
    try {
      const userResponse = await fetch(
        `${env.SUPABASE_URL}/auth/v1/admin/users/${userId}`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          }
        }
      );
      if (userResponse.ok) {
        const userData = await userResponse.json() as { 
          email?: string;
          user_metadata?: { full_name?: string; name?: string };
        };
        userEmail = userData.email;
        userName = userData.user_metadata?.full_name || userData.user_metadata?.name;
        console.log('[Auth] Fetched email for API key user:', maskEmail(userEmail), 'name:', userName ? '<present>' : '<none>');
      } else {
        console.log('[Auth] Could not fetch user email:', userResponse.status);
      }
    } catch (emailError) {
      console.log('[Auth] Error fetching user email:', redact(emailError));
    }
    
    return {
      authenticated: true,
      user_id: userId,
      email: userEmail,
      name: userName,
      auth_method: 'api_key'
    };
    
  } catch (error) {
    console.error('API key validation error:', redact(error));
    return { authenticated: false, error: `API key validation failed: ${redact(error)}` };
  }
}

/**
 * Base64URL decode (JWT uses base64url encoding, not standard base64)
 */
function base64UrlDecode(str: string): Uint8Array {
  // Replace URL-safe characters with standard base64
  let base64 = str.replace(/-/g, '+').replace(/_/g, '/');
  
  // Add padding if needed
  while (base64.length % 4) {
    base64 += '=';
  }
  
  // Decode base64 to binary string
  const binaryString = atob(base64);
  
  // Convert to Uint8Array
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  
  return bytes;
}

/**
 * Generate a view token for secure note viewing
 * This allows the Worker to generate clickable URLs without calling Fly.io
 */
export function generateViewToken(
  noteId: string, 
  userId: string, 
  jwtSecret: string,
  expiryMinutes: number = 1440  // 24 hours default
): string {
  const expiryTs = Math.floor(Date.now() / 1000) + (expiryMinutes * 60);
  const message = `${noteId}:${userId}:${expiryTs}`;
  
  // Create HMAC signature (sync version using simple hash)
  // For production, use async crypto.subtle.sign
  const encoder = new TextEncoder();
  const data = encoder.encode(message + jwtSecret);
  
  // Simple hash for token (not cryptographically strong but matches Fly.io implementation)
  let hash = 0;
  const str = message + jwtSecret;
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash;
  }
  const signature = Math.abs(hash).toString(16).padStart(16, '0').slice(0, 16);
  
  return `${message}:${signature}`;
}

/**
 * Generate view token using proper HMAC (async version)
 */
export async function generateViewTokenAsync(
  noteId: string, 
  userId: string, 
  jwtSecret: string,
  expiryMinutes: number = 1440  // 24 hours default
): Promise<string> {
  const expiryTs = Math.floor(Date.now() / 1000) + (expiryMinutes * 60);
  const message = `${noteId}:${userId}:${expiryTs}`;
  
  // Create HMAC signature
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(jwtSecret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  
  const signatureBuffer = await crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(message)
  );
  
  const signatureArray = Array.from(new Uint8Array(signatureBuffer));
  const signature = signatureArray.map(b => b.toString(16).padStart(2, '0')).join('').slice(0, 16);
  
  return `${message}:${signature}`;
}
