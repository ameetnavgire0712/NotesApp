// Dashboard Chat - Handles chat with notes using RAG Search
// Uses /api/v1/search/smart endpoint (Worker-based RAG pipeline)

// =============================================================================
// State
// =============================================================================
let chatHistory = [];
let isSearching = false;
let currentPage = 1;
let hasMoreNotes = false;
const PAGE_SIZE = 20;

// =============================================================================
// Vercel AI SDK Stream Protocol Parser
// =============================================================================

/**
 * Parse Vercel AI SDK text stream protocol
 * Format:
 * - 0:"text" - text token
 * - 2:[data] - data array
 * - 3:"error" - error message
 * - d:{"finishReason":"stop"} - finish message
 */
function parseAIStreamLine(line) {
    if (!line || line.length < 2) return null;
    
    const type = line[0];
    const colonIndex = line.indexOf(':');
    if (colonIndex === -1) return null;
    
    const payload = line.slice(colonIndex + 1);
    
    try {
        switch (type) {
            case '0': // Text token
                return { type: 'text', data: JSON.parse(payload) };
            case '2': // Data array
                return { type: 'data', data: JSON.parse(payload) };
            case '3': // Error
                return { type: 'error', data: JSON.parse(payload) };
            case 'd': // Finish
                return { type: 'finish', data: JSON.parse(payload) };
            default:
                return null;
        }
    } catch (e) {
        console.warn('Failed to parse AI stream line:', line, e);
        return null;
    }
}

// =============================================================================
// View Switching
// =============================================================================

function switchView(viewName) {
    // Update nav items
    document.querySelectorAll('.nav-item').forEach(item => {
        item.classList.remove('active');
        if (item.dataset.view === viewName) {
            item.classList.add('active');
        }
    });
    
    // Update views
    document.querySelectorAll('.view').forEach(view => {
        view.classList.remove('active');
    });
    
    const targetView = document.getElementById(viewName + 'View');
    if (targetView) {
        targetView.classList.add('active');
    }
    
    // Load data for the view
    if (viewName === 'chatbot') {
        loadNotes();
    } else if (viewName === 'profile') {
        loadProfileData();
    }
}

// =============================================================================
// Chat Functions
// =============================================================================

function handleChatKeydown(event) {
    // Submit on Enter (without Shift)
    if (event.key === 'Enter' && !event.shiftKey) {
        event.preventDefault();
        sendMessage(event);
    }
}

async function sendMessage(event) {
    if (event) event.preventDefault();
    
    const input = document.getElementById('chatInput');
    const message = input.value.trim();
    
    if (!message || isSearching) return;
    
    // Clear input
    input.value = '';
    
    // Add user message to UI
    appendMessage('user', message);
    
    // Add to history
    chatHistory.push({ role: 'user', content: message });
    
    // Use RAG search with synthesis
    await ragSearchResponse(message);
}

function appendMessage(role, content, sources = null) {
    const messagesContainer = document.getElementById('chatMessages');
    
    const messageDiv = document.createElement('div');
    messageDiv.className = `message ${role}`;
    
    const avatar = role === 'user' ? '👤' : '🧠';
    
    messageDiv.innerHTML = `
        <div class="message-avatar">${avatar}</div>
        <div class="message-content">
            ${formatMessageContent(content)}
        </div>
    `;
    
    // Add sources if provided
    if (sources && sources.length > 0) {
        const sourcesDiv = document.createElement('div');
        sourcesDiv.className = 'message-sources';
        sourcesDiv.innerHTML = `
            <span class="sources-label">📚 Sources:</span>
            ${sources.map(s => `
                <a href="${s.view_url || getViewUrl(s.note_id)}" target="_blank" class="source-link">
                    ${escapeHtml(s.title || 'Untitled')}
                </a>
            `).join('')}
        `;
        messageDiv.querySelector('.message-content').appendChild(sourcesDiv);
    }
    
    messagesContainer.appendChild(messageDiv);
    messagesContainer.scrollTop = messagesContainer.scrollHeight;
    
    return messageDiv;
}

