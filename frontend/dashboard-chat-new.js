// =============================================================================
// Dashboard New - JavaScript (Loveable Design)
// v20: 2026-03-31 - Added tag-scoped search filter chips
// =============================================================================

// Debug logger that persists across page navigations
function debugLog(msg) {
    const logs = JSON.parse(sessionStorage.getItem('auth_debug') || '[]');
    logs.push(`[${new Date().toISOString()}] ${msg}`);
    // Keep last 50 entries
    if (logs.length > 50) logs.shift();
    sessionStorage.setItem('auth_debug', JSON.stringify(logs));
    console.log('[DEBUG]', msg);
}
// Show debug logs on page load
console.log('=== AUTH DEBUG LOGS ===');
JSON.parse(sessionStorage.getItem('auth_debug') || '[]').forEach(l => console.log(l));
console.log('=== END DEBUG LOGS ===');

// API Base URL - All calls go to Worker directly (no Gateway/Fly.io)
// AppConfig.API_BASE_URL doesn't include /api/v1, so we need to add it
const API_BASE = (window.AppConfig?.API_BASE_URL || 'https://notesapp-vector-search.monocle0712.workers.dev') + '/api/v1';
// Worker URL (same as API_BASE now, kept for compatibility)
const WORKER_URL = window.AppConfig?.WORKER_URL || 'https://notesapp-vector-search.monocle0712.workers.dev';
// Helper: Get view URL for a note
function getViewUrl(noteId) {
    if (!noteId) return '#';
    // Use AppConfig if available, otherwise build URL directly
    if (window.AppConfig && typeof window.AppConfig.noteViewUrl === 'function') {
        return window.AppConfig.noteViewUrl(noteId);
    }
    return `${WORKER_URL}/notes/${noteId}/view`;
}

// State
let authToken = null;
let apiKey = null;
let notes = [];
let notesViewMode = localStorage.getItem('notesViewMode') || 'date'; // 'date' or 'tags'
let currentChatMessages = [];
let availableTags = [];       // Tags for chat filter
let selectedChatTags = [];   // Currently selected tag filters (empty = "All")
let showAllTags = false;      // Whether to show all tags in overflow popup

// Selection mode state
let isSelectionMode = false;
let selectedNoteIds = new Set();

// Pagination state
let notesPage = 1;
let notesHasMore = false;
let notesPageSize = 200;
let isLoadingMoreNotes = false;

// Collapsed groups state (tracks which groups are collapsed)
let collapsedGroups = {};
let defaultCollapsed = false; // When true, new groups start collapsed

// Search deeper state
let lastSearchDeeper = null;   // { available, exclude_note_ids, message }
let lastQuery = null;          // Last query for search deeper
let lastQueryType = null;      // 'question' or 'keyword'
let isLoadingMore = false;     // Loading state for "Search Deeper"

// DOM Elements
const elements = {
    sidebar: null,
    navItems: null,
    views: {},
    chatMessages: null,
    chatInput: null,
    notesGrid: null,
    viewToggleBtns: null,
    searchInput: null,
    userEmail: null,
    userAvatar: null,
    logoutBtn: null,
};

// Render helpful tips in the welcome state
function renderWelcomeSuggestions() {
    const el = document.getElementById('welcome-suggestions');
    if (!el) return;
    el.innerHTML = `
        <div class="tips-section">
            <div class="tips-label">💡 Tips</div>
            <div class="tips-grid">
                <div class="tip-card">
                    <strong>🔍 Search</strong>
                    <span>Ask natural questions like "Show me my github invoice"</span>
                </div>
                <div class="tip-card">
                    <strong>🏷️ Filter by tag</strong>
                    <span>Use tag filters above to narrow results to a specific category</span>
                </div>
                <div class="tip-card">
                    <strong>📄 Upload</strong>
                    <span>Save PDFs, screenshots, web pages, or quick notes from our mobile app or browser extension</span>
                </div>
                <div class="tip-card">
                    <strong>🔎 Search Deeper</strong>
                    <span>Click "Search Deeper" below results to find more matching documents</span>
                </div>
            </div>
        </div>
    `;
}

// =============================================================================
// Initialize
// =============================================================================
document.addEventListener('DOMContentLoaded', async () => {
    console.log('[Dashboard] DOMContentLoaded fired');
    initElements();
    console.log('[Dashboard] initElements done, navItems:', elements.navItems?.length);
    
    // Setup event listeners FIRST so navigation works even if auth fails
    setupEventListeners();
    console.log('[Dashboard] setupEventListeners done');
    
    // Restore saved view mode (date/tags) and update toggle buttons
    const savedViewMode = localStorage.getItem('notesViewMode');
    if (savedViewMode && ['date', 'tags'].includes(savedViewMode)) {
        notesViewMode = savedViewMode;
        elements.viewToggleBtns?.forEach(btn => {
            btn.classList.toggle('active', btn.dataset.view === savedViewMode);
        });
        console.log('[Dashboard] Restored view mode:', savedViewMode);
    }
    
    // Restore saved nav view from localStorage (without triggering reload)
    const savedView = localStorage.getItem('activeView');
    if (savedView && ['chat', 'notes', 'profile'].includes(savedView)) {
        // Just update UI, don't reload data yet
        elements.navItems?.forEach(item => {
            item.classList.toggle('active', item.dataset.view === savedView);
        });
        Object.entries(elements.views).forEach(([name, el]) => {
            if (el) el.classList.toggle('active', name === savedView);
        });
        console.log('[Dashboard] Restored nav view:', savedView);
    }
    
    // Wait for auth.js to initialize supabaseClient (up to 3 seconds)
    let waitCount = 0;
    while (typeof supabaseClient === 'undefined' || !supabaseClient) {
        if (waitCount >= 30) {
            console.warn('Timeout waiting for supabaseClient, proceeding anyway');
            break;
        }
        await new Promise(r => setTimeout(r, 100));
        waitCount++;
    }
    
    try {
        await checkAuth();
    } catch (err) {
        console.error('[Dashboard] checkAuth error:', err);
    }
    console.log('[Dashboard] Initialization complete');
});

function initElements() {
    elements.navItems = document.querySelectorAll('.nav-item');
    elements.views = {
        chat: document.getElementById('view-chat'),
        notes: document.getElementById('view-notes'),
        profile: document.getElementById('view-profile'),
    };
    elements.chatMessages = document.getElementById('chat-messages');
    elements.chatInput = document.getElementById('chat-input');
    elements.notesGrid = document.getElementById('notes-grid');
    elements.viewToggleBtns = document.querySelectorAll('.toggle-btn');
    elements.searchInput = document.getElementById('notes-search');
    elements.userEmail = document.getElementById('user-email');
    elements.userAvatar = document.getElementById('user-avatar');
    elements.logoutBtn = document.getElementById('logout-btn');
}

// =============================================================================
// Authentication
// =============================================================================
async function checkAuth() {
    debugLog('checkAuth starting...');
    authToken = localStorage.getItem('access_token');
    apiKey = localStorage.getItem('api_key');
    
    debugLog(`Token: ${authToken ? authToken.substring(0,20)+'...' : 'NONE'}, ApiKey: ${apiKey ? 'SET' : 'NONE'}`);
    
    if (!authToken && !apiKey) {
        debugLog('No credentials, redirecting to index');
        window.location.href = 'index.html';
        return;
    }
    
    // Try to get user info
    try {
        debugLog('Calling /auth/me...');
        const response = await fetch(`${API_BASE}/auth/me`, {
            headers: getAuthHeaders()
        });
        
        debugLog(`/auth/me response: ${response.status}`);
        
        if (response.ok) {
            const user = await response.json();
            debugLog(`User loaded: ${user.email}`);
            updateUserInfo(user);
            loadInitialData();
        } else if (response.status === 401) {
            // Log the error response body for debugging
            const errorBody = await response.json().catch(() => ({}));
            debugLog(`401 error body: ${JSON.stringify(errorBody)}`);
            
            // Token might be expired - try to refresh via Supabase
            debugLog('Token rejected (401), trying refresh...');
            debugLog(`supabaseClient available: ${typeof supabaseClient !== 'undefined' && !!supabaseClient}`);
            const refreshed = await tryRefreshSession();
            debugLog(`Refresh result: ${refreshed}`);
            if (refreshed) {
                // Retry with new token
                authToken = localStorage.getItem('access_token');
                debugLog('Retrying /auth/me...');
                const retryResponse = await fetch(`${API_BASE}/auth/me`, {
                    headers: getAuthHeaders()
                });
                debugLog(`Retry response: ${retryResponse.status}`);
                if (retryResponse.ok) {
                    const user = await retryResponse.json();
                    debugLog(`User loaded after refresh: ${user.email}`);
                    updateUserInfo(user);
                    loadInitialData();
                    return;
                } else {
                    // Log retry error body
                    const retryErrorBody = await retryResponse.json().catch(() => ({}));
                    debugLog(`Retry 401 error body: ${JSON.stringify(retryErrorBody)}`);
                }
            }
            // Refresh failed, logout
            debugLog('Refresh failed, calling logout()');
            logout();
        } else {
            debugLog(`Unexpected response: ${response.status}`);
            // Try to continue with cached data
            loadInitialData();
        }
    } catch (err) {
        console.error('[Dashboard] Auth check failed:', err);
        // Continue with cached data if possible
        loadInitialData();
    }
}

