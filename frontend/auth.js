// Auth.js - Supabase Authentication Handler

// Show persistent debug logs immediately on ANY page load
(function showDebugLogs() {
    const logs = JSON.parse(sessionStorage.getItem('auth_debug') || '[]');
    if (logs.length > 0) {
        console.log('%c=== AUTH DEBUG LOGS (from sessionStorage) ===', 'color: red; font-weight: bold');
        logs.forEach(l => console.log(l));
        console.log('%c=== END DEBUG LOGS ===', 'color: red; font-weight: bold');
    }
})();

let supabaseClient = null;
let authInitialized = false;
let pendingAuthMode = null; // 'signin' or 'signup' - tracks what mode the user initiated
let authValidationDone = false; // Prevents double validation
let initialAuthCheckComplete = false; // Prevents redirect during initial auth check

// Memory storage fallback when localStorage is blocked
const memoryStorage = {
    _data: {},
    getItem(key) { return this._data[key] || null; },
    setItem(key, value) { this._data[key] = value; },
    removeItem(key) { delete this._data[key]; },
};

// Check if localStorage is available
function isLocalStorageAvailable() {
    try {
        const test = '__storage_test__';
        window.localStorage.setItem(test, test);
        window.localStorage.removeItem(test);
        return true;
    } catch (e) {
        console.warn('localStorage not available, using memory storage');
        return false;
    }
}

// Get the best available storage
const authStorage = isLocalStorageAvailable() ? window.localStorage : memoryStorage;

// Helper: Show/hide auth loading overlay
function showAuthLoading() {
    const overlay = document.getElementById('authLoadingOverlay');
    if (overlay) {
        overlay.style.display = 'flex';
    }
}

function hideAuthLoading() {
    const overlay = document.getElementById('authLoadingOverlay');
    if (overlay) {
        overlay.style.display = 'none';
    }
}

// Helper: Extract tokens from URL hash (OAuth callback) - run IMMEDIATELY
let urlTokens = null;
(function extractTokensImmediately() {
    const hash = window.location.hash;
    if (!hash || !hash.includes('access_token')) {
        return;
    }
    
    // Show loading overlay immediately when we detect OAuth callback
    document.addEventListener('DOMContentLoaded', showAuthLoading);
    // Also try to show it now in case DOM is already loaded
    if (document.readyState !== 'loading') {
        showAuthLoading();
    }
    
    try {
        const params = new URLSearchParams(hash.substring(1));
        const accessToken = params.get('access_token');
        const refreshToken = params.get('refresh_token');
        const expiresIn = params.get('expires_in');
        const tokenType = params.get('token_type');
        
        if (accessToken) {
            console.log('🔑 Extracted tokens from URL hash immediately');
            // Clear the hash from URL immediately
            window.history.replaceState(null, '', window.location.pathname);
            urlTokens = {
                access_token: accessToken,
                refresh_token: refreshToken,
                expires_in: parseInt(expiresIn) || 3600,
                token_type: tokenType || 'bearer'
            };
        }
    } catch (e) {
        console.error('Failed to extract tokens from URL:', e);
    }
})();

// =============================================================================
// Supabase Configuration (public anon key - safe to expose, security via RLS)
// =============================================================================
const SUPABASE_CONFIG = {
    url: 'https://vnpqsmiuismvwsynpmfu.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc5NDM3OTUsImV4cCI6MjA4MzUxOTc5NX0.D-U6mkNHxh8mGYwgQy9-qEKh3e2wLNirppV2ASivrUg'
};

