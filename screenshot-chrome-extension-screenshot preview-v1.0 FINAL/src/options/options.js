/**
 * Options Page Controller for SecondBrain
 * Handles settings, account management, and preferences
 */

class OptionsController {
  constructor() {
    this.elements = {};
    // All API calls go to Cloudflare Worker (no Gateway/Fly.io)
    this.workerBaseUrl = 'https://notesapp-vector-search.monocle0712.workers.dev/api/v1';
    this.settings = {
      defaultTag: '',
      autoClose: true,
      showNotifications: true,
      searchSuggestions: true,
      searchBaseUrl: this.workerBaseUrl,
      uploadBaseUrl: this.workerBaseUrl
    };
    this.apiKeyVisible = false;
    this.apiKey = '';
    
    this.init();
  }

  async init() {
    this.bindElements();
    this.attachEventListeners();
    await this.loadSettings();
    await this.checkLoginStatus();
  }

  bindElements() {
    this.elements = {
      // Account elements
      loggedOutState: document.getElementById('loggedOutState'),
      loggedInState: document.getElementById('loggedInState'),
      loginBtn: document.getElementById('loginBtn'),
      logoutBtn: document.getElementById('logoutBtn'),
      userEmail: document.getElementById('userEmail'),
      userInitial: document.getElementById('userInitial'),
      
      // Settings elements
      defaultTag: document.getElementById('defaultTag'),
      autoClose: document.getElementById('autoClose'),
      showNotifications: document.getElementById('showNotifications'),
      searchSuggestions: document.getElementById('searchSuggestions'),
      
      // API Key elements
      apiKeySection: document.getElementById('apiKeySection'),
      apiKeyMasked: document.getElementById('apiKeyMasked'),
      toggleApiKey: document.getElementById('toggleApiKey'),
      
      // Actions
      saveBtn: document.getElementById('saveBtn'),
      statusMessage: document.getElementById('statusMessage')
    };
  }

  attachEventListeners() {
    // Login/Logout
    this.elements.loginBtn.addEventListener('click', () => this.handleLogin());
    this.elements.logoutBtn.addEventListener('click', () => this.handleLogout());
    
    // Save settings
    this.elements.saveBtn.addEventListener('click', () => this.saveSettings());
    
    // Toggle API key visibility
    this.elements.toggleApiKey.addEventListener('click', () => this.toggleApiKeyVisibility());
    
    // Auto-save on change
    const autoSaveElements = ['defaultTag', 'autoClose', 'showNotifications', 'searchSuggestions'];
    autoSaveElements.forEach(id => {
      const element = this.elements[id];
      if (element) {
        element.addEventListener('change', () => this.markUnsaved());
      }
    });

    // Listen for storage changes (login from popup)
    chrome.storage.onChanged.addListener((changes) => {
      if (changes.isLoggedIn || changes.userEmail) {
        this.checkLoginStatus();
      }
    });
  }

  async loadSettings() {
    try {
      const result = await chrome.storage.sync.get([
        'defaultTag',
        'autoClose',
        'showNotifications',
        'searchSuggestions',
        'apiKey'
      ]);

      // Apply loaded settings
      if (result.defaultTag !== undefined) {
        this.elements.defaultTag.value = result.defaultTag;
        this.settings.defaultTag = result.defaultTag;
      }
      
      if (result.autoClose !== undefined) {
        this.elements.autoClose.checked = result.autoClose;
        this.settings.autoClose = result.autoClose;
      }
      
      if (result.showNotifications !== undefined) {
        this.elements.showNotifications.checked = result.showNotifications;
        this.settings.showNotifications = result.showNotifications;
      }
      
      if (result.searchSuggestions !== undefined) {
        this.elements.searchSuggestions.checked = result.searchSuggestions;
        this.settings.searchSuggestions = result.searchSuggestions;
      }

      if (result.apiKey) {
        this.apiKey = result.apiKey;
      }

    } catch (error) {
      console.error('Failed to load settings:', error);
      this.showStatus('Failed to load settings', 'error');
    }
  }

