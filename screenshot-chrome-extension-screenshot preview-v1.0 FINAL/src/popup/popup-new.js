/**
 * Popup Controller for SecondBrain
 * Handles UI interactions, authentication, and API communication
 */

class PopupController {
  constructor() {
    console.log('[SecondBrain] PopupController constructor called');
    this.elements = {};
    this.isLoggedIn = false;
    this.apiKey = '';
    this.userEmail = '';
    this.defaultTag = '';
    // Separate base URLs for different services
    this.searchBaseUrl = 'https://notesapp-gateway.monocle0712.workers.dev/api/v1';  // Auth & Search via Gateway
    this.uploadBaseUrl = 'https://notesapp-upload.fly.dev/api/v1';  // Uploads
    this.selectedFile = null;
    this.screenshotData = null;
    
    this.init();
  }

  async init() {
    console.log('[SecondBrain] init() starting...');
    this.bindElements();
    console.log('[SecondBrain] Elements bound:', Object.keys(this.elements));
    console.log('[SecondBrain] loginBtn element:', this.elements.loginBtn);
    this.attachEventListeners();
    console.log('[SecondBrain] Event listeners attached');
    await this.loadSettings();
    await this.checkLoginStatus();
    await this.checkForPendingScreenshot();
    console.log('[SecondBrain] init() complete');
  }

  bindElements() {
    this.elements = {
      // States
      loadingState: document.getElementById('loadingState'),
      loggedOutState: document.getElementById('loggedOutState'),
      loggedInState: document.getElementById('loggedInState'),
      
      // Login elements
      loginBtn: document.getElementById('loginBtn'),
      apiKeyInput: document.getElementById('apiKeyInput'),
      loginError: document.getElementById('loginError'),
      logoutBtn: document.getElementById('logoutBtn'),
      userAvatar: document.getElementById('userAvatar'),
      userEmail: document.getElementById('userEmail'),
      
      // Action buttons
      captureBtn: document.getElementById('captureBtn'),
      uploadBtn: document.getElementById('uploadBtn'),
      notesBtn: document.getElementById('notesBtn'),
      saveWebpageBtn: document.getElementById('saveWebpageBtn'),
      settingsBtn: document.getElementById('settingsBtn'),
      helpBtn: document.getElementById('helpBtn'),
      
      // File input
      fileInput: document.getElementById('fileInput'),
      
      // File upload section
      fileUploadSection: document.getElementById('fileUploadSection'),
      selectedFileName: document.getElementById('selectedFileName'),
      selectedFileSize: document.getElementById('selectedFileSize'),
      fileTag: document.getElementById('fileTag'),
      confirmFileUploadBtn: document.getElementById('confirmFileUploadBtn'),
      cancelFileUploadBtn: document.getElementById('cancelFileUploadBtn'),
      
      // Notes section
      notesEditorSection: document.getElementById('notesEditorSection'),
      notesTextarea: document.getElementById('notesTextarea'),
      noteTag: document.getElementById('noteTag'),
      saveNoteBtn: document.getElementById('saveNoteBtn'),
      cancelNoteBtn: document.getElementById('cancelNoteBtn'),
      
      // Screenshot preview section
      previewSection: document.getElementById('previewSection'),
      previewImage: document.getElementById('previewImage'),
      previewDimensions: document.getElementById('previewDimensions'),
      screenshotTag: document.getElementById('screenshotTag'),
      saveScreenshotBtn: document.getElementById('saveScreenshotBtn'),
      retakeBtn: document.getElementById('retakeBtn'),
      cancelScreenshotBtn: document.getElementById('cancelScreenshotBtn'),
      
      // Webpage section
      webpageSection: document.getElementById('webpageSection'),
      webpageTitle: document.getElementById('webpageTitle'),
      webpageUrl: document.getElementById('webpageUrl'),
      webpageTag: document.getElementById('webpageTag'),
      confirmWebpageBtn: document.getElementById('confirmWebpageBtn'),
      cancelWebpageBtn: document.getElementById('cancelWebpageBtn'),
      
      // Status
      statusMessage: document.getElementById('statusMessage'),
      toastContainer: document.getElementById('toastContainer')
    };
  }

