// =============================================================================
// Dashboard New - JavaScript (Loveable Design)
// v12: 2026-03-18 - Fixed initialization order, nav buttons work now
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
let notesViewMode = 'date'; // 'date' or 'tags'
let currentChatMessages = [];

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

// Generate dynamic suggestions based on user's notes
function renderWelcomeSuggestions() {
    const el = document.getElementById('welcome-suggestions');
    if (!el) return;
    if (!notes || notes.length === 0) {
        el.innerHTML = `<button class="suggestion" onclick="useSuggestion('How do I get started?')">How do I get started?</button>`;
        return;
    }
    // Collect tags and titles
    const tagCounts = {};
    const titleSnippets = [];
    notes.forEach(n => {
        if (n.tag) tagCounts[n.tag] = (tagCounts[n.tag] || 0) + 1;
        if (n.title) titleSnippets.push(n.title);
    });
    const topTags = Object.entries(tagCounts).sort((a,b) => b[1]-a[1]).slice(0,2).map(([tag]) => tag);
    const topTitles = titleSnippets.slice(0,2);
    let html = '';
    if (topTags.length > 0) {
        html += `<button class="suggestion" onclick="useSuggestion('Show me all notes about ${topTags[0]}')">Show me all notes about ${topTags[0]}</button>`;
    }
    if (topTags.length > 1) {
        html += `<button class="suggestion" onclick="useSuggestion('Summarize my ${topTags[1]} notes')">Summarize my ${topTags[1]} notes</button>`;
    }
    if (topTitles.length > 0) {
        html += `<button class="suggestion" onclick="useSuggestion('What are the main points in ${topTitles[0]}?')">What are the main points in ${topTitles[0]}?</button>`;
    }
    if (!html) {
        html = `<button class="suggestion" onclick="useSuggestion('Summarize my notes')">Summarize my notes</button>`;
    }
    el.innerHTML = html;
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
}

function logout() {
    debugLog('logout() called - redirecting to index.html');
    localStorage.removeItem('access_token');
    localStorage.removeItem('api_key');
    localStorage.removeItem('user_email');
    localStorage.removeItem('user_id');
    localStorage.removeItem('sb-auth-token');
    window.location.href = 'index.html';
}

// =============================================================================
// Data Loading
// =============================================================================
async function loadInitialData() {
    loadNotes();
    loadStats();
    loadApiKeys();
}

async function loadNotes() {
    const container = elements.notesGrid;
    if (!container) return;
    
    // Show loading skeleton
    container.innerHTML = `
        <div class="loading-skeleton">
            <div class="skeleton-group">
                <div class="skeleton-header"></div>
                <div class="skeleton-cards">
                    <div class="skeleton-card"></div>
                    <div class="skeleton-card"></div>
                    <div class="skeleton-card"></div>
                </div>
            </div>
            <div class="skeleton-group">
                <div class="skeleton-header"></div>
                <div class="skeleton-cards">
                    <div class="skeleton-card"></div>
                    <div class="skeleton-card"></div>
                </div>
            </div>
        </div>
    `;
    
    try {
        const response = await fetch(`${API_BASE}/notes/?limit=100`, {
            headers: getAuthHeaders()
        });
        
        if (!response.ok) throw new Error('Failed to load notes');
        
        const data = await response.json();
        notes = data.notes || data || [];
        renderNotes();
    } catch (err) {
        console.error('Load notes failed:', err);
        container.innerHTML = `
            <div class="notes-empty">
                <div class="notes-empty-icon">📝</div>
                <p>No notes found or failed to load</p>
            </div>
        `;
    }
}

function renderNotes() {
    const container = elements.notesGrid;
    if (!container) return;
    
    // Filter by search
    const searchTerm = (elements.searchInput?.value || '').toLowerCase().trim();
    let filteredNotes = notes;
    
    if (searchTerm) {
        filteredNotes = notes.filter(note => {
            const title = (note.title || note.file_name || '').toLowerCase();
            const content = (note.content || note.snippet || '').toLowerCase();
            return title.includes(searchTerm) || content.includes(searchTerm);
        });
    }
    
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
    
    // Render groups
    container.innerHTML = '';
    
    Object.entries(groups).forEach(([groupName, groupNotes]) => {
        const groupEl = document.createElement('div');
        groupEl.className = 'notes-group';
        
        groupEl.innerHTML = `
            <div class="notes-group-header">
                <span class="group-dot"></span>
                <span class="group-title">${groupName}</span>
                <span class="group-count">${groupNotes.length}</span>
                <div class="group-line"></div>
            </div>
            <div class="notes-cards" id="group-${groupName.replace(/\s+/g, '-')}"></div>
        `;
        
        const cardsContainer = groupEl.querySelector('.notes-cards');
        groupNotes.forEach(note => {
            cardsContainer.appendChild(createNoteCard(note));
        });
        
        container.appendChild(groupEl);
    });
}