// Try to refresh the session using Supabase client
async function tryRefreshSession() {
    try {
        // Check if Supabase client is available (from auth.js)
        if (typeof supabaseClient !== 'undefined' && supabaseClient) {
            const { data, error } = await supabaseClient.auth.refreshSession();
            if (error) {
                console.error('Session refresh failed:', error);
                return false;
            }
            if (data?.session?.access_token) {
                localStorage.setItem('access_token', data.session.access_token);
                console.log('Session refreshed successfully');
                return true;
            }
        }
        return false;
    } catch (e) {
        console.error('Session refresh error:', e);
        return false;
    }
}

function getAuthHeaders() {
    debugLog(`getAuthHeaders: apiKey=${apiKey ? apiKey.substring(0,10)+'...' : 'NONE'}, authToken=${authToken ? authToken.substring(0,20)+'...' : 'NONE'}`);
    if (apiKey) {
        debugLog('Using X-API-Key header');
        return { 'X-API-Key': apiKey };
    }
    if (authToken) {
        debugLog('Using Authorization Bearer header');
        return { 'Authorization': `Bearer ${authToken}` };
    }
    debugLog('No auth headers!');
    return {};
}

// Strip HTML tags and markdown formatting from text for clean preview
function stripHtmlAndMarkdown(text) {
    if (!text) return '';
    
    // Remove HTML tags
    let cleaned = text.replace(/<[^>]*>/g, '');
    
    // Remove markdown formatting
    // Headers
    cleaned = cleaned.replace(/^#{1,6}\s+/gm, '');
    // Bold/italic
    cleaned = cleaned.replace(/\*\*([^*]+)\*\*/g, '$1');
    cleaned = cleaned.replace(/\*([^*]+)\*/g, '$1');
    cleaned = cleaned.replace(/__([^_]+)__/g, '$1');
    cleaned = cleaned.replace(/_([^_]+)_/g, '$1');
    // Inline code
    cleaned = cleaned.replace(/`([^`]+)`/g, '$1');
    // Code blocks
    cleaned = cleaned.replace(/```[\s\S]*?```/g, '');
    // Links [text](url)
    cleaned = cleaned.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
    // Images ![alt](url)
    cleaned = cleaned.replace(/!\[([^\]]*)\]\([^)]+\)/g, '');
    // Blockquotes
    cleaned = cleaned.replace(/^>\s+/gm, '');
    // Horizontal rules
    cleaned = cleaned.replace(/^[-*_]{3,}$/gm, '');
    // List markers
    cleaned = cleaned.replace(/^[\s]*[-*+]\s+/gm, '');
    cleaned = cleaned.replace(/^[\s]*\d+\.\s+/gm, '');
    // HTML entities
    cleaned = cleaned.replace(/&nbsp;/g, ' ');
    cleaned = cleaned.replace(/&amp;/g, '&');
    cleaned = cleaned.replace(/&lt;/g, '<');
    cleaned = cleaned.replace(/&gt;/g, '>');
    cleaned = cleaned.replace(/&quot;/g, '"');
    cleaned = cleaned.replace(/&#39;/g, "'");
    // Multiple whitespace to single space
    cleaned = cleaned.replace(/\s+/g, ' ');
    // Trim
    cleaned = cleaned.trim();
    
    return cleaned;
}

// Helper: Fetch with automatic token refresh on 401
async function fetchWithAuth(url, options = {}) {
    const mergedOptions = {
        ...options,
        headers: {
            ...options.headers,
            ...getAuthHeaders()
        }
    };
    
    let response = await fetch(url, mergedOptions);
    
    // If 401, try refreshing token and retry once
    if (response.status === 401 && authToken) {
        console.log('Request 401, attempting token refresh...');
        const refreshed = await tryRefreshSession();
        if (refreshed) {
            // Update authToken from localStorage after refresh
            authToken = localStorage.getItem('access_token');
            mergedOptions.headers = {
                ...options.headers,
                ...getAuthHeaders()
            };
            response = await fetch(url, mergedOptions);
        }
    }
    
    return response;
}

function updateUserInfo(user) {
    if (elements.userEmail) {
        elements.userEmail.textContent = user.email || 'User';
    }
    if (elements.userAvatar) {
        const initial = (user.email || 'U')[0].toUpperCase();
        elements.userAvatar.textContent = initial;
    }
    // Update profile section
    const profileEmail = document.getElementById('profile-email');
    const profileUserId = document.getElementById('profile-user-id');
    if (profileEmail) {
        profileEmail.textContent = user.email || 'N/A';
    }
    if (profileUserId) {
        profileUserId.textContent = user.user_id || 'N/A';
    }
    
    // Update user greeting with first name - personalized message
    const userGreeting = document.getElementById('user-greeting');
    if (userGreeting) {
        const firstName = localStorage.getItem('user_first_name');
        if (firstName && firstName.trim()) {
            userGreeting.textContent = `Hey ${firstName}, what's on your mind today?`;
        } else {
            userGreeting.textContent = `Hey, what's on your mind today?`;
        }
    }
}

function logout() {
    debugLog('logout() called - redirecting to index.html');
    localStorage.removeItem('access_token');
    localStorage.removeItem('api_key');
    localStorage.removeItem('user_email');
    localStorage.removeItem('user_id');
    localStorage.removeItem('user_name');
    localStorage.removeItem('user_first_name');
    localStorage.removeItem('sb-auth-token');
    window.location.href = 'index.html';
}

// =============================================================================
// Data Loading
// =============================================================================
async function loadInitialData() {
    console.log('[DEBUG] loadInitialData called');
    loadNotes();
    loadStats();
    loadApiKeys();
    loadChatTags(); // Load tags for chat filter
}

// Load tags for chat filter chips
async function loadChatTags() {
    console.log('[DEBUG] loadChatTags called');
    try {
        const url = `${API_BASE}/notes/tags/all`;
        console.log('[DEBUG] Fetching tags from:', url);
        const response = await fetch(url, {
            headers: getAuthHeaders()
        });
        
        console.log('[DEBUG] Tags response status:', response.status);
        if (!response.ok) throw new Error('Failed to load tags');
        
        const data = await response.json();
        console.log('[DEBUG] Tags data:', data);
        availableTags = data.tags || [];
        console.log('[DEBUG] Available tags:', availableTags);
        renderChatTagChips();
    } catch (err) {
        console.error('[DEBUG] Load tags failed:', err);
        availableTags = [];
        renderChatTagChips();
    }
}

// Render tag filter chips above chat input
function renderChatTagChips() {
    const container = document.getElementById('chat-tag-filter');
    if (!container) return;
    
    if (availableTags.length === 0) {
        container.style.display = 'none';
        return;
    }
    
    container.style.display = 'block';
    
    // Calculate how many tags fit in one line (approx 6-8 tags)
    const MAX_VISIBLE_TAGS = 6;
    
    // Sort tags: selected first, then alphabetically
    const sortedTags = [...availableTags].sort((a, b) => {
        const aSelected = selectedChatTags.includes(a);
        const bSelected = selectedChatTags.includes(b);
        if (aSelected && !bSelected) return -1;
        if (!aSelected && bSelected) return 1;
        return a.localeCompare(b);
    });
    
    // Split into visible and overflow
    const visibleTags = sortedTags.slice(0, MAX_VISIBLE_TAGS);
    const overflowTags = sortedTags.slice(MAX_VISIBLE_TAGS);
    const hasOverflow = overflowTags.length > 0;
    
    // Build visible chips
    const visibleChipsHtml = visibleTags.map(tag => 
        `<button class="tag-chip ${selectedChatTags.includes(tag) ? 'active' : ''}" 
                onclick="toggleChatTag('${escapeHtml(tag)}')" 
                ondblclick="clearTagSelection()">${escapeHtml(tag)}</button>`
    ).join('');
    
    // Build overflow dropdown
    let overflowHtml = '';
    if (hasOverflow) {
        const overflowChipsHtml = overflowTags.map(tag => 
            `<button class="tag-chip ${selectedChatTags.includes(tag) ? 'active' : ''}" 
                    onclick="toggleChatTag('${escapeHtml(tag)}')">${escapeHtml(tag)}</button>`
        ).join('');
        overflowHtml = `
            <div class="tag-overflow-wrapper">
                <button class="tag-chip tag-overflow-btn" onclick="toggleTagOverflow(event)">+${overflowTags.length} more</button>
                <div class="tag-overflow-dropdown ${showAllTags ? 'show' : ''}" id="tag-overflow-dropdown">
                    ${overflowChipsHtml}
                </div>
            </div>
        `;
    }
    
    // Selected count indicator
    const selectedIndicator = selectedChatTags.length > 0 
        ? `<span class="tag-selected-count">${selectedChatTags.length} selected</span>` 
        : '';
    
    container.innerHTML = `
        <div class="tag-filter-row">
            <span class="tag-filter-label">Filter by Tag:</span>
            ${selectedIndicator}
            <button class="tag-chip ${selectedChatTags.length === 0 ? 'active' : ''}" 
                    onclick="clearTagSelection()">All</button>
            ${visibleChipsHtml}
            ${overflowHtml}
        </div>
    `;
}