// Initialize Supabase client
async function initSupabase() {
    // Prevent double initialization
    if (authInitialized && supabaseClient) {
        return supabaseClient;
    }
    
    try {
        // Check if there's a pending auth mode from before OAuth redirect
        pendingAuthMode = sessionStorage.getItem('pendingAuthMode');
        sessionStorage.removeItem('pendingAuthMode'); // Clear it immediately
        
        console.log('initSupabase: pendingAuthMode =', pendingAuthMode, 'urlTokens =', urlTokens ? 'present' : 'none');
        
        // Initialize Supabase client - using hardcoded config (no API call needed)
        // Note: Anon key is public by design - security comes from Row Level Security (RLS)
        supabaseClient = supabase.createClient(SUPABASE_CONFIG.url, SUPABASE_CONFIG.anonKey, {
            auth: {
                autoRefreshToken: true,
                persistSession: true,
                detectSessionInUrl: false,  // We handle URL tokens manually
                storage: authStorage,  // Use our storage (with fallback)
                storageKey: 'sb-auth-token',
            }
        });
        
        // Set up auth state listener (for future state changes, not initial)
        supabaseClient.auth.onAuthStateChange((event, session) => {
            authDebugLog(`onAuthStateChange: event=${event}, hasSession=${!!session}, initialCheckComplete=${initialAuthCheckComplete}`);
            // Only handle sign out AFTER initial auth check is complete
            // This prevents redirect during page load when Supabase fires SIGNED_OUT before session is restored
            if (event === 'SIGNED_OUT' && initialAuthCheckComplete) {
                authDebugLog('Handling SIGNED_OUT - will redirect');
                handleSignedOut();
            } else if (event === 'SIGNED_OUT') {
                authDebugLog('Ignoring SIGNED_OUT during initial auth check');
            }
        });
        
        // If we extracted tokens from URL, set the session manually
        if (urlTokens) {
            authDebugLog('Setting session from URL tokens...');
            const { data, error: setError } = await supabaseClient.auth.setSession({
                access_token: urlTokens.access_token,
                refresh_token: urlTokens.refresh_token,
            });
            
            if (setError) {
                console.error('Error setting session from URL tokens:', setError);
                hideAuthLoading();  // Hide loading on error
                showAuthMessage('Sign in failed. Please try again.', 'error');
            } else if (data.session) {
                console.log('Session set successfully from URL tokens');
                await handleAuthenticatedUser(data.session);
                authInitialized = true;
                return supabaseClient;
            }
        }
        
        // Check current session
        const { data: { session }, error } = await supabaseClient.auth.getSession();
        
        if (error) {
            console.error('Error getting session:', error);
            hideAuthLoading();  // Hide loading on error
        }
        
        if (session) {
            console.log('Found existing session for:', session.user.email);
            // Handle the session with our validation logic
            await handleAuthenticatedUser(session);
        } else {
            console.log('No existing session found');
            hideAuthLoading();  // Hide loading if no session
            
            // Check for OAuth errors in URL params (Supabase sometimes returns these)
            const urlParams = new URLSearchParams(window.location.search);
            const errorCode = urlParams.get('error_code') || urlParams.get('error');
            const errorDesc = urlParams.get('error_description');
            
            if (errorCode || errorDesc) {
                console.error('OAuth error in URL:', errorCode, errorDesc);
                // Clean up URL
                window.history.replaceState(null, '', window.location.pathname);
                showGlobalToast('Sign in failed. Please try again.', 'error');
            }
            // Detect when user tried to sign in but came back without tokens (SSL error, timeout, etc.)
            else if (pendingAuthMode && !urlTokens) {
                console.warn('OAuth flow interrupted - pendingAuthMode was set but no tokens received');
                showGlobalToast('Sign in was interrupted. This can happen due to temporary server issues. Please try again.', 'warning');
            }
        }
        
        authInitialized = true;
        initialAuthCheckComplete = true; // Now it's safe to handle SIGNED_OUT events
        console.log('Supabase initialized successfully, initial auth check complete');
        return supabaseClient;
    } catch (error) {
        console.error('Failed to initialize Supabase:', error);
        showAuthMessage('Failed to initialize authentication. Please refresh the page.', 'error');
        return null;
    }
}