  async checkLoginStatus() {
    try {
      const result = await chrome.storage.sync.get(['isLoggedIn', 'userEmail', 'apiKey']);
      
      if (result.isLoggedIn && result.userEmail) {
        this.showLoggedInState(result.userEmail);
        this.apiKey = result.apiKey || '';
        
        // Show API key section
        this.elements.apiKeySection.style.display = 'flex';
      } else {
        this.showLoggedOutState();
        this.elements.apiKeySection.style.display = 'none';
      }

    } catch (error) {
      console.error('Failed to check login status:', error);
      this.showLoggedOutState();
    }
  }

  showLoggedInState(email) {
    this.elements.loggedOutState.style.display = 'none';
    this.elements.loggedInState.style.display = 'flex';
    this.elements.userEmail.textContent = email;
    this.elements.userInitial.textContent = email.charAt(0).toUpperCase();
  }

  showLoggedOutState() {
    this.elements.loggedOutState.style.display = 'block';
    this.elements.loggedInState.style.display = 'none';
  }

  handleLogin() {
    const extensionId = chrome.runtime.id;
    // Use Worker directly for auth
    const searchBaseUrl = this.workerBaseUrl;
    const loginUrl = `${searchBaseUrl}/auth/chrome-extension/login?extension_id=${extensionId}`;
    
    // Open login page in new tab
    chrome.tabs.create({ url: loginUrl });
  }

  async handleLogout() {
    try {
      // Clear all auth data
      await chrome.storage.sync.remove(['apiKey', 'userEmail', 'isLoggedIn', 'loginTimestamp']);
      
      this.apiKey = '';
      this.showLoggedOutState();
      this.elements.apiKeySection.style.display = 'none';
      
      this.showStatus('Logged out successfully', 'success');

    } catch (error) {
      console.error('Logout failed:', error);
      this.showStatus('Failed to logout', 'error');
    }
  }

  toggleApiKeyVisibility() {
    this.apiKeyVisible = !this.apiKeyVisible;
    
    if (this.apiKeyVisible) {
      this.elements.apiKeyMasked.textContent = this.apiKey || 'No API key stored';
      this.elements.toggleApiKey.textContent = 'Hide';
    } else {
      this.elements.apiKeyMasked.textContent = '••••••••••••••••';
      this.elements.toggleApiKey.textContent = 'Show';
    }
  }

  markUnsaved() {
    this.elements.saveBtn.classList.add('unsaved');
    this.elements.saveBtn.querySelector('.btn-text').textContent = 'Save Settings *';
  }

  async saveSettings() {
    try {
      this.elements.saveBtn.disabled = true;
      this.elements.saveBtn.querySelector('.btn-text').textContent = 'Saving...';

      const settings = {
        defaultTag: this.elements.defaultTag.value.trim(),
        autoClose: this.elements.autoClose.checked,
        showNotifications: this.elements.showNotifications.checked,
        searchSuggestions: this.elements.searchSuggestions.checked
      };

      await chrome.storage.sync.set(settings);
      
      this.settings = { ...settings };
      
      this.elements.saveBtn.classList.remove('unsaved');
      this.elements.saveBtn.querySelector('.btn-text').textContent = 'Save Settings';
      
      this.showStatus('Settings saved successfully!', 'success');

    } catch (error) {
      console.error('Failed to save settings:', error);
      this.showStatus('Failed to save settings', 'error');
    } finally {
      this.elements.saveBtn.disabled = false;
    }
  }

  showStatus(message, type = 'info') {
    const statusEl = this.elements.statusMessage;
    statusEl.textContent = message;
    statusEl.className = `status-message ${type}`;
    statusEl.classList.remove('hidden');

    setTimeout(() => {
      statusEl.classList.add('hidden');
    }, 3000);
  }
}

// Initialize options controller
document.addEventListener('DOMContentLoaded', () => {
  new OptionsController();
});
