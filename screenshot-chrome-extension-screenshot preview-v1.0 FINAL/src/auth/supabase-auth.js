/**
 * Supabase Authentication Module for infoSnap.ai Chrome Extension
 * Handles Google OAuth via Supabase with JWT token management
 */

class SupabaseAuth {
  constructor() {
    // Supabase configuration (same as main app)
    this.SUPABASE_URL = 'https://vnpqsmiuismvwsynpmfu.supabase.co';
    this.SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc5NDM3OTUsImV4cCI6MjA4MzUxOTc5NX0.D-U6mkNHxh8mGYwgQy9-qEKh3e2wLNirppV2ASivrUg';
    this.WORKER_URL = 'https://notesapp-vector-search.monocle0712.workers.dev';
    this.APP_URL = 'https://infosnap.ai';
    
    // Token refresh margin (refresh 5 minutes before expiry)
    this.REFRESH_MARGIN_MS = 5 * 60 * 1000;
  }

  /**
   * Get stored auth tokens from chrome.storage
   */
  async getStoredAuth() {
    return new Promise((resolve) => {
      chrome.storage.sync.get([
        'accessToken',
        'refreshToken',
        'expiresAt',
        'userEmail',
        'userId',
        'isLoggedIn'
      ], (result) => {
        resolve(result);
      });
    });
  }