// Debug logger that persists across page navigations (also used in dashboard-chat-new.js)
function authDebugLog(msg) {
    const logs = JSON.parse(sessionStorage.getItem('auth_debug') || '[]');
    logs.push(`[${new Date().toISOString()}] [auth.js] ${msg}`);
    if (logs.length > 50) logs.shift();
    sessionStorage.setItem('auth_debug', JSON.stringify(logs));
    console.log('[auth.js DEBUG]', msg);
}

// Handle signed out
function handleSignedOut() {
    authDebugLog('handleSignedOut() called');
    localStorage.removeItem('access_token');
    localStorage.removeItem('user_email');
    localStorage.removeItem('user_id');
    // Also clear supabase storage
    localStorage.removeItem('sb-auth-token');
    
    // Redirect to home if on dashboard (check for both paths)
    const path = window.location.pathname;
    authDebugLog(`Current path: ${path}`);
    if (path.includes('dashboard') || path === '/dashboard.html') {
        authDebugLog('Redirecting to / from handleSignedOut');
        window.location.href = '/';
    }
}

// Handle authenticated user
async function handleAuthenticatedUser(session) {
    authDebugLog('handleAuthenticatedUser() called');
    
    // Prevent double execution
    if (authValidationDone) {
        authDebugLog('Auth validation already done, skipping');
        return;
    }
    authValidationDone = true;
    
    // Use the global pendingAuthMode (set in initSupabase)
    const authMode = pendingAuthMode;
    pendingAuthMode = null; // Clear it
    
    // Check if user is new (just created) - Supabase provides this info
    // For OAuth users, we check created_at vs last_sign_in_at
    const user = session.user;
    const createdAt = new Date(user.created_at);
    const now = new Date();
    const isNewUser = (now - createdAt) < 60000; // Created within last 60 seconds
    
    authDebugLog(`authMode=${authMode}, isNewUser=${isNewUser}, email=${user.email}`);
    
    // Validate based on auth mode
    if (authMode === 'signin' && isNewUser) {
        // User tried to sign in but account didn't exist (was just created via OAuth)
        authDebugLog('Sign-in attempted but account was just created - signing out');
        await supabaseClient.auth.signOut();
        // Clear local storage
        localStorage.removeItem('access_token');
        localStorage.removeItem('user_email');
        localStorage.removeItem('user_id');
        // Show modal with error - stay on current page
        showAuthModal('signup');
        setTimeout(() => {
            showAuthMessage('No account found with this email. Please sign up first.', 'error');
        }, 100);
        return;
    }
    
    if (authMode === 'signup' && !isNewUser) {
        // User tried to sign up but account already exists
        authDebugLog('Sign-up attempted but account already exists - signing out');
        await supabaseClient.auth.signOut();
        // Clear local storage
        localStorage.removeItem('access_token');
        localStorage.removeItem('user_email');
        localStorage.removeItem('user_id');
        // Show modal with error - stay on current page
        showAuthModal('signin');
        setTimeout(() => {
            showAuthMessage('An account with this email already exists. Please sign in instead.', 'error');
        }, 100);
        return;
    }
    
    // Store session token for API calls
    authDebugLog('Storing token in localStorage');
    localStorage.setItem('access_token', session.access_token);
    localStorage.setItem('user_email', session.user.email);
    localStorage.setItem('user_id', session.user.id);
    
    authDebugLog(`User authenticated: ${session.user.email}`);
    
    // Redirect to dashboard if on login page (not already on dashboard)
    const path = window.location.pathname;
    authDebugLog(`Current path: ${path}, will redirect: ${path === '/' || path === '/index.html'}`);
    if (path === '/' || path === '/index.html') {
        // Check for redirect parameter in URL first, then localStorage
        const urlParams = new URLSearchParams(window.location.search);
        let redirectTo = urlParams.get('redirect');
        
        // Also check localStorage (set before OAuth flow)
        if (!redirectTo) {
            redirectTo = localStorage.getItem('auth_redirect_to');
            localStorage.removeItem('auth_redirect_to');
        }
        
        if (redirectTo && redirectTo.startsWith('/')) {
            authDebugLog(`Redirecting to ${redirectTo} (from stored redirect)`);
            window.location.href = redirectTo;
        } else {
            authDebugLog('Redirecting to /dashboard.html');
            window.location.href = '/dashboard.html';
        }
    }
}