// Toggle tag selection (multi-select)
function toggleChatTag(tag) {
    const index = selectedChatTags.indexOf(tag);
    if (index === -1) {
        selectedChatTags.push(tag);
    } else {
        selectedChatTags.splice(index, 1);
    }
    renderChatTagChips();
}

// Clear all tag selections (double-click or click "All")
function clearTagSelection() {
    selectedChatTags = [];
    showAllTags = false;
    renderChatTagChips();
}

// Toggle overflow dropdown visibility
function toggleTagOverflow(event) {
    event.stopPropagation();
    showAllTags = !showAllTags;
    const dropdown = document.getElementById('tag-overflow-dropdown');
    if (dropdown) {
        dropdown.classList.toggle('show', showAllTags);
    }
}

// Close overflow dropdown when clicking outside
document.addEventListener('click', (e) => {
    if (!e.target.closest('.tag-overflow-wrapper')) {
        showAllTags = false;
        const dropdown = document.getElementById('tag-overflow-dropdown');
        if (dropdown) dropdown.classList.remove('show');
    }
});

async function loadNotes(page = 1) {
    const container = elements.notesGrid;
    if (!container) {
        console.log('[loadNotes] Container not found');
        return;
    }
    
    console.log('[loadNotes] Starting load, page:', page);
    
    // Show loading spinner for first page
    if (page === 1) {
        console.log('[loadNotes] Showing loading spinner');
        container.innerHTML = `
            <div class="notes-loading">
                <div class="loading-spinner"></div>
                <p>Loading snaps...</p>
            </div>
        `;
    }
    
    try {
        const offset = (page - 1) * notesPageSize;
        // Sort by tag alphabetically when in tags view, by date otherwise
        const sortParam = notesViewMode === 'tags' ? '&sort=tag' : '&sort=date';
        const response = await fetch(`${API_BASE}/notes/?limit=${notesPageSize}&offset=${offset}${sortParam}`, {
            headers: getAuthHeaders()
        });
        
        if (!response.ok) throw new Error('Failed to load notes');
        
        const data = await response.json();
        const newNotes = data.notes || data || [];
        
        if (page === 1) {
            notes = newNotes;
        } else {
            notes = [...notes, ...newNotes];
        }
        
        notesPage = page;
        notesHasMore = newNotes.length >= notesPageSize;
        isLoadingMoreNotes = false;
        
        renderNotes();
    } catch (err) {
        console.error('Load notes failed:', err);
        isLoadingMoreNotes = false;
        if (page === 1) {
            container.innerHTML = `
                <div class="notes-empty">
                    <div class="notes-empty-icon">📝</div>
                    <p>No notes found or failed to load</p>
                </div>
            `;
        }
    }
}

function loadMoreNotes() {
    if (isLoadingMoreNotes || !notesHasMore) return;
    isLoadingMoreNotes = true;
    
    // Save scroll position before any changes
    const container = elements.notesGrid;
    const scrollContainer = container?.closest('.notes-grid-container');
    const savedScrollTop = scrollContainer?.scrollTop || 0;
    
    // Show loading state by updating just the button
    const existingLoadMore = container?.querySelector('.notes-load-more');
    if (existingLoadMore) {
        existingLoadMore.innerHTML = `
            <div class="load-more-loading">
                <div class="load-more-spinner"></div>
                <span>Loading more...</span>
            </div>
        `;
    }
    
    loadNotes(notesPage + 1).then(() => {
        // Restore scroll position after DOM updates
        requestAnimationFrame(() => {
            if (scrollContainer) {
                scrollContainer.scrollTop = savedScrollTop;
            }
        });
    });
}

function renderNotes() {
    const container = elements.notesGrid;
    if (!container) return;
    
    // Use notes as-is (search is now API-based)
    const searchTerm = (elements.searchInput?.value || '').toLowerCase().trim();
    let filteredNotes = notes;
    
    if (filteredNotes.length === 0) {
        container.innerHTML = `
            <div class="notes-empty">
                <div class="notes-empty-icon">📝</div>
                <p>${searchTerm ? 'No notes match your search' : 'No notes yet. Start uploading!'}</p>
            </div>
        `;
        return;
    }
    
    // Group notes
    const groups = notesViewMode === 'date' ? groupByDate(filteredNotes) : groupByTag(filteredNotes);
    const groupNames = Object.keys(groups);
    
    // Render groups
    container.innerHTML = '';
    
    // Add collapse/expand all controls
    if (groupNames.length > 1) {
        const controlsEl = document.createElement('div');
        controlsEl.className = 'notes-group-controls';
        controlsEl.innerHTML = `
            <button class="group-control-btn" onclick="collapseAllGroups()">Collapse All</button>
            <button class="group-control-btn" onclick="expandAllGroups()">Expand All</button>
        `;
        container.appendChild(controlsEl);
    }
    
    Object.entries(groups).forEach(([groupName, groupNotes]) => {
        const groupEl = document.createElement('div');
        groupEl.className = 'notes-group';
        // Use explicit state if set, otherwise use defaultCollapsed
        const isCollapsed = collapsedGroups.hasOwnProperty(groupName) ? collapsedGroups[groupName] : defaultCollapsed;
        const groupId = groupName.replace(/[^a-zA-Z0-9]/g, '-');
        
        groupEl.innerHTML = `
            <div class="notes-group-header" data-group="${encodeURIComponent(groupName)}">
                <span class="group-toggle ${isCollapsed ? 'collapsed' : ''}">${isCollapsed ? '▶' : '▼'}</span>
                <span class="group-dot"></span>
                <span class="group-title">${groupName}</span>
                <span class="group-count">${groupNotes.length}</span>
                <div class="group-line"></div>
            </div>
            <div class="notes-cards ${isCollapsed ? 'collapsed' : ''}" id="group-${groupId}"></div>
        `;
        
        // Add click handler using event delegation (safer for special characters)
        const header = groupEl.querySelector('.notes-group-header');
        header.addEventListener('click', () => toggleGroup(groupName));
        
        if (!isCollapsed) {
            const cardsContainer = groupEl.querySelector('.notes-cards');
            groupNotes.forEach(note => {
                cardsContainer.appendChild(createNoteCard(note));
            });
        }
        
        container.appendChild(groupEl);
    });
    
    // Add Load More button if there are more notes (and not searching)
    if ((notesHasMore || isLoadingMoreNotes) && !searchTerm) {
        const loadMoreEl = document.createElement('div');
        loadMoreEl.className = 'notes-load-more';
        
        if (isLoadingMoreNotes) {
            loadMoreEl.innerHTML = `
                <div class="load-more-loading">
                    <div class="load-more-spinner"></div>
                    <span>Loading more...</span>
                </div>
            `;
        } else {
            loadMoreEl.innerHTML = `
                <button class="load-more-btn" onclick="loadMoreNotes()">Load More</button>
            `;
        }
        
        container.appendChild(loadMoreEl);
    }
}

function toggleGroup(groupName) {
    collapsedGroups[groupName] = !collapsedGroups[groupName];
    renderNotes();
}

function collapseAllGroups() {
    // Set default to collapsed so new groups will also be collapsed
    defaultCollapsed = true;
    // Collapse all current groups
    const groups = notesViewMode === 'date' ? groupByDate(notes) : groupByTag(notes);
    Object.keys(groups).forEach(name => {
        collapsedGroups[name] = true;
    });
    renderNotes();
}

function expandAllGroups() {
    // Set default to expanded
    defaultCollapsed = false;
    // Expand all current groups
    collapsedGroups = {};
    renderNotes();
}

// Search notes via API
let lastSearchTerm = '';
let originalNotes = []; // Store original notes for when search is cleared

async function searchNotes() {
    const searchTerm = (elements.searchInput?.value || '').trim();
    console.log('[Search] searchNotes called, term:', searchTerm);
    
    // If search is cleared, restore original notes
    if (!searchTerm) {
        if (lastSearchTerm) {
            // Was searching, now cleared - restore notes
            console.log('[Search] Cleared search, restoring notes');
            lastSearchTerm = '';
            if (originalNotes.length > 0) {
                notes = originalNotes;
                originalNotes = [];
                renderNotes();
            } else {
                // Reload if we don't have original notes
                notesPage = 1;
                notes = [];
                notesHasMore = false;
                await loadNotes(1);
            }
        }
        return;
    }
    
    // Save original notes before first search
    if (!lastSearchTerm && notes.length > 0) {
        originalNotes = [...notes];
    }
    
    // Search API call (searches all notes, not just loaded ones)
    lastSearchTerm = searchTerm;
    console.log('[Search] Calling API with term:', searchTerm);
    try {
        const response = await fetch(`${API_BASE}/notes/?search=${encodeURIComponent(searchTerm)}&limit=500`, {
            headers: getAuthHeaders()
        });
        
        console.log('[Search] Response status:', response.status);
        if (response.ok) {
            const result = await response.json();
            console.log('[Search] Found', result.notes?.length || 0, 'notes');
            // Replace notes with search results
            notes = result.notes || [];
            notesHasMore = false; // Search shows all results
            renderNotes();
        } else {
            // API error - fall back to local filter
            console.log('[Search] API error, status:', response.status, '- falling back to local filter');
            const lowerSearch = searchTerm.toLowerCase();
            notes = originalNotes.filter(note => {
                const title = (note.title || note.file_name || '').toLowerCase();
                const content = (note.content || note.snippet || '').toLowerCase();
                return title.includes(lowerSearch) || content.includes(lowerSearch);
            });
            notesHasMore = false;
            renderNotes();
        }
    } catch (err) {
        console.error('[Search] Error:', err);
        // Fall back to local filter
        const lowerSearch = searchTerm.toLowerCase();
        notes = originalNotes.filter(note => {
            const title = (note.title || note.file_name || '').toLowerCase();
            const content = (note.content || note.snippet || '').toLowerCase();
            return title.includes(lowerSearch) || content.includes(lowerSearch);
        });
        notesHasMore = false;
        renderNotes();
    }
}