  attachEventListeners() {
    // Login/Logout
    if (this.elements.loginBtn) {
      console.log('[SecondBrain] Attaching click listener to loginBtn');
      this.elements.loginBtn.addEventListener('click', (e) => {
        console.log('[SecondBrain] Login button CLICKED!', e);
        this.handleLogin();
      });
    } else {
      console.log('[SecondBrain] WARNING: loginBtn is null/undefined');
    }
    this.elements.logoutBtn?.addEventListener('click', () => this.handleLogout());
    
    // Action buttons
    this.elements.captureBtn?.addEventListener('click', () => this.handleCapture());
    this.elements.uploadBtn?.addEventListener('click', () => this.elements.fileInput.click());
    this.elements.notesBtn?.addEventListener('click', () => this.showNotesEditor());
    this.elements.saveWebpageBtn?.addEventListener('click', () => this.saveWebpage());
    this.elements.settingsBtn?.addEventListener('click', () => this.openSettings());
    this.elements.helpBtn?.addEventListener('click', () => this.openHelp());
    
    // File handling
    this.elements.fileInput?.addEventListener('change', (e) => this.handleFileSelected(e));
    this.elements.confirmFileUploadBtn?.addEventListener('click', () => this.uploadFile());
    this.elements.cancelFileUploadBtn?.addEventListener('click', () => this.cancelFileUpload());
    
    // Webpage handling
    this.elements.confirmWebpageBtn?.addEventListener('click', () => this.confirmSaveWebpage());
    this.elements.cancelWebpageBtn?.addEventListener('click', () => this.cancelWebpage());
    
    // Notes handling
    this.elements.saveNoteBtn?.addEventListener('click', () => this.saveNote());
    this.elements.cancelNoteBtn?.addEventListener('click', () => this.cancelNotes());
    
    // Screenshot handling
    this.elements.saveScreenshotBtn?.addEventListener('click', () => this.saveScreenshot());
    this.elements.retakeBtn?.addEventListener('click', () => this.retakeScreenshot());
    this.elements.cancelScreenshotBtn?.addEventListener('click', () => this.cancelScreenshot());

    // Listen for storage changes
    chrome.storage.onChanged.addListener((changes) => {
      if (changes.preview_screenshot) {
        this.checkForPendingScreenshot();
      }
      if (changes.isLoggedIn || changes.apiKey) {
        this.checkLoginStatus();
      }
    });
  }

  async loadSettings() {
    try {
      const result = await chrome.storage.sync.get([
        'apiKey', 'userEmail', 'isLoggedIn', 'defaultTag', 'searchBaseUrl', 'uploadBaseUrl'
      ]);
      
      this.apiKey = result.apiKey || '';
      this.userEmail = result.userEmail || '';
      this.isLoggedIn = result.isLoggedIn || false;
      this.defaultTag = result.defaultTag || '';
      this.searchBaseUrl = result.searchBaseUrl || 'https://notesapp-gateway.monocle0712.workers.dev/api/v1';
      this.uploadBaseUrl = result.uploadBaseUrl || 'https://notesapp-upload.fly.dev/api/v1';
      
    } catch (error) {
      console.error('Failed to load settings:', error);
    }
  }

  async checkLoginStatus() {
    try {
      const result = await chrome.storage.sync.get(['isLoggedIn', 'userEmail', 'apiKey']);
      
      this.isLoggedIn = result.isLoggedIn || false;
      this.userEmail = result.userEmail || '';
      this.apiKey = result.apiKey || '';
      
      // Hide loading state
      this.elements.loadingState.classList.add('hidden');
      
      if (this.isLoggedIn && this.apiKey) {
        this.showLoggedInState();
      } else {
        this.showLoggedOutState();
      }
      
    } catch (error) {
      console.error('Failed to check login status:', error);
      this.showLoggedOutState();
    }
  }

