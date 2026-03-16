// Dashboard.js - API Key Management and User Dashboard

// ============================================================================
// Modal Helper Functions
// ============================================================================

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

// Convenience functions called from HTML onclick
function showCreateKeyModal() {
    showModal('createKeyModal');
}

function hideCreateKeyModal() {
    hideModal('createKeyModal');
    // Reset the modal to show form again (in case user created a key and wants to create another)
    const createForm = document.getElementById('createKeyForm');
    const successDiv = document.getElementById('keyCreatedSuccess');
    if (createForm) createForm.style.display = 'block';
    if (successDiv) successDiv.style.display = 'none';
    // Refresh the keys list
    loadApiKeys();
}

// Check authentication on page load
document.addEventListener('DOMContentLoaded', async () => {
    // First initialize Supabase to process any OAuth callback tokens
    await initSupabase();
    
    // Now check if user is authenticated (after processing OAuth tokens)
    if (!isAuthenticated()) {
        window.location.href = '/';
        return;
    }
    
    // Load user info
    loadUserInfo();
    
    // Load API keys
    await loadApiKeys();
    
    // Load stats
    await loadStats();
    
    // Set up event listeners
    setupEventListeners();
});

// Load user info into header
function loadUserInfo() {
    const user = getCurrentUser();
    const userEmailEl = document.getElementById('userEmail');
    if (userEmailEl && user.email) {
        userEmailEl.textContent = user.email;
    }
}

// Load API keys from server
async function loadApiKeys() {
    const keysListEl = document.getElementById('apiKeysList');
    const emptyStateEl = document.getElementById('noKeysMessage');
    
    try {
        const authHeaders = await getFreshAuthHeaders();
        const response = await fetch(AppConfig.apiKeysUrl, {
            headers: authHeaders
        });
        
        if (!response.ok) {
            if (response.status === 401) {
                signOut();
                return;
            }
            throw new Error('Failed to load API keys');
        }
        
        const keys = await response.json();
        
        if (keys.length === 0) {
            keysListEl.style.display = 'none';
            emptyStateEl.style.display = 'block';
            // Setup guide not currently in HTML, skip for now
        } else {
            keysListEl.style.display = 'block';
            emptyStateEl.style.display = 'none';
            // Setup guide hidden when user has keys
            renderApiKeys(keys);
        }
    } catch (error) {
        console.error('Error loading API keys:', error);
        showNotification('Failed to load API keys', 'error');
    }
}

// Render API keys list
function renderApiKeys(keys) {
    const keysListEl = document.getElementById('apiKeysList');
    keysListEl.innerHTML = '';
    
    keys.forEach(key => {
        const keyEl = document.createElement('div');
        keyEl.className = 'api-key-item';
        keyEl.innerHTML = `
            <div class="key-info">
                <div class="key-name">${escapeHtml(key.name)}</div>
                <div class="key-meta">
                    <span class="key-preview">${key.key_prefix}••••••••</span>
                    <span class="key-date">Created ${formatDate(key.created_at)}</span>
                    ${key.last_used_at ? `<span class="key-used">Last used ${formatDate(key.last_used_at)}</span>` : ''}
                </div>
            </div>
            <div class="key-actions">
                <button class="btn btn-sm btn-danger" onclick="confirmDeleteKey('${key.id}', '${escapeHtml(key.name)}')">
                    Delete
                </button>
            </div>
        `;
        keysListEl.appendChild(keyEl);
    });
}

// Create new API key
async function createApiKey(event) {
    // Prevent form submission
    if (event) {
        event.preventDefault();
    }
    
    const nameInput = document.getElementById('keyName');
    const name = nameInput.value.trim();
    
    if (!name) {
        showNotification('Please enter a name for your API key', 'error');
        return;
    }
    
    const createBtn = document.getElementById('createKeyBtn');
    const originalText = createBtn ? createBtn.textContent : 'Create Key';
    if (createBtn) {
        createBtn.disabled = true;
        createBtn.textContent = 'Creating...';
    }
    
    try {
        const authHeaders = await getFreshAuthHeaders();
        const response = await fetch(AppConfig.apiKeysUrl, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...authHeaders
            },
            body: JSON.stringify({ name: name })
        });
        
        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.detail || 'Failed to create API key');
        }
        
        const result = await response.json();
        
        // Hide create form, show success with the key
        const createForm = document.getElementById('createKeyForm');
        const successDiv = document.getElementById('keyCreatedSuccess');
        const newApiKeyEl = document.getElementById('newApiKey');
        
        if (createForm) createForm.style.display = 'none';
        if (successDiv) successDiv.style.display = 'block';
        if (newApiKeyEl) newApiKeyEl.textContent = result.api_key;
        
        // Clear input
        nameInput.value = '';
        
    } catch (error) {
        console.error('Error creating API key:', error);
        showNotification(error.message, 'error');
    } finally {
        if (createBtn) {
            createBtn.disabled = false;
            createBtn.textContent = originalText;
        }
    }
}

// Show the newly created key
function showNewKeyModal(key, name) {
    // Create a temporary modal to show the key
    const modal = document.createElement('div');
    modal.className = 'modal active';
    modal.id = 'newKeyModal';
    modal.innerHTML = `
        <div class="modal-content">
            <div class="modal-header">
                <h3 class="modal-title">API Key Created!</h3>
            </div>
            <div class="modal-body">
                <div class="alert alert-warning">
                    <strong>Important:</strong> Copy your API key now. You won't be able to see it again!
                </div>
                <div class="key-display">
                    <code id="newKeyValue">${key}</code>
                    <button class="btn btn-sm btn-primary" onclick="copyToClipboard('${key}')">
                        Copy
                    </button>
                </div>
                <p class="key-name-display">Key name: <strong>${escapeHtml(name)}</strong></p>
            </div>
            <div class="modal-footer">
                <button class="btn btn-primary" onclick="closeNewKeyModal()">Done</button>
            </div>
        </div>
    `;
    document.body.appendChild(modal);
    document.body.style.overflow = 'hidden';
}