// Sign in with Google
// mode: 'signin' - requires existing account, 'signup' - creates new account
async function signInWithGoogle(mode = 'signin') {
    // Ensure Supabase is initialized before proceeding
    if (!supabaseClient) {
        console.log('Supabase not initialized, initializing now...');
        await initSupabase();
    }
    
    if (!supabaseClient) {
        showError('Authentication failed to initialize. Please refresh the page.');
        return;
    }
    
    try {
        // Health check: verify Supabase is reachable before OAuth redirect
        // This catches SSL errors, timeouts, and service outages before redirecting
        try {
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 5000);
            const healthCheck = await fetch(SUPABASE_CONFIG.url + '/rest/v1/', {
                method: 'HEAD',
                signal: controller.signal,
                mode: 'cors'
            });
            clearTimeout(timeoutId);
            // 401 is expected (no auth), but other errors indicate problems
            if (!healthCheck.ok && healthCheck.status !== 401) {
                console.warn('Supabase health check failed:', healthCheck.status);
                throw new Error('Service unavailable');
            }
        } catch (healthErr) {
            if (healthErr.name === 'AbortError' || healthErr.message.includes('Failed to fetch') || healthErr.message.includes('Service unavailable')) {
                console.error('Supabase health check failed:', healthErr);
                showError('Authentication service is temporarily unavailable. Please try again in a few minutes.');
                return;
            }
            // For unexpected errors, log but continue with OAuth attempt
            console.warn('Health check warning:', healthErr);
        }
        
        // Store the auth mode so we can validate after OAuth redirect
        sessionStorage.setItem('pendingAuthMode', mode);
        
        // Store redirect URL if present (for after OAuth)
        const urlParams = new URLSearchParams(window.location.search);
        const redirectTo = urlParams.get('redirect');
        if (redirectTo && redirectTo.startsWith('/')) {
            localStorage.setItem('auth_redirect_to', redirectTo);
            authDebugLog(`Stored redirect URL: ${redirectTo}`);
        }
        
        // Redirect to home page first for validation, then redirect to dashboard if valid
        const { data, error } = await supabaseClient.auth.signInWithOAuth({
            provider: 'google',
            options: {
                redirectTo: window.location.origin + '/',  // Validate on home page first
                queryParams: {
                    prompt: 'select_account'  // Always show account selection
                }
            }
        });
        
        if (error) throw error;
    } catch (error) {
        console.error('Google sign-in error:', error);
        showError('Failed to sign in with Google: ' + error.message);
    }
}

// Sign out
async function signOut() {
    console.log('signOut called');
    
    // Try to sign out from Supabase if client exists
    if (supabaseClient) {
        try {
            await supabaseClient.auth.signOut();
        } catch (error) {
            console.error('Supabase sign-out error:', error);
        }
    }
    
    // Always clear local state and redirect
    handleSignedOut();
}

// Check if user is authenticated
function isAuthenticated() {
    return !!localStorage.getItem('access_token');
}

// Get current user info
function getCurrentUser() {
    return {
        email: localStorage.getItem('user_email'),
        id: localStorage.getItem('user_id'),
        accessToken: localStorage.getItem('access_token')
    };
}

// Get auth headers for API calls (sync - uses cached token)
function getAuthHeaders() {
    const token = localStorage.getItem('access_token');
    return token ? { 'Authorization': `Bearer ${token}` } : {};
}

/**
 * Get fresh auth headers - ensures token is valid before API call
 * Uses Supabase's auto-refresh mechanism via getSession()
 * Performance: ~0-5ms when token valid, ~200-500ms when refresh needed (once/hour)
 */