  showLoggedInState() {
    this.elements.loggedOutState.classList.add('hidden');
    this.elements.loggedInState.classList.remove('hidden');
    this.elements.logoutBtn.classList.remove('hidden');
    
    // Update user info
    this.elements.userEmail.textContent = this.userEmail;
    this.elements.userAvatar.textContent = this.userEmail.charAt(0).toUpperCase();
    
    // Pre-fill default tag
    if (this.defaultTag) {
      if (this.elements.fileTag) this.elements.fileTag.value = this.defaultTag;
      if (this.elements.noteTag) this.elements.noteTag.value = this.defaultTag;
      if (this.elements.screenshotTag) this.elements.screenshotTag.value = this.defaultTag;
    }
  }

  showLoggedOutState() {
    this.elements.loggedInState.classList.add('hidden');
    this.elements.loggedOutState.classList.remove('hidden');
    this.elements.logoutBtn.classList.add('hidden');
    // Clear any previous error
    if (this.elements.loginError) {
      this.elements.loginError.classList.add('hidden');
      this.elements.loginError.textContent = '';
    }
    // Clear API key input
    if (this.elements.apiKeyInput) {
      this.elements.apiKeyInput.value = '';
    }
  }

  async handleLogin() {
    console.log('[SecondBrain] handleLogin() called');
    
    const apiKeyInput = this.elements.apiKeyInput;
    const loginError = this.elements.loginError;
    const loginBtn = this.elements.loginBtn;
    
    // Get the entered API key
    const enteredApiKey = apiKeyInput?.value?.trim();
    
    if (!enteredApiKey) {
      this.showLoginError('Please enter your API key');
      return;
    }
    
    try {
      // Disable button while validating
      if (loginBtn) {
        loginBtn.disabled = true;
        loginBtn.querySelector('span:last-child').textContent = 'Validating...';
      }
      
      // Validate API key by calling /auth/me endpoint
      console.log('[SecondBrain] Validating API key against:', `${this.searchBaseUrl}/auth/me`);
      const response = await fetch(`${this.searchBaseUrl}/auth/me`, {
        method: 'GET',
        headers: {
          'X-API-Key': enteredApiKey
        }
      });
      
      console.log('[SecondBrain] Response status:', response.status);
      
      if (!response.ok) {
        const errorText = await response.text();
        console.log('[SecondBrain] Error response:', errorText);
        if (response.status === 401 || response.status === 403) {
          throw new Error('Invalid API key. Please check and try again.');
        }
        throw new Error(`Validation failed (${response.status}). Please try again.`);
      }
      
      const data = await response.json();
      console.log('[SecondBrain] API key validated, full response:', JSON.stringify(data, null, 2));
      
      // Try different possible email fields from the response
      const userEmail = data.email || data.user?.email || data.user_email || data.username || data.name || 'User';
      console.log('[SecondBrain] Extracted email:', userEmail);
      
      // Store credentials
      await chrome.storage.sync.set({
        apiKey: enteredApiKey,
        userEmail: userEmail,
        isLoggedIn: true,
        loginTimestamp: Date.now()
      });
      
      this.apiKey = enteredApiKey;
      this.userEmail = userEmail;
      this.isLoggedIn = true;
      
      this.showLoggedInState();
      this.showToast('Signed in successfully! 🎉', 'success');
      
    } catch (error) {
      console.error('[SecondBrain] Login failed:', error);
      this.showLoginError(error.message || 'Failed to sign in');
    } finally {
      // Re-enable button
      if (loginBtn) {
        loginBtn.disabled = false;
        loginBtn.querySelector('span:last-child').textContent = 'Sign In';
      }
    }
  }

  showLoginError(message) {
    const loginError = this.elements.loginError;
    if (loginError) {
      loginError.textContent = message;
      loginError.classList.remove('hidden');
    }
  }

  async handleLogout() {
    try {
      await chrome.storage.sync.remove(['apiKey', 'userEmail', 'isLoggedIn', 'loginTimestamp']);
      
      this.isLoggedIn = false;
      this.apiKey = '';
      this.userEmail = '';
      
      this.showLoggedOutState();
      this.showToast('Logged out successfully', 'success');
      
    } catch (error) {
      console.error('Logout failed:', error);
      this.showToast('Failed to logout', 'error');
    }
  }