function groupByDate(notesList) {
    const groups = {};
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const yesterday = new Date(today);
    yesterday.setDate(yesterday.getDate() - 1);
    const weekAgo = new Date(today);
    weekAgo.setDate(weekAgo.getDate() - 7);
    const monthAgo = new Date(today);
    monthAgo.setMonth(monthAgo.getMonth() - 1);
    
    notesList.forEach(note => {
        const date = new Date(note.created_at || note.uploaded_at || Date.now());
        let groupName;
        
        if (date >= today) {
            groupName = 'Today';
        } else if (date >= yesterday) {
            groupName = 'Yesterday';
        } else if (date >= weekAgo) {
            groupName = 'This Week';
        } else if (date >= monthAgo) {
            groupName = 'This Month';
        } else {
            groupName = 'Earlier';
        }
        
        if (!groups[groupName]) groups[groupName] = [];
        groups[groupName].push(note);
    });
    
    return groups;
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
    const preview = note.content_markdown || note.content || note.snippet || 'No preview available';
    const tag = note.tag || note.file_type || '';
    const date = formatDate(note.created_at || note.uploaded_at);
    const type = note.file_type || 'note';
    
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
        default: '📁'
    };
    const icon = icons[type.toLowerCase()] || icons.default;
    
    card.innerHTML = `
        <div class="note-card-header" style="display: flex; align-items: flex-start; justify-content: space-between; gap: 0.5rem; position: relative;">
            <div style="display: flex; align-items: center; gap: 0.5rem; min-width: 0;">
                <div class="note-icon">${icon}</div>
                ${tag ? `<span class="note-tag">${tag}</span>` : ''}
            </div>
            <button class="note-delete-btn" onclick="event.stopPropagation(); confirmDeleteNote('${note.id}', '${escapeHtml(title).replace(/'/g, "\\'")}')" title="Delete note">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <polyline points="3 6 5 6 21 6"></polyline>
                    <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
                    <line x1="10" y1="11" x2="10" y2="17"></line>
                    <line x1="14" y1="11" x2="14" y2="17"></line>
                </svg>
            </button>
        </div>
        <div class="note-card-content" onclick="openNote('${note.id}')">
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
            const card = document.querySelector(`.note-card[data-note-id="${noteId}"]`);
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
    
    // Add user message
    addMessage('user', query);
    
    // Show typing indicator
    const typingId = addTypingIndicator();
    
    try {
        // Use Worker's /rag-search-auth endpoint for detailed tracing
        const response = await fetch(`${WORKER_URL}/rag-search-auth`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...getAuthHeaders()
            },
            body: JSON.stringify({
                query,
                max_results: 5,
                client_source: 'dashboard'  // Track that this came from dashboard chat
            })
        });
        
        if (!response.ok) throw new Error('Search failed');
        
        const data = await response.json();
        removeTypingIndicator(typingId);
        
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
        
        // Store path_taken for source display logic
        window._lastRagPathTaken = data.path_taken || data.metadata?.path_taken || '';
        addMessage('assistant', answer, sources);
    } catch (err) {
        console.error('Search failed:', err);
        removeTypingIndicator(typingId);
        addMessage('assistant', 'Sorry, I encountered an error while searching. Please try again.');
    }
}

function addMessage(role, content, sources = []) {
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
        sourcesHtml = `
            <div class="message-sources">
                <span class="sources-label">📎 ${sources.length} document${sources.length > 1 ? 's' : ''} found:</span>
                ${sources.map((s, idx) => {
                    const noteId = s.note_id || s.id;
                    const fullTitle = s.title || s.file_name || 'Document';
                    const displayTitle = escapeHtml(truncateTitle(fullTitle));
                    const tag = escapeHtml(s.tag || 'general');
                    return `
                    <a href="#" class="source-link" data-note-id="${noteId}" onclick="openSourceDocument('${noteId}'); return false;" title="${escapeHtml(fullTitle)}">
                        <span class="source-num">${idx + 1}</span>
                        ${displayTitle}
                        <span class="source-tag">${tag}</span>
                    </a>
                    `;
                }).join('')}
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
            elements.viewToggleBtns.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            renderNotes();
        });
    });
    
    // Search
    if (elements.searchInput) {
        let debounceTimer;
        elements.searchInput.addEventListener('input', () => {
            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => renderNotes(), 300);
        });
    }
    
    // Logout
    if (elements.logoutBtn) {
        elements.logoutBtn.addEventListener('click', logout);
    }
}

function switchView(viewName) {
    // Update nav items
    elements.navItems.forEach(item => {
        item.classList.toggle('active', item.dataset.view === viewName);
    });
    
    // Update views
    Object.entries(elements.views).forEach(([name, el]) => {
        if (el) el.classList.toggle('active', name === viewName);
    });
    
    // Refresh data when switching to profile view
    if (viewName === 'profile') {
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