function groupByDate(notesList) {
    const groups = {};
    const groupOrder = [];
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const yesterday = new Date(today);
    yesterday.setDate(yesterday.getDate() - 1);
    
    // Start of this week (Monday)
    const thisWeekStart = new Date(today);
    thisWeekStart.setDate(today.getDate() - ((today.getDay() + 6) % 7));
    // Start of last week
    const lastWeekStart = new Date(thisWeekStart);
    lastWeekStart.setDate(lastWeekStart.getDate() - 7);
    // Start of current month
    const thisMonthStart = new Date(now.getFullYear(), now.getMonth(), 1);
    
    const monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'];
    
    notesList.forEach(note => {
        const date = new Date(note.created_at || note.uploaded_at || Date.now());
        let groupName;
        
        if (date >= today) {
            groupName = 'Today';
        } else if (date >= yesterday) {
            groupName = 'Yesterday';
        } else if (date >= thisWeekStart) {
            groupName = 'This Week';
        } else if (date >= lastWeekStart) {
            groupName = 'Last Week';
        } else if (date >= thisMonthStart) {
            groupName = 'Earlier This Month';
        } else {
            groupName = `${monthNames[date.getMonth()]} ${date.getFullYear()}`;
        }
        
        if (!groups[groupName]) {
            groups[groupName] = [];
            groupOrder.push(groupName);
        }
        groups[groupName].push(note);
    });
    
    // Return in insertion order (notes are already sorted by date desc)
    const orderedGroups = {};
    groupOrder.forEach(key => { orderedGroups[key] = groups[key]; });
    return orderedGroups;
}

function groupByTag(notesList) {
    const groups = {};
    
    notesList.forEach(note => {
        const tag = note.tag || note.file_type || 'Other';
        const groupName = capitalizeFirst(tag);
        
        if (!groups[groupName]) groups[groupName] = [];
        groups[groupName].push(note);
    });
    
    // Sort groups alphabetically
    const sortedGroups = {};
    Object.keys(groups).sort().forEach(key => {
        sortedGroups[key] = groups[key];
    });
    
    return sortedGroups;
}

function createNoteCard(note) {
    const card = document.createElement('div');
    card.className = 'note-card';
    card.dataset.noteId = note.id;
    
    const title = note.title || note.file_name || 'Untitled Note';
    const rawPreview = note.content_markdown || note.content || note.snippet || 'No preview available';
    const preview = stripHtmlAndMarkdown(rawPreview);
    const tag = note.tag || note.file_type || '';
    const date = formatDate(note.created_at || note.uploaded_at);
    const originalFilename = note.original_filename || note.file_name || '';
    
    // Determine actual file type based on metadata and filename extension
    let type = note.file_type || 'note';
    if (type === 'uploaded_file') {
        // Check if it's a webpage saved via URL (has source_url in metadata)
        if (note.metadata?.source_url) {
            type = 'webpage';
        } else if (originalFilename) {
            // Check file extension for uploaded files
            const ext = originalFilename.split('.').pop().toLowerCase();
            if (ext === 'html' || ext === 'htm') {
                type = 'webpage';
            } else if (ext === 'pdf') {
                type = 'pdf';
            } else if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'].includes(ext)) {
                type = 'image';
            } else if (['doc', 'docx'].includes(ext)) {
                type = 'word';
            }
        }
    }
    const thumbnailUrl = note.thumbnail_url || '';
    
    // Get icon based on type
    const icons = {
        pdf: '📄',
        word: '📝',
        email: '📧',
        image: '🖼️',
        note: '📋',
        quick_note: '📝',
        uploaded_file: '📁',
        screenshot: '🖼️',
        webpage: '🌐',
        default: '📁'
    };
    const icon = icons[type.toLowerCase()] || icons.default;
    
    // Escape preview for JS string
    const escapedPreview = preview.replace(/'/g, "\\'").replace(/\n/g, ' ').replace(/\r/g, '');
    const escapedTitle = escapeHtml(title).replace(/'/g, "\\'");
    
    // Check if selected
    const isSelected = selectedNoteIds.has(note.id);
    if (isSelected) {
        card.classList.add('selected');
    }
    
    card.innerHTML = `
        <div class="note-card-header" style="display: flex; align-items: flex-start; justify-content: space-between; gap: 0.5rem; position: relative;">
            <div style="display: flex; align-items: center; gap: 0.5rem; min-width: 0;">
                <label class="note-checkbox ${isSelectionMode ? 'visible' : ''}" onclick="event.stopPropagation();">
                    <input type="checkbox" ${isSelected ? 'checked' : ''} onchange="toggleNoteSelection('${note.id}', this.checked)">
                    <span class="checkmark"></span>
                </label>
                <div class="note-icon ${isSelectionMode ? 'hidden' : ''}">${icon}</div>
                ${tag ? `<span class="note-tag">${tag}</span>` : ''}
            </div>
            <div style="display: flex; gap: 4px;" class="${isSelectionMode ? 'hidden' : ''}">
                <button class="note-delete-btn" onclick="event.stopPropagation(); confirmDeleteNote('${note.id}', '${escapedTitle}')" title="Delete note">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                        <polyline points="3 6 5 6 21 6"></polyline>
                        <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
                        <line x1="10" y1="11" x2="10" y2="17"></line>
                        <line x1="14" y1="11" x2="14" y2="17"></line>
                    </svg>
                </button>
            </div>
        </div>
        <div class="note-card-content" onclick="handleNoteCardClick('${note.id}')">
            <div class="note-title">${escapeHtml(title)}</div>
            <div class="note-preview">${escapeHtml(preview.substring(0, 120))}${preview.length > 120 ? '...' : ''}</div>
            <div class="note-footer">
                <span class="note-date">${date}</span>
                <span class="note-type">${type}</span>
            </div>
        </div>
    `;
    
    return card;
}

// Handle note card click - opens note or toggles selection
function handleNoteCardClick(noteId) {
    if (isSelectionMode) {
        toggleNoteSelection(noteId);
    } else {
        openNote(noteId);
    }
}

// Toggle selection of a note
function toggleNoteSelection(noteId, checked) {
    if (checked === undefined) {
        // Toggle
        if (selectedNoteIds.has(noteId)) {
            selectedNoteIds.delete(noteId);
        } else {
            selectedNoteIds.add(noteId);
        }
    } else if (checked) {
        selectedNoteIds.add(noteId);
    } else {
        selectedNoteIds.delete(noteId);
    }
    
    // Update card visual
    const card = document.querySelector(`[data-note-id="${noteId}"]`);
    if (card) {
        const checkbox = card.querySelector('.note-checkbox input');
        if (selectedNoteIds.has(noteId)) {
            card.classList.add('selected');
            if (checkbox) checkbox.checked = true;
        } else {
            card.classList.remove('selected');
            if (checkbox) checkbox.checked = false;
        }
    }
    
    // Enter selection mode if first selection
    if (selectedNoteIds.size > 0 && !isSelectionMode) {
        enterSelectionMode();
    }
    
    // Update selection header count
    updateSelectionHeader();
    
    // Exit selection mode if no selections
    if (selectedNoteIds.size === 0 && isSelectionMode) {
        exitSelectionMode();
    }
}

// Enter selection mode
function enterSelectionMode() {
    isSelectionMode = true;
    document.body.classList.add('selection-mode');
    
    // Show checkboxes on all cards
    document.querySelectorAll('.note-checkbox').forEach(cb => cb.classList.add('visible'));
    document.querySelectorAll('.note-icon').forEach(icon => icon.classList.add('hidden'));
    document.querySelectorAll('.note-delete-btn').forEach(btn => btn.parentElement.classList.add('hidden'));
    
    // Show selection toolbar
    showSelectionToolbar();
}

// Exit selection mode
function exitSelectionMode() {
    isSelectionMode = false;
    selectedNoteIds.clear();
    document.body.classList.remove('selection-mode');
    
    // Hide checkboxes on all cards
    document.querySelectorAll('.note-checkbox').forEach(cb => cb.classList.remove('visible'));
    document.querySelectorAll('.note-icon').forEach(icon => icon.classList.remove('hidden'));
    document.querySelectorAll('.note-delete-btn').forEach(btn => btn.parentElement.classList.remove('hidden'));
    
    // Remove selected class from cards
    document.querySelectorAll('.note-card.selected').forEach(card => card.classList.remove('selected'));
    
    // Hide selection toolbar
    hideSelectionToolbar();
}

// Show selection toolbar
function showSelectionToolbar() {
    let toolbar = document.getElementById('selection-toolbar');
    if (!toolbar) {
        toolbar = document.createElement('div');
        toolbar.id = 'selection-toolbar';
        toolbar.className = 'selection-toolbar';
        toolbar.innerHTML = `
            <button class="btn-cancel" onclick="exitSelectionMode()">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <line x1="18" y1="6" x2="6" y2="18"></line>
                    <line x1="6" y1="6" x2="18" y2="18"></line>
                </svg>
            </button>
            <span class="selection-count">0 selected</span>
            <button class="btn-select-all" onclick="selectAllNotes()">Select All</button>
            <button class="btn-delete-selected" onclick="confirmBulkDelete()">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <polyline points="3 6 5 6 21 6"></polyline>
                    <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
                </svg>
                Delete
            </button>
        `;
        
        // Insert before notes-grid
        const notesGrid = document.getElementById('notes-grid');
        notesGrid.parentElement.insertBefore(toolbar, notesGrid);
    }
    toolbar.classList.add('visible');
    updateSelectionHeader();
}

// Hide selection toolbar
function hideSelectionToolbar() {
    const toolbar = document.getElementById('selection-toolbar');
    if (toolbar) {
        toolbar.classList.remove('visible');
    }
}

// Update selection count in header
function updateSelectionHeader() {
    const countEl = document.querySelector('.selection-count');
    if (countEl) {
        countEl.textContent = `${selectedNoteIds.size} selected`;
    }
    
    // Enable/disable delete button
    const deleteBtn = document.querySelector('.btn-delete-selected');
    if (deleteBtn) {
        deleteBtn.disabled = selectedNoteIds.size === 0;
    }
}

// Select all visible notes
function selectAllNotes() {
    document.querySelectorAll('.note-card').forEach(card => {
        const noteId = card.dataset.noteId;
        if (noteId) {
            selectedNoteIds.add(noteId);
            card.classList.add('selected');
            const checkbox = card.querySelector('.note-checkbox input');
            if (checkbox) checkbox.checked = true;
        }
    });
    updateSelectionHeader();
}

// Show bulk delete confirmation
function confirmBulkDelete() {
    if (selectedNoteIds.size === 0) return;
    
    let modal = document.getElementById('bulk-delete-modal');
    if (!modal) {
        modal = document.createElement('div');
        modal.id = 'bulk-delete-modal';
        modal.className = 'modal-overlay';
        document.body.appendChild(modal);
    }
    
    modal.innerHTML = `
        <div class="modal-content delete-modal">
            <div class="modal-header">
                <h3>Delete ${selectedNoteIds.size} Snaps</h3>
                <button class="modal-close" onclick="closeBulkDeleteModal()">×</button>
            </div>
            <div class="modal-body">
                <p>Are you sure you want to delete ${selectedNoteIds.size} selected snaps?</p>
                <p class="delete-warning">This action cannot be reversed or undone.</p>
            </div>
            <div class="modal-footer">
                <button class="btn btn-outline" onclick="closeBulkDeleteModal()">Cancel</button>
                <button class="btn btn-danger" id="bulk-delete-confirm-btn" onclick="performBulkDelete()">Delete All</button>
            </div>
        </div>
    `;
    
    modal.classList.add('show');
}

// Close bulk delete modal
function closeBulkDeleteModal() {
    const modal = document.getElementById('bulk-delete-modal');
    if (modal) {
        modal.classList.remove('show');
    }
}

// Perform bulk delete API call
async function performBulkDelete() {
    const deleteBtn = document.getElementById('bulk-delete-confirm-btn');
    if (deleteBtn) {
        deleteBtn.disabled = true;
        deleteBtn.textContent = 'Deleting...';
    }
    
    const idsToDelete = Array.from(selectedNoteIds);
    
    try {
        const response = await fetchWithAuth(`${API_BASE}/notes/bulk`, {
            method: 'DELETE',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ ids: idsToDelete })
        });
        
        if (response.ok) {
            const data = await response.json();
            closeBulkDeleteModal();
            
            // Remove deleted cards with animation
            const deletedIds = new Set(data.deleted || []);
            deletedIds.forEach(noteId => {
                const card = document.querySelector(`[data-note-id="${noteId}"]`);
                if (card) {
                    card.style.transition = 'opacity 0.3s, transform 0.3s';
                    card.style.opacity = '0';
                    card.style.transform = 'scale(0.9)';
                    setTimeout(() => card.remove(), 300);
                }
            });
            
            // Update notes array
            notes = notes.filter(n => !deletedIds.has(n.id));
            
            // Exit selection mode
            exitSelectionMode();
            
            // Update stats
            loadStats();
            
            // Show success toast
            const failedCount = (data.failed || []).length;
            if (failedCount > 0) {
                showToast(`Deleted ${data.total_deleted} snaps, ${failedCount} failed`, 'warning');
            } else {
                showToast(`${data.total_deleted} snaps deleted successfully`, 'success');
            }
            
            // Show empty state if no notes left
            if (notes.length === 0) {
                renderNotes();
            }
        } else {
            const errorData = await response.json().catch(() => ({}));
            throw new Error(errorData.error || 'Failed to delete snaps');
        }
    } catch (error) {
        console.error('Bulk delete failed:', error);
        showToast(error.message || 'Failed to delete snaps', 'error');
        
        if (deleteBtn) {
            deleteBtn.disabled = false;
            deleteBtn.textContent = 'Delete All';
        }
    }
}