function formatMessageContent(content) {
    // Improved markdown rendering
    let formatted = escapeHtml(content);
    
    // Code blocks (before other transforms)
    formatted = formatted.replace(/```([\s\S]*?)```/g, '<pre><code>$1</code></pre>');
    
    // Inline code
    formatted = formatted.replace(/`(.*?)`/g, '<code>$1</code>');
    
    // Headers (## and ###)
    formatted = formatted.replace(/^### (.*?)$/gm, '<h4 style="margin: 0.6rem 0 0.3rem; color: hsl(155, 50%, 35%); font-size: 0.95rem;">$1</h4>');
    formatted = formatted.replace(/^## (.*?)$/gm, '<h3 style="margin: 0.8rem 0 0.4rem; color: hsl(155, 50%, 30%); font-size: 1.05rem;">$1</h3>');
    
    // Bold (before italic)
    formatted = formatted.replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>');
    
    // Italic
    formatted = formatted.replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, '<em>$1</em>');
    
    // Convert bullet lists: group consecutive "- " or "* " lines into <ul>
    formatted = formatted.replace(/((?:^|\n)(?:[*\-] .+(?:\n|$))+)/g, (match) => {
        const items = match.trim().split('\n')
            .filter(line => line.trim())
            .map(line => `<li>${line.replace(/^[*\-] /, '').trim()}</li>`)
            .join('');
        return `<ul style="margin: 0.4rem 0; padding-left: 1.4rem; list-style: disc;">${items}</ul>`;
    });
    
    // Convert numbered lists: group consecutive "1. " lines into <ol>
    formatted = formatted.replace(/((?:^|\n)(?:\d+\. .+(?:\n|$))+)/g, (match) => {
        const items = match.trim().split('\n')
            .filter(line => line.trim())
            .map(line => `<li>${line.replace(/^\d+\. /, '').trim()}</li>`)
            .join('');
        return `<ol style="margin: 0.4rem 0; padding-left: 1.4rem;">${items}</ol>`;
    });
    
    // Line breaks (but not inside lists/headers already handled)
    formatted = formatted.replace(/\n/g, '<br>');
    
    // Clean up double <br> from empty lines
    formatted = formatted.replace(/(<br>){2,}/g, '<br><br>');
    
    // Remove leading/trailing <br>
    formatted = formatted.replace(/^(<br>)+/, '').replace(/(<br>)+$/, '');
    
    return `<div class="formatted-answer">${formatted}</div>`;
}

/**
 * RAG Search Response - Uses Worker-based RAG pipeline
 * Calls Worker /rag-search-auth directly (all processing happens on Cloudflare Worker)
 */
async function ragSearchResponse(message) {
    isSearching = true;
    const sendButton = document.getElementById('sendButton');
    sendButton.disabled = true;
    sendButton.innerHTML = '<span class="loading-dots">...</span>';
    
    // Create assistant message placeholder
    const assistantMessage = appendMessage('assistant', '');
    const contentDiv = assistantMessage.querySelector('.message-content');
    contentDiv.innerHTML = '<span class="typing-indicator">🔍 Searching your notes...</span>';
    
    try {
        const startTime = performance.now();
        
        const authHeaders = await getFreshAuthHeaders();
        const response = await fetch(AppConfig.workerRagSearchUrl, {
            method: 'POST',
            headers: {
                ...authHeaders,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                query: message
                // max_results defaults to Worker's default (10)
                // Note: user_id is extracted from JWT by Worker
            })
        });
        
        const elapsed = Math.round(performance.now() - startTime);
        console.log(`RAG Search (Worker): ${elapsed}ms`);
        
        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(`Search failed (${response.status}): ${errorText}`);
        }
        
        const data = await response.json();
        console.log('RAG Search response:', data);
        
        // Build response content
        let responseHtml = '';
        
        // Show the synthesized answer if available
        if (data.answer) {
            responseHtml += formatMessageContent(data.answer);
        } else if (data.results && data.results.length > 0) {
            // No synthesis, show a summary of results
            responseHtml += `<p>I found <strong>${data.results.length}</strong> relevant notes:</p>`;
        } else {
            responseHtml += `<p>Hmm, I couldn't find anything matching that in your collection 🤔 But don't give up! Try different keywords, check for typos, or browse your notes by tag. I'm here to help you find what you need! ✨📚</p>`;
        }
        
        // Show spell correction if applied
        if (data.query_corrected && data.query_corrected !== message) {
            responseHtml += `<p class="spell-correction">🔤 Searched for: <em>"${escapeHtml(data.query_corrected)}"</em></p>`;
        }
        
        // Show search metadata
        const metadata = data.metadata || {};
        if (metadata.worker_request_id) {
            responseHtml += `<p class="search-timing">⚡ ${elapsed}ms (${metadata.path_taken || 'hybrid'} search)</p>`;
        }
        
        contentDiv.innerHTML = responseHtml;
        
        // Add sources from results (skip for collection_summary/date/multi-step paths — those are answer-only)
        const skipSourcesPaths = ['collection_summary', 'exploratory'];
        const pathTaken = data.path_taken || data.metadata?.path_taken || '';
        if (data.results && data.results.length > 0 && !skipSourcesPaths.includes(pathTaken)) {
            const truncateTitle = (title, max = 60) => {
                if (!title) return 'Untitled';
                return title.length > max ? title.slice(0, max) + '…' : title;
            };
            const getTypeIcon = (fileType) => {
                switch (fileType) {
                    case 'quick_note': return '📝';
                    case 'screenshot': return '📸';
                    case 'webpage': return '🌐';
                    default: return '📄';
                }
            };
            const sourcesDiv = document.createElement('div');
            sourcesDiv.className = 'message-sources';
            sourcesDiv.innerHTML = `
                <span class="sources-label">📎 ${data.results.length} document${data.results.length > 1 ? 's' : ''} found:</span>
                ${data.results.map((r, i) => `
                    <a href="${r.view_url || AppConfig.noteViewUrl(r.note_id)}" target="_blank" class="source-link" title="${escapeHtml(r.title || 'Untitled')}${r.file_type === 'quick_note' ? ' (Quick Note)' : ''}">
                        <span class="source-num">${getTypeIcon(r.file_type)}</span>
                        ${escapeHtml(truncateTitle(r.title))}
                        <span class="source-tag">${escapeHtml(r.tag || 'general')}</span>
                    </a>
                `).join('')}
            `;
            contentDiv.appendChild(sourcesDiv);
        }
        
        // Add to history
        const assistantContent = data.answer || `Found ${data.results?.length || 0} results`;
        chatHistory.push({ role: 'assistant', content: assistantContent });
        
        // Auto-scroll
        const messagesContainer = document.getElementById('chatMessages');
        messagesContainer.scrollTop = messagesContainer.scrollHeight;
        
    } catch (error) {
        console.error('RAG Search error:', error);
        contentDiv.innerHTML = `
            <p class="error-message">
                ❌ Sorry, search failed: ${escapeHtml(error.message)}
            </p>
            <p class="error-hint">Try refreshing the page or check your connection.</p>
        `;
    } finally {
        isSearching = false;
        sendButton.disabled = false;
        sendButton.innerHTML = '<span class="send-icon">➤</span>';
    }
}

