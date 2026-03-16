// =============================================================================
// SecondBrain Frontend Configuration
// =============================================================================
// This file contains all environment-specific configuration for the frontend.
// Update API_BASE_URL when deploying to different environments.
// 
// For Cloudflare Pages deployment:
// 1. Set environment variables in Cloudflare Pages dashboard
// 2. Or create environment-specific config files (config.production.js, etc.)
// =============================================================================

const AppConfig = (() => {
    // =========================================================================
    // Environment Detection
    // =========================================================================
    const hostname = window.location.hostname;
    
    const isLocalhost = hostname === 'localhost' || 
                        hostname === '127.0.0.1' || 
                        hostname.startsWith('192.168.');
    
    const isProduction = hostname.includes('pages.dev') || 
                         hostname.includes('secondbrain') ||
                         hostname.includes('secondbrain-app') ||
                         hostname.includes('notesapp');
    
    // =========================================================================
    // API Configuration
    // =========================================================================
    // All API calls go to the Worker directly (no Gateway/Fly.io dependency)
    
    // Worker URL - handles all API endpoints directly with Supabase
    const WORKER_URL = 'https://notesapp-vector-search.monocle0712.workers.dev';
    
    // Development API URL (local backend for testing)
    const DEVELOPMENT_API_URL = '';  // Empty string = same origin (relative paths)
    
    // Production uses Worker directly - no Gateway/Fly.io overhead
    const API_BASE_URL = isLocalhost ? DEVELOPMENT_API_URL : WORKER_URL;
    
    // =========================================================================
    // API Endpoints
    // =========================================================================
    const API_ENDPOINTS = {
        // Auth endpoints (now on Worker)
        AUTH_ME: '/api/v1/auth/me',
        API_KEYS: '/api/v1/auth/api-keys',
        
        // Notes endpoints (now on Worker)
        NOTES: '/api/v1/notes/',
        NOTES_STATS: '/api/v1/notes/stats',
        NOTE_VIEW: (noteId) => `/notes/${noteId}/view`,
        NOTE_VIEW_TOKEN: (noteId) => `/api/v1/notes/${noteId}/view-token`,
        NOTES_TAGS: '/api/v1/notes/tags/all',
        
        // Search endpoints (all on Worker)
        WORKER_RAG_SEARCH: '/rag-search-auth', // Direct Worker RAG search
        
        // Chat endpoint (legacy - uses internal RAG agent)
        CHAT: '/api/v1/chat/',
        
        // Logs endpoints (admin)
        LOGS_TRACE: (correlationId) => `/api/v1/logs/file/trace/${correlationId}`,
    };
    
    // =========================================================================
    // Helper Functions
    // =========================================================================
    
    /**
     * Build full API URL from endpoint path
     * @param {string} endpoint - The API endpoint path (e.g., '/api/v1/auth/config')
     * @returns {string} Full URL with API base
     */
    function buildUrl(endpoint) {
        if (!API_BASE_URL) {
            return endpoint;  // Use relative path for same-origin
        }
        // Remove trailing slash from base, ensure endpoint starts with /
        const base = API_BASE_URL.replace(/\/$/, '');
        const path = endpoint.startsWith('/') ? endpoint : `/${endpoint}`;
        return `${base}${path}`;
    }
    
    /**
     * Get full URL for a specific endpoint
     * @param {string} endpointKey - Key from API_ENDPOINTS
     * @param {...any} args - Arguments for dynamic endpoints
     * @returns {string} Full URL
     */
    function getApiUrl(endpointKey, ...args) {
        const endpoint = API_ENDPOINTS[endpointKey];
        if (!endpoint) {
            console.warn(`Unknown endpoint: ${endpointKey}`);
            return buildUrl(`/api/v1/${endpointKey.toLowerCase()}`);
        }
        
        const path = typeof endpoint === 'function' ? endpoint(...args) : endpoint;
        return buildUrl(path);
    }
    
    // =========================================================================
    // Public API
    // =========================================================================
    return {
        // Environment info
        isLocalhost,
        isProduction,
        
        // URLs
        API_BASE_URL,
        WORKER_URL,
        API_ENDPOINTS,
        
        // Helper methods
        buildUrl,
        getApiUrl,
        
        // Shorthand methods for common endpoints
        get authMeUrl() { return buildUrl(API_ENDPOINTS.AUTH_ME); },
        get apiKeysUrl() { return buildUrl(API_ENDPOINTS.API_KEYS); },
        get notesUrl() { return buildUrl(API_ENDPOINTS.NOTES); },
        get notesStatsUrl() { return buildUrl(API_ENDPOINTS.NOTES_STATS); },
        get notesTagsUrl() { return buildUrl(API_ENDPOINTS.NOTES_TAGS); },
        get chatUrl() { return buildUrl(API_ENDPOINTS.CHAT); },
        // Direct Worker RAG search
        get workerRagSearchUrl() { return buildUrl(API_ENDPOINTS.WORKER_RAG_SEARCH); },
        
        noteViewUrl(noteId) { return buildUrl(API_ENDPOINTS.NOTE_VIEW(noteId)); },
        noteViewTokenUrl(noteId) { return buildUrl(API_ENDPOINTS.NOTE_VIEW_TOKEN(noteId)); },
        logsTraceUrl(correlationId) { return buildUrl(API_ENDPOINTS.LOGS_TRACE(correlationId)); },
        apiKeyDeleteUrl(keyId) { return buildUrl(`${API_ENDPOINTS.API_KEYS}/${keyId}`); },
        notesPaginatedUrl(limit, offset) { return buildUrl(`${API_ENDPOINTS.NOTES}?limit=${limit}&offset=${offset}`); },
    };
})();

// Make config globally available
window.AppConfig = AppConfig;

// Log configuration on load (only in development)
if (AppConfig.isLocalhost) {
    console.log('🔧 AppConfig loaded:', {
        isLocalhost: AppConfig.isLocalhost,
        isProduction: AppConfig.isProduction,
        API_BASE_URL: AppConfig.API_BASE_URL || '(same origin)',
    });
}