// Toggle note card menu dropdown
function toggleNoteMenu(noteId) {
    // Close all other menus first
    document.querySelectorAll('.note-menu-dropdown.show').forEach(menu => {
        if (menu.id !== `menu-${noteId}`) {
            menu.classList.remove('show');
        }
    });
    
    const menu = document.getElementById(`menu-${noteId}`);
    if (menu) {
        menu.classList.toggle('show');
    }
}

// Close menus when clicking outside
document.addEventListener('click', (e) => {
    if (!e.target.closest('.note-card-menu')) {
        document.querySelectorAll('.note-menu-dropdown.show').forEach(menu => {
            menu.classList.remove('show');
        });
    }
});

// Open note in new tab
async function openNote(noteId) {
    try {
        const url = `${API_BASE}/notes/${noteId}/view-token`;
        const response = await fetchWithAuth(url);
        
        if (response.ok) {
            const data = await response.json();
            window.open(data.view_url, '_blank');
        } else {
            console.error('Failed to get view URL:', response.status);
            if (response.status === 401) {
                alert('Session expired. Please sign in again.');
                logout();
            } else {
                alert('Failed to open document. Please try again.');
            }
        }
    } catch (error) {
        console.error('Error opening document:', error);
        alert('Failed to open document. Please try again.');
    }
}

// Show delete confirmation modal
function confirmDeleteNote(noteId, noteTitle) {
    // Close any open menu
    document.querySelectorAll('.note-menu-dropdown.show').forEach(menu => {
        menu.classList.remove('show');
    });
    
    // Create or update modal
    let modal = document.getElementById('delete-note-modal');
    if (!modal) {
        modal = document.createElement('div');
        modal.id = 'delete-note-modal';
        modal.className = 'modal-overlay';
        document.body.appendChild(modal);
    }
    
    modal.innerHTML = `
        <div class="modal-content delete-modal">
            <div class="modal-header">
                <h3>Delete Note</h3>
                <button class="modal-close" onclick="closeDeleteModal()">×</button>
            </div>
            <div class="modal-body">
                <p>Are you sure you want to delete this note?</p>
                <p class="delete-note-title">"${noteTitle}"</p>
                <p class="delete-warning">This action cannot be reversed or undone.</p>
            </div>
            <div class="modal-footer">
                <button class="btn btn-outline" onclick="closeDeleteModal()">Cancel</button>
                <button class="btn btn-danger" onclick="deleteNote('${noteId}')">Delete</button>
            </div>
        </div>
    `;
    
    modal.classList.add('show');
}

// Close delete modal
function closeDeleteModal() {
    const modal = document.getElementById('delete-note-modal');
    if (modal) {
        modal.classList.remove('show');
    }
}

// Delete note API call
async function deleteNote(noteId) {
    const deleteBtn = document.querySelector('#delete-note-modal .btn-danger');
    if (deleteBtn) {
        deleteBtn.disabled = true;
        deleteBtn.textContent = 'Deleting...';
    }
    
    try {
        const response = await fetchWithAuth(`${API_BASE}/notes/${noteId}`, {
            method: 'DELETE'
        });
        
        if (response.ok) {
            // Close modal
            closeDeleteModal();
            
            // Remove card from DOM with animation
            const card = document.querySelector(`[data-note-id="${noteId}"]`);
            console.log('Delete - looking for card with noteId:', noteId, 'Found:', card);
            if (card) {
                card.style.transition = 'opacity 0.3s, transform 0.3s';
                card.style.opacity = '0';
                card.style.transform = 'scale(0.9)';
                setTimeout(() => {
                    card.remove();
                    // Update notes array
                    notes = notes.filter(n => n.id !== noteId);
                    // Show empty state if no notes left
                    if (notes.length === 0) {
                        renderNotes();
                    }
                }, 300);
            } else {
                // Fallback: reload all notes to ensure UI is in sync
                console.log('Card not found, reloading notes');
                await loadNotes();
            }
            
            // Update stats
            loadStats();
            
            // Show success toast
            showToast('Note deleted successfully', 'success');
        } else {
            const data = await response.json().catch(() => ({}));
            throw new Error(data.error || 'Failed to delete note');
        }
    } catch (error) {
        console.error('Delete note failed:', error);
        showToast(error.message || 'Failed to delete note', 'error');
        
        if (deleteBtn) {
            deleteBtn.disabled = false;
            deleteBtn.textContent = 'Delete';
        }
    }
}