function getViewUrl(noteId) {
    return AppConfig.noteViewUrl(noteId);
}

// =============================================================================
// Notes List Functions
// =============================================================================

async function loadNotes(page = 1) {
    const notesList = document.getElementById('notesList');
    const notesCount = document.getElementById('notesCount');
    const loadMoreBtn = document.getElementById('loadMoreNotes');
    
    if (page === 1) {
        // Show loading skeleton
        notesList.innerHTML = `
            <div class="note-item-skeleton">
                <div class="note-icon-skeleton loading-skeleton"></div>
                <div class="note-info-skeleton">
                    <div class="note-title-skeleton loading-skeleton"></div>
                    <div class="note-meta-skeleton loading-skeleton"></div>
                </div>
            </div>
            <div class="note-item-skeleton">
                <div class="note-icon-skeleton loading-skeleton"></div>
                <div class="note-info-skeleton">
                    <div class="note-title-skeleton loading-skeleton"></div>
                    <div class="note-meta-skeleton loading-skeleton"></div>
                </div>
            </div>
            <div class="note-item-skeleton">
                <div class="note-icon-skeleton loading-skeleton"></div>
                <div class="note-info-skeleton">
                    <div class="note-title-skeleton loading-skeleton"></div>
                    <div class="note-meta-skeleton loading-skeleton"></div>
                </div>
            </div>
        `;
        notesCount.textContent = 'Loading...';
    }
    
    try {
        // Use the existing notes endpoint with limit/offset pagination
        const offset = (page - 1) * PAGE_SIZE;
        const authHeaders = await getFreshAuthHeaders();
        const response = await fetch(AppConfig.notesPaginatedUrl(PAGE_SIZE, offset), {
            headers: authHeaders
        });
        
        if (!response.ok) {
            throw new Error('Failed to load notes');
        }
        
        const notes = await response.json();
        
        // The / endpoint returns an array directly, not paginated response
        notesCount.textContent = `${notes.length}+ notes`;
        hasMoreNotes = notes.length === PAGE_SIZE;
        currentPage = page;
        
        if (page === 1) {
            notesList.innerHTML = '';
        }
        
        if (notes.length === 0 && page === 1) {
            notesList.innerHTML = `
                <div class="empty-notes">
                    <p>📝 No notes yet</p>
                    <p class="empty-hint">Use the Chrome Extension to save your first note!</p>
                </div>
            `;
        } else {
            notes.forEach(note => {
                const noteEl = createNoteElement(note);
                notesList.appendChild(noteEl);
            });
        }
        
        // Show/hide load more button
        loadMoreBtn.style.display = hasMoreNotes ? 'block' : 'none';
        
    } catch (error) {
        console.error('Error loading notes:', error);
        notesList.innerHTML = `
            <div class="error-message">
                Failed to load notes. <a href="#" onclick="loadNotes()">Try again</a>
            </div>
        `;
    }
}