  // ==================== Screenshot Handling ====================

  async handleCapture() {
    try {
      this.setButtonLoading(this.elements.captureBtn, true);
      
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      
      if (!tab) {
        throw new Error('No active tab found');
      }

      if (this.isRestrictedUrl(tab.url)) {
        throw new Error('Cannot capture screenshots on this page');
      }

      // Try to send message to content script, inject if not available
      try {
        await chrome.tabs.sendMessage(tab.id, { action: 'ping' });
      } catch (e) {
        // Content script not loaded, inject it first
        console.log('Content script not found, injecting...');
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          files: ['src/content.js']
        });
        await chrome.scripting.insertCSS({
          target: { tabId: tab.id },
          files: ['src/screenshot/screenshot.css']
        });
        // Wait a moment for script to initialize
        await new Promise(resolve => setTimeout(resolve, 100));
      }

      // Now send the capture message
      await chrome.tabs.sendMessage(tab.id, { action: 'startCapture' });
      
      // Close popup - screenshot will be handled when user returns
      window.close();
      
    } catch (error) {
      console.error('Capture failed:', error);
      this.showToast(error.message, 'error');
    } finally {
      this.setButtonLoading(this.elements.captureBtn, false);
    }
  }

  async checkForPendingScreenshot() {
    try {
      const result = await chrome.storage.local.get(['preview_screenshot']);
      
      if (result.preview_screenshot && result.preview_screenshot.dataUrl) {
        this.screenshotData = result.preview_screenshot;
        this.showScreenshotPreview();
        
        // Clear the stored screenshot
        await chrome.storage.local.remove(['preview_screenshot']);
      }
    } catch (error) {
      console.error('Failed to check for pending screenshot:', error);
    }
  }

  showScreenshotPreview() {
    if (!this.screenshotData) return;
    
    // Hide other sections
    this.hideAllDetailSections();
    
    // Show preview section
    this.elements.previewSection.classList.remove('hidden');
    this.elements.previewImage.src = this.screenshotData.dataUrl;
    
    if (this.screenshotData.dimensions) {
      this.elements.previewDimensions.textContent = 
        `${this.screenshotData.dimensions.width} × ${this.screenshotData.dimensions.height}`;
    }
    
    // Pre-fill default tag
    if (this.defaultTag) {
      this.elements.screenshotTag.value = this.defaultTag;
    }
  }

  async saveScreenshot() {
    if (!this.screenshotData) {
      this.showToast('No screenshot to save', 'error');
      return;
    }

    const tag = this.elements.screenshotTag.value.trim();
    if (!tag) {
      this.showToast('Tag is required', 'warning');
      this.elements.screenshotTag.focus();
      return;
    }

    try {
      this.setButtonLoading(this.elements.saveScreenshotBtn, true);
      
      // Convert base64 to blob
      const response = await fetch(this.screenshotData.dataUrl);
      const blob = await response.blob();
      
      // Create form data
      const formData = new FormData();
      formData.append('file', blob, `screenshot-${Date.now()}.png`);
      formData.append('tag', tag);
      
      // Upload to API
      const result = await this.apiRequest('/upload/screenshot', {
        method: 'POST',
        body: formData
      });
      
      this.showToast('Screenshot saved successfully! ☁️', 'success');
      this.triggerCacheSync();
      this.cancelScreenshot();
      
      // Close popup after short delay
      setTimeout(() => window.close(), 1500);
      
    } catch (error) {
      console.error('Failed to save screenshot:', error);
      this.showToast(error.message || 'Failed to save screenshot', 'error');
    } finally {
      this.setButtonLoading(this.elements.saveScreenshotBtn, false);
    }
  }

  retakeScreenshot() {
    this.cancelScreenshot();
    this.handleCapture();
  }

  cancelScreenshot() {
    this.screenshotData = null;
    this.elements.previewSection.classList.add('hidden');
    this.elements.previewImage.src = '';
    this.elements.screenshotTag.value = this.defaultTag;
  }

  // ==================== Save Webpage Handling ====================

  async saveWebpage() {
    try {
      this.setButtonLoading(this.elements.saveWebpageBtn, true);

      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      
      if (!tab) {
        throw new Error('No active tab found');
      }

      if (this.isRestrictedUrl(tab.url)) {
        throw new Error('Cannot save this page (restricted URL)');
      }

      // Store tab info for later use
      this.webpageData = {
        tabId: tab.id,
        title: tab.title || 'Untitled Page',
        url: tab.url
      };

      // Show webpage section
      this.hideAllDetailSections();
      this.elements.webpageSection.classList.remove('hidden');
      this.elements.webpageTitle.textContent = this.webpageData.title;
      this.elements.webpageUrl.textContent = this.webpageData.url;
      
      // Pre-fill default tag
      if (this.defaultTag) {
        this.elements.webpageTag.value = this.defaultTag;
      }
      this.elements.webpageTag.focus();

    } catch (error) {
      console.error('Failed to prepare webpage save:', error);
      this.showToast(error.message || 'Failed to prepare webpage', 'error');
    } finally {
      this.setButtonLoading(this.elements.saveWebpageBtn, false);
    }
  }

  async confirmSaveWebpage() {
    const tag = this.elements.webpageTag.value.trim();
    if (!tag) {
      this.showToast('Tag is required', 'warning');
      this.elements.webpageTag.focus();
      return;
    }

    if (!this.webpageData) {
      this.showToast('No webpage data', 'error');
      return;
    }

    try {
      this.setButtonLoading(this.elements.confirmWebpageBtn, true);
      this.showToast('Generating PDF...', 'info');

      // Generate PDF using chrome.debugger API
      const pdfData = await this.capturePageAsPDF(this.webpageData.tabId);

      if (!pdfData) {
        throw new Error('Failed to generate PDF');
      }

      this.showToast('Uploading...', 'info');

      // Convert base64 to blob
      const pdfBlob = this.base64ToBlob(pdfData, 'application/pdf');

      // Generate filename from title (sanitized, max 50 chars)
      const sanitizedTitle = this.webpageData.title
        .replace(/[<>:"/\\|?*]/g, '')
        .replace(/\s+/g, '_')
        .substring(0, 50)
        || 'webpage';
      const filename = `${sanitizedTitle}.pdf`;

      // Create form data
      const formData = new FormData();
      formData.append('file', pdfBlob, filename);
      formData.append('tag', tag);
      formData.append('source_url', this.webpageData.url);

      // Upload to API
      const result = await this.apiRequest('/upload/file', {
        method: 'POST',
        body: formData
      });

      this.showToast('✅ Webpage saved as PDF!', 'success');
      this.triggerCacheSync();
      this.cancelWebpage();

      // Close popup after short delay
      setTimeout(() => window.close(), 1500);

    } catch (error) {
      console.error('Failed to save webpage:', error);
      this.showToast(error.message || 'Failed to save webpage', 'error');
    } finally {
      this.setButtonLoading(this.elements.confirmWebpageBtn, false);
    }
  }

  async capturePageAsPDF(tabId) {
    return new Promise((resolve, reject) => {
      const debuggeeId = { tabId: tabId };

      // Attach debugger
      chrome.debugger.attach(debuggeeId, '1.3', async () => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
          return;
        }

        try {
          // Generate PDF
          chrome.debugger.sendCommand(debuggeeId, 'Page.printToPDF', {
            printBackground: true,
            preferCSSPageSize: true,
            paperWidth: 8.5,
            paperHeight: 11,
            marginTop: 0.4,
            marginBottom: 0.4,
            marginLeft: 0.4,
            marginRight: 0.4
          }, (result) => {
            // Detach debugger regardless of result
            chrome.debugger.detach(debuggeeId, () => {
              if (chrome.runtime.lastError) {
                console.warn('Debugger detach warning:', chrome.runtime.lastError.message);
              }
            });

            if (chrome.runtime.lastError) {
              reject(new Error(chrome.runtime.lastError.message));
              return;
            }

            if (result && result.data) {
              resolve(result.data); // base64 encoded PDF
            } else {
              reject(new Error('No PDF data returned'));
            }
          });
        } catch (error) {
          chrome.debugger.detach(debuggeeId, () => {});
          reject(error);
        }
      });
    });
  }

  base64ToBlob(base64, mimeType) {
    const byteCharacters = atob(base64);
    const byteNumbers = new Array(byteCharacters.length);
    for (let i = 0; i < byteCharacters.length; i++) {
      byteNumbers[i] = byteCharacters.charCodeAt(i);
    }
    const byteArray = new Uint8Array(byteNumbers);
    return new Blob([byteArray], { type: mimeType });
  }

  cancelWebpage() {
    this.webpageData = null;
    this.elements.webpageSection.classList.add('hidden');
    this.elements.webpageTag.value = this.defaultTag;
  }

  // ==================== File Upload Handling ====================

  handleFileSelected(event) {
    const file = event.target.files[0];
    if (!file) return;
    
    this.selectedFile = file;
    
    // Show file upload section
    this.hideAllDetailSections();
    this.elements.fileUploadSection.classList.remove('hidden');
    
    // Update file info
    this.elements.selectedFileName.textContent = file.name;
    this.elements.selectedFileSize.textContent = this.formatFileSize(file.size);
    
    // Pre-fill default tag
    if (this.defaultTag) {
      this.elements.fileTag.value = this.defaultTag;
    }
  }

  async uploadFile() {
    if (!this.selectedFile) {
      this.showToast('No file selected', 'error');
      return;
    }

    const tag = this.elements.fileTag.value.trim();
    if (!tag) {
      this.showToast('Tag is required', 'warning');
      this.elements.fileTag.focus();
      return;
    }

    try {
      this.setButtonLoading(this.elements.confirmFileUploadBtn, true);
      
      // Create form data
      const formData = new FormData();
      formData.append('file', this.selectedFile);
      formData.append('tag', tag);
      
      // Upload to API
      const result = await this.apiRequest('/upload/file', {
        method: 'POST',
        body: formData
      });
      
      this.showToast('File uploaded successfully! ☁️', 'success');
      this.triggerCacheSync();
      this.cancelFileUpload();
      
      // Close popup after short delay
      setTimeout(() => window.close(), 1500);
      
    } catch (error) {
      console.error('Failed to upload file:', error);
      this.showToast(error.message || 'Failed to upload file', 'error');
    } finally {
      this.setButtonLoading(this.elements.confirmFileUploadBtn, false);
    }
  }

  cancelFileUpload() {
    this.selectedFile = null;
    this.elements.fileInput.value = '';
    this.elements.fileUploadSection.classList.add('hidden');
    this.elements.fileTag.value = this.defaultTag;
  }

  // ==================== Notes Handling ====================

  showNotesEditor() {
    this.hideAllDetailSections();
    this.elements.notesEditorSection.classList.remove('hidden');
    this.elements.notesTextarea.focus();
    
    // Pre-fill default tag
    if (this.defaultTag) {
      this.elements.noteTag.value = this.defaultTag;
    }
  }

  async saveNote() {
    const content = this.elements.notesTextarea.value.trim();
    
    if (!content) {
      this.showToast('Please enter some text', 'warning');
      return;
    }

    const tag = this.elements.noteTag.value.trim();
    if (!tag) {
      this.showToast('Tag is required', 'warning');
      this.elements.noteTag.focus();
      return;
    }

    try {
      this.setButtonLoading(this.elements.saveNoteBtn, true);
      
      // Send to API
      const result = await this.apiRequest('/upload/quick-note', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          content: content,
          tag: tag
        })
      });
      
      this.showToast('Note saved successfully! ☁️', 'success');
      this.triggerCacheSync();
      this.cancelNotes();
      
      // Close popup after short delay
      setTimeout(() => window.close(), 1500);
      
    } catch (error) {
      console.error('Failed to save note:', error);
      this.showToast(error.message || 'Failed to save note', 'error');
    } finally {
      this.setButtonLoading(this.elements.saveNoteBtn, false);
    }
  }

  cancelNotes() {
    this.elements.notesEditorSection.classList.add('hidden');
    this.elements.notesTextarea.value = '';
    this.elements.noteTag.value = this.defaultTag;
  }

  // ==================== API Communication ====================

  async apiRequest(endpoint, options = {}) {
    if (!this.apiKey) {
      throw new Error('Not authenticated. Please login.');
    }

    // Use uploadBaseUrl for upload endpoints, searchBaseUrl for others
    const baseUrl = endpoint.startsWith('/upload') ? this.uploadBaseUrl : this.searchBaseUrl;
    const url = `${baseUrl}${endpoint}`;
    
    const headers = {
      'X-API-Key': this.apiKey,
      ...options.headers
    };
    
    // Don't set Content-Type for FormData (browser sets it with boundary)
    if (options.body instanceof FormData) {
      delete headers['Content-Type'];
    }

    try {
      const response = await fetch(url, {
        ...options,
        headers
      });

      if (response.status === 401 || response.status === 403) {
        // Token expired or invalid - logout user
        await this.handleLogout();
        throw new Error('Session expired. Please login again.');
      }

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        throw new Error(errorData.message || `Request failed (${response.status})`);
      }

      return await response.json();
      
    } catch (error) {
      if (error.name === 'TypeError' && error.message.includes('fetch')) {
        throw new Error('Network error. Please check your connection.');
      }
      throw error;
    }
  }

  // ==================== Utility Methods ====================

  hideAllDetailSections() {
    this.elements.fileUploadSection?.classList.add('hidden');
    this.elements.notesEditorSection?.classList.add('hidden');
    this.elements.previewSection?.classList.add('hidden');
    this.elements.webpageSection?.classList.add('hidden');
  }

  setButtonLoading(button, loading) {
    if (!button) return;
    
    if (loading) {
      button.disabled = true;
      button.classList.add('loading');
      const textEl = button.querySelector('span:last-child');
      if (textEl) {
        textEl.dataset.originalText = textEl.textContent;
        textEl.textContent = 'Saving...';
      }
    } else {
      button.disabled = false;
      button.classList.remove('loading');
      const textEl = button.querySelector('span:last-child');
      if (textEl && textEl.dataset.originalText) {
        textEl.textContent = textEl.dataset.originalText;
      }
    }
  }

  showToast(message, type = 'info') {
    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    toast.textContent = message;
    
    this.elements.toastContainer.appendChild(toast);
    
    // Trigger animation
    requestAnimationFrame(() => {
      toast.classList.add('show');
    });
    
    // Remove after delay
    const delay = type === 'error' ? 5000 : 3000;
    setTimeout(() => {
      toast.classList.remove('show');
      setTimeout(() => toast.remove(), 300);
    }, delay);
  }

  formatFileSize(bytes) {
    if (bytes === 0) return '0 Bytes';
    const k = 1024;
    const sizes = ['Bytes', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  triggerCacheSync() {
    // Trigger background service to sync keyword cache after successful upload
    chrome.runtime.sendMessage({ action: 'syncCache' }).catch(() => {
      // Ignore errors - cache sync is optional
    });
  }

  isRestrictedUrl(url) {
    const restrictedPatterns = [
      /^chrome:\/\//,
      /^chrome-extension:\/\//,
      /^edge:\/\//,
      /^about:/,
      /^moz-extension:/
    ];
    return restrictedPatterns.some(pattern => pattern.test(url));
  }

  openSettings() {
    chrome.runtime.openOptionsPage();
  }

  openHelp() {
    chrome.tabs.create({
      url: 'https://github.com/your-username/secondbrain-extension#readme'
    });
  }
}

// Initialize popup when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  console.log('[SecondBrain] DOMContentLoaded event fired');
  new PopupController();
});