// Toast notification
function showToast(message, type = 'info') {
    // Remove existing toast
    const existing = document.querySelector('.toast-notification');
    if (existing) existing.remove();
    
    const toast = document.createElement('div');
    toast.className = `toast-notification toast-${type}`;
    toast.innerHTML = `
        <span class="toast-icon">${type === 'success' ? '✓' : type === 'error' ? '✗' : 'ℹ'}</span>
        <span class="toast-message">${message}</span>
    `;
    document.body.appendChild(toast);
    
    // Trigger animation
    setTimeout(() => toast.classList.add('show'), 10);
    
    // Auto-remove after 3 seconds
    setTimeout(() => {
        toast.classList.remove('show');
        setTimeout(() => toast.remove(), 300);
    }, 3000);
}

// =============================================================================
// Stats & API Keys
// =============================================================================
async function loadStats() {
    const statsContainer = document.getElementById('stats-grid');
    if (!statsContainer) return;
    
    try {
        const response = await fetch(`${API_BASE}/notes/stats`, {
            headers: getAuthHeaders()
        });
        
        if (response.ok) {
            const stats = await response.json();
            document.getElementById('stat-notes').textContent = stats.total_notes || 0;
            document.getElementById('stat-google-searches').textContent = stats.google_searches || 0;
            document.getElementById('stat-other-searches').textContent = stats.dashboard_searches || 0;
        }
    } catch (err) {
        console.log('Stats not available');
    }
}

async function loadApiKeys() {
    const container = document.getElementById('api-keys-list');
    if (!container) return;
    
    try {
        const response = await fetch(`${API_BASE}/auth/api-keys`, {
            headers: getAuthHeaders()
        });
        
        if (!response.ok) throw new Error('Failed to load API keys');
        
        const keys = await response.json();
        
        if (!keys || keys.length === 0) {
            container.innerHTML = '<div class="empty-state">No API keys yet</div>';
            return;
        }
        
        container.innerHTML = keys.map(key => `
            <div class="api-key-item" data-key-id="${key.id}">
                <div class="key-info">
                    <div class="key-name">${escapeHtml(key.name || 'API Key')}</div>
                    <div class="key-meta">
                        <span class="key-preview">${key.key_preview || '••••••••'}</span>
                        <span>Created ${formatDate(key.created_at)}</span>
                    </div>
                </div>
                <div class="key-actions">
                    <button class="btn btn-outline btn-sm" onclick="deleteApiKey('${key.id}')">
                        🗑️
                    </button>
                </div>
            </div>
        `).join('');
    } catch (err) {
        console.error('Load API keys failed:', err);
        container.innerHTML = '<div class="empty-state">Failed to load API keys</div>';
    }
}

async function createApiKey(name) {
    try {
        const response = await fetch(`${API_BASE}/auth/api-keys`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...getAuthHeaders()
            },
            body: JSON.stringify({ name })
        });
        
        if (!response.ok) throw new Error('Failed to create API key');
        
        const data = await response.json();
        showApiKeyCreatedModal(data.api_key);
        loadApiKeys();
    } catch (err) {
        console.error('Create API key failed:', err);
        alert('Failed to create API key');
    }
}

async function deleteApiKey(keyId) {
    if (!confirm('Are you sure you want to delete this API key?')) return;
    
    try {
        const response = await fetch(`${API_BASE}/auth/api-keys/${keyId}`, {
            method: 'DELETE',
            headers: getAuthHeaders()
        });
        
        if (!response.ok) throw new Error('Failed to delete');
        
        loadApiKeys();
    } catch (err) {
        console.error('Delete API key failed:', err);
        alert('Failed to delete API key');
    }
}

// =============================================================================
// Chat
// =============================================================================
async function sendMessage() {
    const input = elements.chatInput;
    if (!input) return;
    
    const query = input.value.trim();
    if (!query) return;
    
    // Clear input
    input.value = '';
    input.style.height = 'auto';
    
    // Hide welcome state
    const welcome = document.querySelector('.chat-welcome');
    if (welcome) welcome.style.display = 'none';
    
    // Check if this is a new session BEFORE adding the user message to the array
    const isNewSession = currentChatMessages.length === 0;
    
    // Add user message
    addMessage('user', query);
    
    // Disable any existing Search Deeper buttons from previous messages
    document.querySelectorAll('.search-deeper-btn').forEach(btn => {
        btn.disabled = true;
        btn.style.opacity = '0.4';
        btn.style.cursor = 'default';
        btn.onclick = null;
    });
    lastSearchDeeper = null;
    
    // Show typing indicator
    const typingId = addTypingIndicator();
    
    try {
        // Use Worker's /rag-search-auth endpoint for detailed tracing
        const requestBody = {
            query,
            client_source: 'dashboard',  // Track that this came from dashboard chat
            new_session: isNewSession  // First message = fresh session
        };
        // Add tag filter if any tags are selected
        if (selectedChatTags.length > 0) {
            requestBody.tag_filter = selectedChatTags;
        }
        const response = await fetch(`${WORKER_URL}/rag-search-auth`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...getAuthHeaders()
            },
            body: JSON.stringify(requestBody)
        });
        
        if (!response.ok) throw new Error('Search failed');
        
        const data = await response.json();
        removeTypingIndicator(typingId);
        
        // Parse search_deeper data
        lastSearchDeeper = data.search_deeper || null;
        lastQuery = query;
        lastQueryType = data.query_type || null;
        
        // Format response - Worker returns results array and answer
        let answer;
        if (data.answer) {
            answer = data.answer;
        } else if (data.results && data.results.length > 0) {
            answer = `I found ${data.results.length} relevant document${data.results.length > 1 ? 's' : ''} for you:`;
        } else {
            answer = "Hmm, I couldn't find anything matching that in your collection 🤔 But don't give up! Try different keywords, check for typos, or browse your notes by tag. I'm here to help you find what you need! ✨📚";
        }
        const sources = data.results || [];
        
        // Show query rewrite indicator if the backend rewrote the query
        const rewrittenQuery = data.metadata?.spell_check?.query_rewritten;
        console.log('[SnapBot] Query rewrite metadata:', JSON.stringify(data.metadata?.spell_check));
        console.log('[SnapBot] Timing:', JSON.stringify(data.metadata?.timing));
        if (rewrittenQuery) {
            const rewriteNote = document.createElement('div');
            rewriteNote.className = 'query-rewrite-note';
            rewriteNote.style.cssText = 'font-size: 0.75em; color: #999; padding: 2px 16px 6px 52px; font-style: italic; opacity: 0.85;';
            rewriteNote.textContent = `🔄 Searched as: "${rewrittenQuery}"`;
            elements.chatMessages?.appendChild(rewriteNote);
        }

        // Store path_taken for source display logic
        window._lastRagPathTaken = data.path_taken || data.metadata?.path_taken || '';
        addMessage('assistant', answer, sources, lastSearchDeeper);
    } catch (err) {
        console.error('Search failed:', err);
        removeTypingIndicator(typingId);
        addMessage('assistant', 'Sorry, I encountered an error while searching. Please try again.');
    }
}