function createNoteElement(note) {
    const noteEl = document.createElement('a');
    noteEl.className = 'note-item';
    noteEl.href = '#';
    noteEl.onclick = async (e) => {
        e.preventDefault();
        try {
            // Fetch a view token and open the document
            const url = AppConfig.noteViewTokenUrl(note.id);
            console.log('Fetching view token from:', url);
            
            const authHeaders = await getFreshAuthHeaders();
            const response = await fetch(url, {
                headers: authHeaders
            });
            
            console.log('Response status:', response.status);
            
            if (response.ok) {
                const data = await response.json();
                console.log('View URL:', data.view_url);
                window.open(data.view_url, '_blank');
            } else {
                const errorText = await response.text();
                console.error('Failed to get view URL:', response.status, errorText);
                alert('Failed to open document. Please try again.');
            }
        } catch (error) {
            console.error('Error opening document:', error);
            alert('Failed to open document. Please try again.');
        }
    };
    
    const title = note.title || 'Untitled';
    const tag = note.tag || 'general';
    const date = note.created_at ? formatRelativeDate(note.created_at) : '';
    const fileType = note.file_type || 'note';
    
    const icon = getFileTypeIcon(fileType);
    
    noteEl.innerHTML = `
        <div class="note-icon">${icon}</div>
        <div class="note-info">
            <div class="note-title">${escapeHtml(title)}</div>
            <div class="note-meta">
                <span class="note-tag">${escapeHtml(tag)}</span>
                <span class="note-date">${date}</span>
            </div>
        </div>
    `;
    
    return noteEl;
}

function getFileTypeIcon(fileType) {
    switch (fileType) {
        case 'screenshot': return '📸';
        case 'quick_note': return '📝';
        case 'uploaded_file': return '📄';
        default: return '📑';
    }
}

function loadMoreNotes() {
    loadNotes(currentPage + 1);
}

function formatRelativeDate(dateString) {
    const date = new Date(dateString);
    const now = new Date();
    const diffMs = now - date;
    const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));
    
    if (diffDays === 0) {
        const diffHours = Math.floor(diffMs / (1000 * 60 * 60));
        if (diffHours === 0) {
            const diffMins = Math.floor(diffMs / (1000 * 60));
            return diffMins <= 1 ? 'just now' : `${diffMins}m ago`;
        }
        return `${diffHours}h ago`;
    } else if (diffDays === 1) {
        return 'yesterday';
    } else if (diffDays < 7) {
        return `${diffDays}d ago`;
    } else {
        return date.toLocaleDateString();
    }
}

// =============================================================================
// Profile Functions
// =============================================================================

async function loadProfileData() {
    const user = getCurrentUser();
    
    // Update profile info
    document.getElementById('profileEmail').textContent = user.email || 'Unknown';
    document.getElementById('profileUserId').textContent = user.id || 'Unknown';
    document.getElementById('sidebarUserEmail').textContent = user.email || 'User';
    
    // Load stats
    await loadUserStats();
    
    // Load API keys
    await loadApiKeys();
}

async function loadUserStats() {
    try {
        const authHeaders = await getFreshAuthHeaders();
        const response = await fetch(AppConfig.notesStatsUrl, {
            headers: authHeaders
        });
        
        if (!response.ok) {
            throw new Error('Failed to load stats');
        }
        
        const stats = await response.json();
        
        document.getElementById('statNotesCount').textContent = stats.total_notes;
        document.getElementById('statApiKeys').textContent = stats.total_api_keys;
        document.getElementById('statApiCalls').textContent = stats.api_calls_today;
        document.getElementById('statLastActive').textContent = stats.last_activity 
            ? formatRelativeDate(stats.last_activity) 
            : 'Never';
        
    } catch (error) {
        console.error('Error loading stats:', error);
    }
}

// =============================================================================
// Notes Search Functions (using RAG search)
// =============================================================================

let isNotesSearchMode = false;

function handleNotesSearchKeydown(event) {
    if (event.key === 'Enter') {
        event.preventDefault();
        searchNotes();
    }
    // Clear search on Escape
    if (event.key === 'Escape') {
        clearNotesSearch();
    }
}