  /**
   * Store auth tokens in chrome.storage
   */
  async storeAuth(data) {
    return new Promise((resolve, reject) => {
      chrome.storage.sync.set(data, () => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
        } else {
          resolve();
        }
      });
    });
  }

  /**
   * Clear all auth data from storage
   */
  async clearAuth() {
    return new Promise((resolve) => {
      chrome.storage.sync.remove([
        'accessToken',
        'refreshToken',
        'expiresAt',
        'userEmail',
        'userId',
        'isLoggedIn',
        // Also clear old API key auth data
        'apiKey',
        'loginTimestamp'
      ], resolve);
    });
  }

  /**
   * Check if user is authenticated
   */
  async isAuthenticated() {
    const auth = await this.getStoredAuth();
    return auth.isLoggedIn && (auth.accessToken || auth.refreshToken);
  }

  /**
   * Get a valid access token (refreshes if expired)
   */
  async getValidToken() {
    const auth = await this.getStoredAuth();
    
    if (!auth.refreshToken) {
      console.log('[SupabaseAuth] No refresh token available');
      return null;
    }

    // Check if token is expired or expiring soon
    const now = Date.now();
    const needsRefresh = !auth.accessToken || 
                         !auth.expiresAt || 
                         (now > (auth.expiresAt - this.REFRESH_MARGIN_MS));

    if (needsRefresh) {
      console.log('[SupabaseAuth] Token expired or expiring, refreshing...');
      try {
        const newTokens = await this.refreshTokens(auth.refreshToken);
        return newTokens.access_token;
      } catch (error) {
        console.error('[SupabaseAuth] Token refresh failed:', error);
        // Clear auth on refresh failure
        await this.clearAuth();
        return null;
      }
    }

    return auth.accessToken;
  }

  /**
   * Refresh tokens using Supabase API
   */
  async refreshTokens(refreshToken) {
    console.log('[SupabaseAuth] Refreshing tokens...');
    
    const response = await fetch(`${this.SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': this.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        refresh_token: refreshToken
      })
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error('[SupabaseAuth] Refresh failed:', response.status, errorText);
      throw new Error(`Token refresh failed: ${response.status}`);
    }

    const data = await response.json();
    
    // Store the new tokens
    const expiresAt = Date.now() + (data.expires_in * 1000);
    await this.storeAuth({
      accessToken: data.access_token,
      refreshToken: data.refresh_token,
      expiresAt: expiresAt,
      isLoggedIn: true
    });

    console.log('[SupabaseAuth] Tokens refreshed successfully');
    return data;
  }

  /**
   * Get auth headers for API calls
   */
  async getAuthHeaders() {
    const token = await this.getValidToken();
    
    if (token) {
      return { 'Authorization': `Bearer ${token}` };
    }
    
    // Fallback: Check for legacy API key
    const auth = await this.getStoredAuth();
    if (auth.apiKey) {
      return { 'X-API-Key': auth.apiKey };
    }
    
    return {};
  }

  /**
   * Start Google OAuth flow
   * Opens a popup window to handle the OAuth redirect
   */
  async signInWithGoogle() {
    console.log('[SupabaseAuth] Starting Google OAuth flow...');
    
    // For Chrome extensions, we must use the chrome-extension redirect URL
    // Format: https://<extension-id>.chromiumapp.org/
    const redirectUri = chrome.identity.getRedirectURL();
    console.log('[SupabaseAuth] Redirect URI:', redirectUri);
    
    // Build the OAuth URL
    const oauthUrl = `${this.SUPABASE_URL}/auth/v1/authorize?` + new URLSearchParams({
      provider: 'google',
      redirect_to: redirectUri,
      prompt: 'select_account'
    }).toString();

    console.log('[SupabaseAuth] OAuth URL:', oauthUrl);

    // Use chrome.identity.launchWebAuthFlow for seamless OAuth
    return new Promise((resolve, reject) => {
      chrome.identity.launchWebAuthFlow({
        url: oauthUrl,
        interactive: true
      }, async (responseUrl) => {
        if (chrome.runtime.lastError) {
          console.error('[SupabaseAuth] OAuth error:', chrome.runtime.lastError);
          reject(new Error(chrome.runtime.lastError.message));
          return;
        }

        if (!responseUrl) {
          reject(new Error('No response from OAuth'));
          return;
        }

        console.log('[SupabaseAuth] OAuth response received');
        
        try {
          // Extract tokens from the response URL hash
          const url = new URL(responseUrl);
          const hashParams = new URLSearchParams(url.hash.substring(1));
          
          const accessToken = hashParams.get('access_token');
          const refreshToken = hashParams.get('refresh_token');
          const expiresIn = parseInt(hashParams.get('expires_in') || '3600');
          
          if (!accessToken) {
            // Check for error
            const error = hashParams.get('error') || url.searchParams.get('error');
            const errorDesc = hashParams.get('error_description') || url.searchParams.get('error_description');
            throw new Error(errorDesc || error || 'No access token in response');
          }

          // Get user info from the token
          const userInfo = await this.getUserInfo(accessToken);
          
          // Store everything
          const expiresAt = Date.now() + (expiresIn * 1000);
          await this.storeAuth({
            accessToken,
            refreshToken,
            expiresAt,
            userEmail: userInfo.email,
            userId: userInfo.id,
            isLoggedIn: true
          });

          console.log('[SupabaseAuth] Successfully signed in:', userInfo.email);
          resolve({
            email: userInfo.email,
            userId: userInfo.id
          });
          
        } catch (error) {
          console.error('[SupabaseAuth] Failed to process OAuth response:', error);
          reject(error);
        }
      });
    });
  }

  /**
   * Get user info from Supabase using access token
   */
  async getUserInfo(accessToken) {
    const response = await fetch(`${this.SUPABASE_URL}/auth/v1/user`, {
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'apikey': this.SUPABASE_ANON_KEY
      }
    });

    if (!response.ok) {
      throw new Error(`Failed to get user info: ${response.status}`);
    }

    return response.json();
  }

  /**
   * Sign out - clear local tokens
   */
  async signOut() {
    console.log('[SupabaseAuth] Signing out...');
    
    // Try to revoke session on server (best effort)
    try {
      const token = await this.getValidToken();
      if (token) {
        await fetch(`${this.SUPABASE_URL}/auth/v1/logout`, {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${token}`,
            'apikey': this.SUPABASE_ANON_KEY
          }
        });
      }
    } catch (error) {
      console.log('[SupabaseAuth] Server logout failed (continuing with local logout):', error);
    }

    // Clear local storage
    await this.clearAuth();
    console.log('[SupabaseAuth] Signed out successfully');
  }

  /**
   * Validate stored auth by calling backend
   */
  async validateAuth() {
    try {
      const headers = await this.getAuthHeaders();
      if (!headers.Authorization && !headers['X-API-Key']) {
        return { valid: false, error: 'No auth credentials' };
      }

      const response = await fetch(`${this.WORKER_URL}/api/v1/auth/me`, {
        headers
      });

      if (response.ok) {
        const user = await response.json();
        // Update stored email/userId if different
        if (user.email || user.user_id) {
          await this.storeAuth({
            userEmail: user.email,
            userId: user.user_id
          });
        }
        return { valid: true, user };
      }

      return { valid: false, error: `Auth failed: ${response.status}` };
    } catch (error) {
      return { valid: false, error: error.message };
    }
  }
}

// Export singleton instance
const supabaseAuth = new SupabaseAuth();

// Make available globally
if (typeof window !== 'undefined') {
  window.supabaseAuth = supabaseAuth;
}