function addMessage(role, content, sources = [], searchDeeper = null) {
    const container = elements.chatMessages;
    if (!container) return;
    
    const msg = document.createElement('div');
    msg.className = `message ${role}`;
    
    const avatar = role === 'user' ? '👤' : '🤖';
    
    // Skip sources for answer-only paths (collection_summary, exploratory)
    const skipSourcesPaths = ['collection_summary', 'exploratory'];
    const pathTaken = window._lastRagPathTaken || '';
    
    let sourcesHtml = '';
    if (sources.length > 0 && !skipSourcesPaths.includes(pathTaken)) {
        const truncateTitle = (title, max = 60) => {
            if (!title) return 'Untitled';
            return title.length > max ? title.slice(0, max) + '…' : title;
        };
        
        // Build "Search Deeper" button HTML if available
        const searchDeeperHtml = searchDeeper?.available ? `
            <div style="margin-top: 10px; font-size: 11px; font-style: italic; color: #999; margin-bottom: 6px;">
                Not quite what you're looking for? Try searching deeper.
            </div>
            <button class="search-deeper-btn" onclick="loadMoreResults()" 
                    style="padding: 6px 12px; background: linear-gradient(135deg, #22b573 0%, #15803d 100%); 
                           color: white; border: none; border-radius: 6px; cursor: pointer; font-size: 12px;
                           display: flex; align-items: center; gap: 6px; transition: opacity 0.2s;">
                <span class="search-deeper-icon">🔎</span>
                <span>Search Deeper</span>
            </button>
        ` : '';
        
        sourcesHtml = `
            <div class="message-sources">
                <span class="sources-label">📎 ${sources.length} document${sources.length > 1 ? 's' : ''} found:</span>
                ${sources.map((s, idx) => {
                    const noteId = s.note_id || s.id;
                    const fullTitle = s.title || s.file_name || 'Document';
                    const displayTitle = escapeHtml(truncateTitle(fullTitle));
                    const tag = s.tag || 'general';
                    const fileType = s.file_type || s.content_type || '';
                    const snippet = (s.chunk_content || s.snippet || s.content_preview || fullTitle).replace(/'/g, "\\'").replace(/\n/g, ' ').replace(/\r/g, '');
                    return `
                    <a href="#" class="source-link" data-note-id="${noteId}" 
                       onclick="openSourceDocument('${noteId}'); return false;" 
                       title="Click to open document">
                        <span class="source-num">${idx + 1}</span>
                        ${displayTitle}
                        <span class="source-tag">${escapeHtml(tag)}</span>
                    </a>
                    `;
                }).join('')}
                ${searchDeeperHtml}
            </div>
        `;
    }
    
    msg.innerHTML = `
        <div class="message-avatar">${avatar}</div>
        <div class="message-content">
            ${formatMarkdown(content)}
            ${sourcesHtml}
        </div>
    `;
    
    container.appendChild(msg);
    container.scrollTop = container.scrollHeight;
    
    currentChatMessages.push({ role, content });
}

// Load more results by re-calling main search with exclude_note_ids
async function loadMoreResults() {
    if (!lastSearchDeeper?.available || isLoadingMore) return;
    
    isLoadingMore = true;
    
    // Update the LAST (active) search deeper button to show loading state
    const allBtns = document.querySelectorAll('.search-deeper-btn');
    const btn = allBtns[allBtns.length - 1];
    if (btn) {
        btn.innerHTML = '<span>⏳</span> <span>Loading...</span>';
        btn.disabled = true;
    }
    
    try {
        const requestBody = {
            query: lastQuery,
            exclude_note_ids: lastSearchDeeper.exclude_note_ids
        };
        console.log('[SearchDeeper] Sending exclude_note_ids:', lastSearchDeeper.exclude_note_ids?.length, lastSearchDeeper.exclude_note_ids);
        // Add tag filter if any tags are selected
        if (selectedChatTags.length > 0) {
            requestBody.tag_filter = selectedChatTags;
        }
        
        const response = await fetch(`${WORKER_URL}/rag-search-auth`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...getAuthHeaders()
            },
            body: JSON.stringify(requestBody)
        });
        
        if (!response.ok) throw new Error('Search deeper failed');
        
        const data = await response.json();
        const newSources = data.results || [];
        
        // Update search deeper state
        lastSearchDeeper = data.search_deeper || null;
        
        // Remove the Search Deeper button that was just clicked
        if (btn) btn.remove();
        
        // Add deeper results as a new assistant message
        if (newSources.length > 0) {
            const deeperAnswer = `Found ${newSources.length} more result${newSources.length !== 1 ? 's' : ''} for "${lastQuery}":`;
            addMessage('assistant', deeperAnswer, newSources, lastSearchDeeper);
        } else {
            addMessage('assistant', `No more results found for "${lastQuery}". Try rephrasing your query for different results.`);
        }
    } catch (err) {
        console.error('Search deeper failed:', err);
        // Re-enable button on error
        if (btn) {
            btn.innerHTML = `<span class="search-deeper-icon">🔎</span> <span>Retry</span>`;
            btn.disabled = false;
        }
    }
    
    isLoadingMore = false;
}

// Append additional sources to the last assistant message
function appendSourcesToLastMessage(newSources, searchDeeper) {
    const container = elements.chatMessages;
    if (!container) return;
    
    // Find the last assistant message
    const messages = container.querySelectorAll('.message.assistant');
    const lastMsg = messages[messages.length - 1];
    if (!lastMsg) return;
    
    const sourcesDiv = lastMsg.querySelector('.message-sources');
    if (!sourcesDiv) return;
    
    // Remove the old "Search Deeper" button
    const oldBtn = sourcesDiv.querySelector('.search-deeper-btn');
    if (oldBtn) oldBtn.remove();
    
    // Get current source count
    const existingLinks = sourcesDiv.querySelectorAll('.source-link');
    let startNum = existingLinks.length;
    
    // Add new source links
    const truncateTitle = (title, max = 60) => {
        if (!title) return 'Untitled';
        return title.length > max ? title.slice(0, max) + '…' : title;
    };
    
    newSources.forEach((s, idx) => {
        const noteId = s.note_id || s.id;
        const fullTitle = s.title || s.file_name || 'Document';
        const displayTitle = escapeHtml(truncateTitle(fullTitle));
        const tag = s.tag || 'general';
        
        const link = document.createElement('a');
        link.href = '#';
        link.className = 'source-link';
        link.dataset.noteId = noteId;
        link.onclick = (e) => { e.preventDefault(); openSourceDocument(noteId); };
        link.title = 'Click to open document';
        link.innerHTML = `
            <span class="source-num">${startNum + idx + 1}</span>
            ${displayTitle}
            <span class="source-tag">${escapeHtml(tag)}</span>
        `;
        sourcesDiv.appendChild(link);
    });
    
    // Update the source count label
    const label = sourcesDiv.querySelector('.sources-label');
    if (label) {
        const totalCount = startNum + newSources.length;
        const moreText = '';
        label.textContent = `📎 ${totalCount} document${totalCount > 1 ? 's' : ''} found${moreText}:`;
    }
    
    // Add new "Search Deeper" button if there are still more results
    if (searchDeeper?.available) {
        const wrapper = document.createElement('div');
        wrapper.innerHTML = `<div style="margin-top: 10px; font-size: 11px; font-style: italic; color: #999; margin-bottom: 6px;">Not quite what you're looking for? Try searching deeper.</div>`;
        sourcesDiv.appendChild(wrapper.firstElementChild);
        
        const btn = document.createElement('button');
        btn.className = 'search-deeper-btn';
        btn.onclick = loadMoreResults;
        btn.style.cssText = 'padding: 6px 12px; background: linear-gradient(135deg, #22b573 0%, #15803d 100%); color: white; border: none; border-radius: 6px; cursor: pointer; font-size: 12px; display: flex; align-items: center; gap: 6px; transition: opacity 0.2s;';
        btn.innerHTML = `<span class="search-deeper-icon">🔎</span> <span>Search Deeper</span>`;
        sourcesDiv.appendChild(btn);
    }
    
    // Scroll to bottom
    container.scrollTop = container.scrollHeight;
}

function addTypingIndicator() {
    const container = elements.chatMessages;
    if (!container) return null;
    
    const id = 'typing-' + Date.now();
    const msg = document.createElement('div');
    msg.className = 'message assistant';
    msg.id = id;
    
    msg.innerHTML = `
        <div class="message-avatar">🤖</div>
        <div class="message-content typing-indicator">
            Searching your documents...
        </div>
    `;
    
    container.appendChild(msg);
    container.scrollTop = container.scrollHeight;
    
    return id;
}

function removeTypingIndicator(id) {
    if (!id) return;
    const el = document.getElementById(id);
    if (el) el.remove();
}

function useSuggestion(text) {
    if (elements.chatInput) {
        elements.chatInput.value = text;
        sendMessage();
    }
}

// =============================================================================
// Navigation
// =============================================================================
function setupEventListeners() {
    console.log('[Dashboard] Setting up event listeners');
    // Navigation
    elements.navItems.forEach(item => {
        item.addEventListener('click', () => {
            const view = item.dataset.view;
            console.log('[Dashboard] Nav click:', view);
            switchView(view);
        });
    });
    console.log('[Dashboard] Nav listeners attached to', elements.navItems?.length, 'items');
    
    // Chat input
    if (elements.chatInput) {
        elements.chatInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                sendMessage();
            }
        });
        
        // Auto-resize
        elements.chatInput.addEventListener('input', () => {
            elements.chatInput.style.height = 'auto';
            elements.chatInput.style.height = Math.min(elements.chatInput.scrollHeight, 120) + 'px';
        });
    }
    
    // View toggle
    elements.viewToggleBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            notesViewMode = btn.dataset.view;
            localStorage.setItem('notesViewMode', notesViewMode);
            elements.viewToggleBtns.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            // Reset pagination and reload for the new view
            notesPage = 1;
            notes = [];
            notesHasMore = false;
            collapsedGroups = {};
            defaultCollapsed = false;
            loadNotes(1);
        });
    });
    
    // Search
    if (elements.searchInput) {
        let debounceTimer;
        elements.searchInput.addEventListener('input', () => {
            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => searchNotes(), 300);
        });
    }
    
    // Logout
    if (elements.logoutBtn) {
        elements.logoutBtn.addEventListener('click', logout);
    }
}