async function searchNotes() {
    const input = document.getElementById('notesSearchInput');
    const query = input.value.trim();
    
    if (!query) {
        clearNotesSearch();
        return;
    }
    
    const notesList = document.getElementById('notesList');
    const notesCount = document.getElementById('notesCount');
    const loadMoreBtn = document.getElementById('loadMoreNotes');
    const clearBtn = document.getElementById('clearSearchBtn');
    
    // Show loading state
    notesList.innerHTML = `
        <div class="notes-search-loading">
            <span class="typing-indicator">🔍 Searching...</span>
        </div>
    `;
    notesCount.textContent = 'Searching...';
    loadMoreBtn.style.display = 'none';
    
    try {
        const startTime = performance.now();
        
        // Use Worker RAG search endpoint
        const authHeaders = await getFreshAuthHeaders();
        const response = await fetch(AppConfig.workerRagSearchUrl, {
            method: 'POST',
            headers: {
                ...authHeaders,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                query: query,
                max_results: 10
                // user_id is extracted from JWT by Worker
            })
        });
        
        const elapsed = Math.round(performance.now() - startTime);
        
        if (!response.ok) {
            throw new Error('Search failed');
        }
        
        const data = await response.json();
        const results = data.results || [];
        
        // Update UI
        isNotesSearchMode = true;
        clearBtn.style.display = 'inline-block';
        
        // Show spell correction if applied
        let searchInfo = `${results.length} results`;
        if (data.query_corrected && data.query_corrected !== query) {
            searchInfo += ` for "${data.query_corrected}"`;
        }
        searchInfo += ` (${elapsed}ms)`;
        notesCount.textContent = searchInfo;
        
        if (results.length === 0) {
            notesList.innerHTML = `
                <div class="empty-notes">
                    <p>🔍 No matching documents found</p>
                    <p class="empty-hint">Try a different search query — I can help you find any documents you've saved!</p>
                </div>
            `;
        } else {
            notesList.innerHTML = '';
            results.forEach((result, index) => {
                const noteEl = createSearchResultElement(result, index + 1);
                notesList.appendChild(noteEl);
            });
        }
        
    } catch (error) {
        console.error('Notes search error:', error);
        notesList.innerHTML = `
            <div class="error-message">
                Search failed. <a href="#" onclick="searchNotes()">Try again</a>
            </div>
        `;
    }
}

function createSearchResultElement(result, rank) {
    const noteEl = document.createElement('a');
    noteEl.className = 'note-item search-result';
    noteEl.href = '#';
    noteEl.onclick = async (e) => {
        e.preventDefault();
        // Open via view URL (already includes token from backend)
        if (result.view_url) {
            window.open(result.view_url, '_blank');
        } else {
            // Fallback to note view token endpoint
            try {
                const authHeaders = await getFreshAuthHeaders();
                const response = await fetch(AppConfig.noteViewTokenUrl(result.note_id), {
                    headers: authHeaders
                });
                if (response.ok) {
                    const data = await response.json();
                    window.open(data.view_url, '_blank');
                }
            } catch (error) {
                console.error('Error opening document:', error);
            }
        }
    };
    
    const title = result.title || 'Untitled';
    const tag = result.tag || 'general';
    const score = result.rerank_score || result.similarity_score || 0;
    const content = result.content || '';
    
    // Truncate content preview
    const preview = content.length > 100 ? content.substring(0, 100) + '...' : content;
    
    noteEl.innerHTML = `
        <div class="note-rank">#${rank}</div>
        <div class="note-info">
            <div class="note-title">${escapeHtml(title)}</div>
            <div class="note-preview">${escapeHtml(preview)}</div>
            <div class="note-meta">
                <span class="note-tag">${escapeHtml(tag)}</span>
                <span class="note-score">Score: ${score.toFixed(3)}</span>
            </div>
        </div>
    `;
    
    return noteEl;
}

function clearNotesSearch() {
    const input = document.getElementById('notesSearchInput');
    const clearBtn = document.getElementById('clearSearchBtn');
    
    input.value = '';
    clearBtn.style.display = 'none';
    isNotesSearchMode = false;
    
    // Reload regular notes list
    loadNotes(1);
}

// =============================================================================
// Initialize
// =============================================================================

document.addEventListener('DOMContentLoaded', async () => {
    // Wait for auth to be initialized
    await initSupabase();
    
    if (!isAuthenticated()) {
        window.location.href = '/';
        return;
    }
    
    // Load user info in sidebar
    const user = getCurrentUser();
    document.getElementById('sidebarUserEmail').textContent = user.email || 'User';
    
    // Load initial data for chatbot view
    loadNotes();
});