async function getFreshAuthHeaders() {
    if (!supabaseClient) {
        // Fallback to cached token if Supabase not initialized
        const cached = getAuthHeaders();
        if (!cached.Authorization) {
            console.warn('No auth available - redirecting to login');
            window.location.href = '/';
        }
        return cached;
    }
    
    try {
        // getSession() auto-refreshes expired tokens when autoRefreshToken: true
        const { data: { session }, error } = await supabaseClient.auth.getSession();
        
        if (error) {
            console.error('Error getting session:', error);
            // Fallback to cached - might still be valid
            return getAuthHeaders();
        }
        
        if (session?.access_token) {
            // Update localStorage if token was refreshed
            const cachedToken = localStorage.getItem('access_token');
            if (session.access_token !== cachedToken) {
                console.log('🔄 Token refreshed');
                localStorage.setItem('access_token', session.access_token);
            }
            return { 'Authorization': `Bearer ${session.access_token}` };
        }
        
        // No valid session - check if we have a cached token (might be edge case)
        const cachedToken = localStorage.getItem('access_token');
        if (cachedToken) {
            console.warn('No Supabase session but have cached token - using cached');
            return { 'Authorization': `Bearer ${cachedToken}` };
        }
        
        // No valid session at all - redirect to login
        console.warn('Session expired - redirecting to login');
        handleSignedOut();
        return {};
    } catch (e) {
        console.error('Error in getFreshAuthHeaders:', e);
        return getAuthHeaders(); // Fallback to cached
    }
}

// ============================================================================
// Auth Modal Functions (called from HTML onclick)
// ============================================================================

function showAuthModal(mode) {
    const modal = document.getElementById('authModal');
    const signinForm = document.getElementById('signinForm');
    const signupForm = document.getElementById('signupForm');
    
    if (!modal) {
        console.error('Auth modal not found');
        return;
    }
    
    // Show the modal
    modal.classList.add('active');
    document.body.style.overflow = 'hidden';
    
    // Show the appropriate form
    if (mode === 'signup') {
        if (signinForm) signinForm.style.display = 'none';
        if (signupForm) signupForm.style.display = 'block';
    } else {
        if (signinForm) signinForm.style.display = 'block';
        if (signupForm) signupForm.style.display = 'none';
    }
    
    // Clear any previous messages
    clearAuthMessage();
}

function hideAuthModal() {
    const modal = document.getElementById('authModal');
    if (modal) {
        modal.classList.remove('active');
        document.body.style.overflow = '';
    }
    clearAuthMessage();
}

function clearAuthMessage() {
    const messageDiv = document.getElementById('authMessage');
    if (messageDiv) {
        messageDiv.textContent = '';
        messageDiv.style.display = 'none';
        messageDiv.className = 'auth-message';
    }
}

function showAuthMessage(message, type) {
    const messageDiv = document.getElementById('authMessage');
    if (messageDiv) {
        messageDiv.textContent = message;
        messageDiv.className = 'auth-message ' + type;
        messageDiv.style.display = 'block';
    } else {
        if (type === 'error') {
            alert('Error: ' + message);
        }
    }
}