function switchView(viewName) {
    // Save to localStorage for persistence across refresh
    localStorage.setItem('activeView', viewName);
    
    // Update nav items
    elements.navItems.forEach(item => {
        item.classList.toggle('active', item.dataset.view === viewName);
    });
    
    // Update views
    Object.entries(elements.views).forEach(([name, el]) => {
        if (el) el.classList.toggle('active', name === viewName);
    });
    
    // Refresh data when switching views
    if (viewName === 'notes') {
        // Reset and reload notes
        notesPage = 1;
        notes = [];
        notesHasMore = false;
        collapsedGroups = {};
        defaultCollapsed = false;
        loadNotes(1);
    } else if (viewName === 'profile') {
        loadStats();
        loadApiKeys();
    }
}

// =============================================================================
// Modals
// =============================================================================
function openModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) modal.classList.add('active');
}

function closeModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) modal.classList.remove('active');
}

function showCreateKeyModal() {
    openModal('modal-create-key');
    document.getElementById('key-name-input').value = '';
}

function handleCreateKey() {
    const name = document.getElementById('key-name-input').value.trim();
    if (!name) {
        alert('Please enter a name for the API key');
        return;
    }
    closeModal('modal-create-key');
    createApiKey(name);
}

function showApiKeyCreatedModal(key) {
    const modal = document.getElementById('modal-key-created');
    const codeEl = modal.querySelector('code');
    if (codeEl) codeEl.textContent = key;
    openModal('modal-key-created');
}

function copyApiKey() {
    const codeEl = document.querySelector('#modal-key-created code');
    if (codeEl) {
        navigator.clipboard.writeText(codeEl.textContent);
        const btn = document.querySelector('#modal-key-created .btn-copy');
        if (btn) {
            const orig = btn.textContent;
            btn.textContent = 'Copied!';
            setTimeout(() => btn.textContent = orig, 2000);
        }
    }
}

// =============================================================================
// Utilities
// =============================================================================
function escapeHtml(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}

function formatDate(dateStr) {
    if (!dateStr) return '';
    const date = new Date(dateStr);
    const now = new Date();
    const diff = now - date;
    
    if (diff < 60000) return 'Just now';
    if (diff < 3600000) return Math.floor(diff / 60000) + 'm ago';
    if (diff < 86400000) return Math.floor(diff / 3600000) + 'h ago';
    if (diff < 604800000) return Math.floor(diff / 86400000) + 'd ago';
    
    return date.toLocaleDateString('en-US', {
        month: 'short',
        day: 'numeric',
        year: date.getFullYear() !== now.getFullYear() ? 'numeric' : undefined
    });
}

function capitalizeFirst(str) {
    if (!str) return '';
    return str.charAt(0).toUpperCase() + str.slice(1).toLowerCase();
}

function formatMarkdown(text) {
    if (!text) return '';

    // Split into lines and process
    const lines = text.split('\n');
    let html = '';
    let inList = false;
    let listType = ''; // 'ul' or 'ol'

    for (let i = 0; i < lines.length; i++) {
        let line = lines[i];

        // Headers
        if (line.startsWith('### ')) {
            if (inList) { html += `</${listType}>`; inList = false; }
            html += `<h4>${line.slice(4)}</h4>`;
            continue;
        }
        if (line.startsWith('## ')) {
            if (inList) { html += `</${listType}>`; inList = false; }
            html += `<h3>${line.slice(3)}</h3>`;
            continue;
        }

        // Bullet lists
        const bulletMatch = line.match(/^\s*[-*]\s+(.*)/);
        if (bulletMatch) {
            if (!inList || listType !== 'ul') {
                if (inList) html += `</${listType}>`;
                html += '<ul>';
                inList = true;
                listType = 'ul';
            }
            html += `<li>${applyInlineFormatting(bulletMatch[1])}</li>`;
            continue;
        }

        // Numbered lists
        const numMatch = line.match(/^\s*\d+[.)\s]\s*(.*)/);
        if (numMatch) {
            if (!inList || listType !== 'ol') {
                if (inList) html += `</${listType}>`;
                html += '<ol>';
                inList = true;
                listType = 'ol';
            }
            html += `<li>${applyInlineFormatting(numMatch[1])}</li>`;
            continue;
        }

        // Close any open list
        if (inList) {
            html += `</${listType}>`;
            inList = false;
        }

        // Empty line = paragraph break
        if (line.trim() === '') {
            html += '<br>';
            continue;
        }

        // Regular text
        html += `<p>${applyInlineFormatting(line)}</p>`;
    }

    if (inList) html += `</${listType}>`;

    return `<div class="formatted-answer">${html}</div>`;
}

function applyInlineFormatting(text) {
    return text
        // Markdown links: [text](url) → clickable <a> tag
        .replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer" class="doc-link">$1</a>')
        .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
        .replace(/(?<!\*)\*(?!\*)(.*?)(?<!\*)\*(?!\*)/g, '<em>$1</em>')
        .replace(/`(.*?)`/g, '<code>$1</code>');
}

// Open source document by fetching view token first
async function openSourceDocument(noteId) {
    if (!noteId) {
        alert('Document not available');
        return;
    }
    try {
        const url = `${API_BASE}/notes/${noteId}/view-token`;
        const response = await fetchWithAuth(url);
        
        if (response.ok) {
            const data = await response.json();
            window.open(data.view_url, '_blank');
        } else {
            console.error('Failed to get view URL:', response.status);
            if (response.status === 401) {
                alert('Session expired. Please sign in again.');
                logout();
            } else {
                alert('Failed to open document. Please try again.');
            }
        }
    } catch (error) {
        console.error('Error opening document:', error);
        alert('Failed to open document. Please try again.');
    }
}

// =============================================================================
// Custom Confirm/Alert Dialogs (themed)
// =============================================================================
let confirmResolve = null;
let alertResolve = null;

function showConfirmDialog(options = {}) {
    const {
        title = 'Confirm Action',
        message = 'Are you sure?',
        icon = '⚠️',
        confirmText = 'Confirm',
        confirmClass = 'btn-danger'
    } = options;
    
    document.getElementById('confirm-icon').textContent = icon;
    document.getElementById('confirm-title').textContent = title;
    document.getElementById('confirm-message').innerHTML = message;
    
    const confirmBtn = document.getElementById('confirm-action-btn');
    confirmBtn.textContent = confirmText;
    confirmBtn.className = `btn ${confirmClass}`;
    
    openModal('modal-confirm');
    
    return new Promise((resolve) => {
        confirmResolve = resolve;
    });
}

function closeConfirmDialog(result) {
    closeModal('modal-confirm');
    if (confirmResolve) {
        confirmResolve(result);
        confirmResolve = null;
    }
}

function showAlertDialog(options = {}) {
    const {
        title = 'Notice',
        message = '',
        icon = 'ℹ️'
    } = options;
    
    document.getElementById('alert-icon').textContent = icon;
    document.getElementById('alert-title').textContent = title;
    document.getElementById('alert-message').innerHTML = message;
    
    openModal('modal-alert');
    
    return new Promise((resolve) => {
        alertResolve = resolve;
    });
}

function closeAlertDialog() {
    closeModal('modal-alert');
    if (alertResolve) {
        alertResolve();
        alertResolve = null;
    }
}

// =============================================================================
// Sign Out All Devices
// =============================================================================
async function signOutAllDevices() {
    const confirmed = await showConfirmDialog({
        title: 'Sign Out All Devices',
        icon: '🔐',
        message: `This will:<br><br>
            • Log you out of all browsers<br>
            • Invalidate all Chrome extension sessions<br>
            • Delete all API keys<br>
            • Require you to sign in again everywhere`,
        confirmText: 'Sign Out All',
        confirmClass: 'btn-danger'
    });
    
    if (!confirmed) return;

    try {
        // Call the backend to revoke all sessions
        const response = await fetch(`${API_BASE}/auth/revoke-all-sessions`, {
            method: 'POST',
            headers: getAuthHeaders()
        });

        if (!response.ok) {
            const errorData = await response.json().catch(() => ({}));
            throw new Error(errorData.error || 'Failed to sign out all devices');
        }

        await showAlertDialog({
            title: 'Success!',
            icon: '✅',
            message: 'Successfully signed out of all devices.<br><br>You will now be redirected to the login page.'
        });
        
        // Clear local storage and redirect
        logout();
        
    } catch (error) {
        console.error('Sign out all devices failed:', error);
        await showAlertDialog({
            title: 'Error',
            icon: '❌',
            message: `Failed to sign out all devices:<br><br>${error.message}`
        });
    }
}

// Make functions globally available
window.sendMessage = sendMessage;
window.useSuggestion = useSuggestion;
window.openModal = openModal;
window.closeModal = closeModal;
window.showCreateKeyModal = showCreateKeyModal;
window.handleCreateKey = handleCreateKey;
window.copyApiKey = copyApiKey;
window.deleteApiKey = deleteApiKey;
window.logout = logout;
window.openSourceDocument = openSourceDocument;
window.signOutAllDevices = signOutAllDevices;
window.showConfirmDialog = showConfirmDialog;
window.closeConfirmDialog = closeConfirmDialog;
window.showAlertDialog = showAlertDialog;
window.closeAlertDialog = closeAlertDialog;