function closeNewKeyModal() {
    const modal = document.getElementById('newKeyModal');
    if (modal) {
        modal.remove();
        document.body.style.overflow = '';
    }
}

// Copy to clipboard
async function copyToClipboard(text) {
    try {
        await navigator.clipboard.writeText(text);
        showNotification('Copied to clipboard!', 'success');
    } catch (error) {
        // Fallback for older browsers
        const textArea = document.createElement('textarea');
        textArea.value = text;
        document.body.appendChild(textArea);
        textArea.select();
        document.execCommand('copy');
        document.body.removeChild(textArea);
        showNotification('Copied to clipboard!', 'success');
    }
}

// Copy API key from success modal
function copyApiKey() {
    const apiKeyEl = document.getElementById('newApiKey');
    const copyBtnText = document.getElementById('copyBtnText');
    if (apiKeyEl) {
        copyToClipboard(apiKeyEl.textContent);
        if (copyBtnText) {
            copyBtnText.textContent = 'Copied!';
            setTimeout(() => {
                copyBtnText.textContent = 'Copy';
            }, 2000);
        }
    }
}

// Confirm delete key
function confirmDeleteKey(keyId, keyName) {
    document.getElementById('deleteKeyName').textContent = keyName;
    document.getElementById('confirmDeleteBtn').onclick = () => deleteApiKey(keyId);
    showModal('deleteModal');
}

// Delete API key
async function deleteApiKey(keyId) {
    const deleteBtn = document.getElementById('confirmDeleteBtn');
    deleteBtn.disabled = true;
    deleteBtn.textContent = 'Deleting...';
    
    try {
        const authHeaders = await getFreshAuthHeaders();
        const response = await fetch(AppConfig.apiKeyDeleteUrl(keyId), {
            method: 'DELETE',
            headers: authHeaders
        });
        
        if (!response.ok) {
            throw new Error('Failed to delete API key');
        }
        
        hideModal('deleteModal');
        showNotification('API key deleted successfully', 'success');
        await loadApiKeys();
        
    } catch (error) {
        console.error('Error deleting API key:', error);
        showNotification('Failed to delete API key', 'error');
    } finally {
        deleteBtn.disabled = false;
        deleteBtn.textContent = 'Delete';
    }
}

// Load user stats
async function loadStats() {
    try {
        const authHeaders = await getFreshAuthHeaders();
        const response = await fetch(AppConfig.notesStatsUrl, {
            headers: authHeaders
        });
        
        if (response.ok) {
            const stats = await response.json();
            const notesEl = document.getElementById('notesCount');
            const searchesEl = document.getElementById('searchesCount');
            if (notesEl) notesEl.textContent = stats.total_notes || 0;
            if (searchesEl) searchesEl.textContent = stats.total_searches || 0;
        }
    } catch (error) {
        console.error('Error loading stats:', error);
    }
}

// Set up event listeners
function setupEventListeners() {
    // Create key button
    document.getElementById('createKeyBtn')?.addEventListener('click', createApiKey);
    
    // Enter key on key name input
    document.getElementById('keyName')?.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            createApiKey();
        }
    });
    
    // Sign out button
    document.getElementById('signOutBtn')?.addEventListener('click', signOut);
    
    // Modal close buttons
    document.querySelectorAll('.modal-close, .btn-cancel').forEach(btn => {
        btn.addEventListener('click', () => {
            hideAllModals();
            closeNewKeyModal();
        });
    });
    
    // Show create key modal button
    document.querySelectorAll('.show-create-key-modal').forEach(btn => {
        btn.addEventListener('click', () => showModal('createKeyModal'));
    });
}

// Show notification toast
function showNotification(message, type = 'info') {
    // Remove any existing notifications
    document.querySelectorAll('.notification').forEach(n => n.remove());
    
    const notification = document.createElement('div');
    notification.className = `notification notification-${type}`;
    notification.textContent = message;
    document.body.appendChild(notification);
    
    // Trigger animation
    setTimeout(() => notification.classList.add('show'), 10);
    
    // Remove after 3 seconds
    setTimeout(() => {
        notification.classList.remove('show');
        setTimeout(() => notification.remove(), 300);
    }, 3000);
}

// Utility functions
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function formatDate(dateString) {
    const date = new Date(dateString);
    const now = new Date();
    const diff = now - date;
    
    // Less than a minute
    if (diff < 60000) {
        return 'just now';
    }
    
    // Less than an hour
    if (diff < 3600000) {
        const mins = Math.floor(diff / 60000);
        return `${mins} minute${mins > 1 ? 's' : ''} ago`;
    }
    
    // Less than a day
    if (diff < 86400000) {
        const hours = Math.floor(diff / 3600000);
        return `${hours} hour${hours > 1 ? 's' : ''} ago`;
    }
    
    // Less than a week
    if (diff < 604800000) {
        const days = Math.floor(diff / 86400000);
        return `${days} day${days > 1 ? 's' : ''} ago`;
    }
    
    // Default to date string
    return date.toLocaleDateString();
}