// Global toast notification (shows outside modal, for transient errors)
function showGlobalToast(message, type = 'info') {
    // Create or reuse toast container
    let toast = document.getElementById('globalAuthToast');
    if (!toast) {
        toast = document.createElement('div');
        toast.id = 'globalAuthToast';
        toast.style.cssText = `
            position: fixed;
            top: 20px;
            left: 50%;
            transform: translateX(-50%);
            padding: 16px 24px;
            border-radius: 12px;
            font-family: var(--font-body, system-ui, sans-serif);
            font-size: 14px;
            font-weight: 500;
            z-index: 10000;
            box-shadow: 0 8px 32px rgba(0,0,0,0.3);
            display: flex;
            align-items: center;
            gap: 12px;
            max-width: 90vw;
            animation: toastSlideIn 0.3s ease-out;
        `;
        document.body.appendChild(toast);
        
        // Add keyframes if not already present
        if (!document.getElementById('toastAnimStyles')) {
            const style = document.createElement('style');
            style.id = 'toastAnimStyles';
            style.textContent = `
                @keyframes toastSlideIn {
                    from { opacity: 0; transform: translateX(-50%) translateY(-20px); }
                    to { opacity: 1; transform: translateX(-50%) translateY(0); }
                }
                @keyframes toastSlideOut {
                    from { opacity: 1; transform: translateX(-50%) translateY(0); }
                    to { opacity: 0; transform: translateX(-50%) translateY(-20px); }
                }
            `;
            document.head.appendChild(style);
        }
    }
    
    // Style based on type
    const colors = {
        error: { bg: 'hsl(0, 70%, 15%)', border: 'hsl(0, 70%, 40%)', text: 'hsl(0, 70%, 85%)', icon: '❌' },
        warning: { bg: 'hsl(38, 70%, 15%)', border: 'hsl(38, 70%, 50%)', text: 'hsl(38, 70%, 85%)', icon: '⚠️' },
        info: { bg: 'hsl(210, 70%, 15%)', border: 'hsl(210, 70%, 50%)', text: 'hsl(210, 70%, 85%)', icon: 'ℹ️' },
        success: { bg: 'hsl(155, 70%, 15%)', border: 'hsl(155, 70%, 45%)', text: 'hsl(155, 70%, 85%)', icon: '✓' },
    };
    const c = colors[type] || colors.info;
    
    toast.style.background = c.bg;
    toast.style.border = `1px solid ${c.border}`;
    toast.style.color = c.text;
    toast.innerHTML = `<span>${c.icon}</span><span>${message}</span>`;
    toast.style.display = 'flex';
    toast.style.animation = 'toastSlideIn 0.3s ease-out';
    
    // Auto hide after 6 seconds
    clearTimeout(toast._hideTimeout);
    toast._hideTimeout = setTimeout(() => {
        toast.style.animation = 'toastSlideOut 0.3s ease-out forwards';
        setTimeout(() => {
            toast.style.display = 'none';
        }, 300);
    }, 6000);
}

// Modal controls
function showModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.classList.add('active');
        document.body.style.overflow = 'hidden';
    }
}

function hideModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.classList.remove('active');
        document.body.style.overflow = '';
    }
}

function hideAllModals() {
    document.querySelectorAll('.modal').forEach(modal => {
        modal.classList.remove('active');
    });
    document.body.style.overflow = '';
}

// Switch between sign-in and sign-up forms
function showSignIn() {
    document.getElementById('signInForm').style.display = 'block';
    document.getElementById('signUpForm').style.display = 'none';
    document.querySelector('.modal-title').textContent = 'Welcome Back';
}

function showSignUp() {
    document.getElementById('signInForm').style.display = 'none';
    document.getElementById('signUpForm').style.display = 'block';
    document.querySelector('.modal-title').textContent = 'Create Account';
}

// Error/Success message display
function showError(message) {
    const errorDiv = document.getElementById('authError');
    if (errorDiv) {
        errorDiv.textContent = message;
        errorDiv.style.display = 'block';
        setTimeout(() => {
            errorDiv.style.display = 'none';
        }, 5000);
    } else {
        alert(message);
    }
}

function showSuccess(message) {
    const successDiv = document.getElementById('authSuccess');
    if (successDiv) {
        successDiv.textContent = message;
        successDiv.style.display = 'block';
        setTimeout(() => {
            successDiv.style.display = 'none';
        }, 5000);
    } else {
        alert(message);
    }
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', async () => {
    // Initialize Supabase first (this will also handle OAuth redirects and show errors)
    await initSupabase();
    
    // Set up form handlers
    setupFormHandlers();
    
    // Set up modal close on outside click
    document.querySelectorAll('.modal').forEach(modal => {
        modal.addEventListener('click', (e) => {
            if (e.target === modal) {
                hideAuthModal();
            }
        });
    });
    
    // Set up ESC key to close modals
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            hideAuthModal();
        }
    });
});

function setupFormHandlers() {
    // Google sign-in buttons use onclick in HTML with signInWithGoogle('signin'/'signup')
    // No email/password forms to set up
}
