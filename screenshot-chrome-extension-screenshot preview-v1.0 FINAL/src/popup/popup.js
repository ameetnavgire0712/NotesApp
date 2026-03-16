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
    // All API calls go to Cloudflare Worker (no Fly.io)
    this.workerBaseUrl = 'https://notesapp-vector-search.monocle0712.workers.dev/api/v1';
    this.searchBaseUrl = this.workerBaseUrl;  // Auth & Search
    this.uploadBaseUrl = this.workerBaseUrl;  // Uploads
    this.selectedFile = null;
    this.screenshotData = null;
    this.uploadInProgress = false;  // Lock to prevent concurrent uploads
    this.activeTraceId = null;      // Track active upload for polling
    this.activeItemName = null;     // Track item name for display
    
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
    await this.restoreUploadState();  // Restore any active upload state
    console.log('[SecondBrain] init() complete');
  }

  bindElements() {
    this.elements = {
      // States
      loadingState: document.getElementById('loadingState'),
      loggedOutState: document.getElementById('loggedOutState'),
      loggedInState: document.getElementById('loggedInState'),
      
      // Login elements
      googleLoginBtn: document.getElementById('googleLoginBtn'),
      showApiKeyBtn: document.getElementById('showApiKeyBtn'),
      apiKeySection: document.getElementById('apiKeySection'),
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
      toastContainer: document.getElementById('toastContainer'),
      
      // Upload Progress Section
      uploadProgressSection: document.getElementById('uploadProgressSection'),
      uploadItemName: document.getElementById('uploadItemName'),
      uploadStatusText: document.getElementById('uploadStatusText'),
      uploadStepInfo: document.getElementById('uploadStepInfo'),
      cancelUploadBtn: document.getElementById('cancelUploadBtn')
    };
    
    // Debug: verify upload progress elements were found
    console.log('[SecondBrain] Upload progress elements:', {
      uploadProgressSection: !!this.elements.uploadProgressSection,
      uploadItemName: !!this.elements.uploadItemName,
      uploadStatusText: !!this.elements.uploadStatusText,
      uploadStepInfo: !!this.elements.uploadStepInfo,
      cancelUploadBtn: !!this.elements.cancelUploadBtn
    });
  }

  attachEventListeners() {
    // Google Login
    this.elements.googleLoginBtn?.addEventListener('click', () => this.handleGoogleLogin());
    
    // Show/hide API key section
    this.elements.showApiKeyBtn?.addEventListener('click', () => {
      this.elements.apiKeySection?.classList.toggle('hidden');
      this.elements.showApiKeyBtn.textContent = 
        this.elements.apiKeySection?.classList.contains('hidden') 
          ? 'Sign in with API Key instead' 
          : 'Hide API Key option';
    });
    
    // API Key Login
    if (this.elements.loginBtn) {
      console.log('[SecondBrain] Attaching click listener to loginBtn');
      this.elements.loginBtn.addEventListener('click', (e) => {
        console.log('[SecondBrain] Login button CLICKED!', e);
        this.handleApiKeyLogin();
      });
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
    
    // Cancel upload handling
    this.elements.cancelUploadBtn?.addEventListener('click', () => this.handleCancelUpload());

    // Listen for storage changes
    chrome.storage.onChanged.addListener((changes) => {
      if (changes.preview_screenshot) {
        this.checkForPendingScreenshot();
      }
      if (changes.isLoggedIn || changes.accessToken || changes.apiKey) {
        this.checkLoginStatus();
      }
    });
  }

  async loadSettings() {
    try {
      const result = await chrome.storage.sync.get([
        'apiKey', 'accessToken', 'refreshToken', 'userEmail', 'isLoggedIn', 'defaultTag'
      ]);
      
      this.apiKey = result.apiKey || '';
      this.accessToken = result.accessToken || '';
      this.refreshToken = result.refreshToken || '';
      this.userEmail = result.userEmail || '';
      this.isLoggedIn = result.isLoggedIn || false;
      this.defaultTag = result.defaultTag || '';
      // Always use Cloudflare Worker
      this.workerBaseUrl = 'https://notesapp-vector-search.monocle0712.workers.dev/api/v1';
      this.searchBaseUrl = this.workerBaseUrl;
      this.uploadBaseUrl = this.workerBaseUrl;
      
    } catch (error) {
      console.error('Failed to load settings:', error);
    }
  }

  async checkLoginStatus() {
    try {
      const result = await chrome.storage.sync.get([
        'isLoggedIn', 'userEmail', 'apiKey', 'accessToken', 'refreshToken', 
        'pendingApiKey', 'pendingValidation'
      ]);
      
      this.isLoggedIn = result.isLoggedIn || false;
      this.userEmail = result.userEmail || '';
      this.apiKey = result.apiKey || '';
      this.accessToken = result.accessToken || '';
      this.refreshToken = result.refreshToken || '';
      
      // Hide loading state
      this.elements.loadingState.classList.add('hidden');
      
      // Check for JWT auth (preferred) or API key auth (legacy)
      const hasValidAuth = this.isLoggedIn && (this.accessToken || this.refreshToken || this.apiKey);
      
      if (hasValidAuth) {
        this.showLoggedInState();
      } else {
        this.showLoggedOutState();
        
        // If there was a pending validation, restore the API key in the input
        // and automatically retry validation
        if (result.pendingApiKey && result.pendingValidation) {
          console.log('[SecondBrain] Found pending validation, restoring...');
          if (this.elements.apiKeyInput) {
            this.elements.apiKeyInput.value = result.pendingApiKey;
          }
          // Auto-retry the validation
          this.handleLogin();
        }
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
    // Hide API key section by default
    if (this.elements.apiKeySection) {
      this.elements.apiKeySection.classList.add('hidden');
    }
  }

  // ==================== Google OAuth Login ====================
  
  async handleGoogleLogin() {
    console.log('[SecondBrain] handleGoogleLogin() called');
    
    const googleBtn = this.elements.googleLoginBtn;
    
    try {
      // Show loading state
      if (googleBtn) {
        googleBtn.disabled = true;
        googleBtn.innerHTML = '<div class="spinner"></div><span>Signing in...</span>';
      }
      this.hideLoginError();
      
      // Use the SupabaseAuth module
      const result = await supabaseAuth.signInWithGoogle();
      
      console.log('[SecondBrain] Google sign-in successful:', result.email);
      
      this.userEmail = result.email;
      this.isLoggedIn = true;
      
      this.showLoggedInState();
      this.showToast('Signed in successfully! 🎉', 'success');
      
    } catch (error) {
      console.error('[SecondBrain] Google sign-in failed:', error);
      this.showLoginError(error.message || 'Google sign-in failed. Please try again.');
    } finally {
      // Restore button state
      if (googleBtn) {
        googleBtn.disabled = false;
        googleBtn.innerHTML = `
          <svg class="google-icon" viewBox="0 0 24 24" width="20" height="20">
            <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/>
            <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"/>
            <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"/>
            <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"/>
          </svg>
          <span>Sign in with Google</span>
        `;
      }
    }
  }

  // ==================== API Key Login (Legacy) ====================
  
  async handleApiKeyLogin() {
    console.log('[SecondBrain] handleApiKeyLogin() called');
    
    const apiKeyInput = this.elements.apiKeyInput;
    const loginError = this.elements.loginError;
    const loginBtn = this.elements.loginBtn;
    
    // Get the entered API key and sanitize it (remove smart quotes, non-ASCII chars)
    let enteredApiKey = apiKeyInput?.value?.trim();
    if (enteredApiKey) {
      // Replace smart quotes and other problematic characters
      enteredApiKey = enteredApiKey
        .replace(/[\u2018\u2019]/g, "'")  // Smart single quotes → regular
        .replace(/[\u201C\u201D]/g, '"')  // Smart double quotes → regular
        .replace(/[\u2013\u2014]/g, '-')  // En/em dashes → regular dash
        .replace(/[^\x00-\x7F]/g, '');    // Remove any remaining non-ASCII
    }
    
    if (!enteredApiKey) {
      this.showLoginError('Please enter your API key');
      return;
    }
    
    // Validate API key format
    if (!enteredApiKey.startsWith('na_')) {
      this.showLoginError('Invalid API key format. Keys should start with "na_"');
      return;
    }
    
    try {
      // Disable button while validating
      if (loginBtn) {
        loginBtn.disabled = true;
        loginBtn.querySelector('span:last-child').textContent = 'Validating...';
      }
      
      // Save API key temporarily so popup state persists if user clicks away
      await chrome.storage.sync.set({
        pendingApiKey: enteredApiKey,
        pendingValidation: true
      });
      
      // Validate API key by calling /auth/me endpoint on Cloudflare Worker
      console.log('[SecondBrain] Validating API key against:', `${this.searchBaseUrl}/auth/me`);
      const response = await fetch(`${this.searchBaseUrl}/auth/me`, {
        method: 'GET',
        headers: {
          'X-API-Key': enteredApiKey
        }
      });
      
      console.log('[SecondBrain] Response status:', response.status);
      
      if (!response.ok) {
        let errorMessage = 'Invalid API key. Please check and try again.';
        try {
          const errorData = await response.json();
          console.log('[SecondBrain] Error response:', errorData);
          // Extract meaningful error from response
          if (errorData.error) {
            errorMessage = errorData.error;
          }
          if (errorData.debug?.auth_error) {
            errorMessage = errorData.debug.auth_error;
          }
        } catch {
          // If not JSON, just use status-based message
          if (response.status === 401 || response.status === 403) {
            errorMessage = 'Invalid API key. Please check and try again.';
          } else if (response.status >= 500) {
            errorMessage = 'Server error. Please try again in a moment.';
          } else {
            errorMessage = `Validation failed (${response.status}). Please try again.`;
          }
        }
        // Clear pending state on error
        await chrome.storage.sync.remove(['pendingApiKey', 'pendingValidation']);
        throw new Error(errorMessage);
      }
      
      const data = await response.json();
      console.log('[SecondBrain] API key validated, full response:', JSON.stringify(data, null, 2));
      
      // Try different possible email fields from the response (handle null explicitly)
      const userEmail = (data.email && data.email !== null) ? data.email : 
                        (data.user?.email && data.user.email !== null) ? data.user.email : 
                        (data.user_email && data.user_email !== null) ? data.user_email : 
                        (data.username && data.username !== null) ? data.username : 
                        (data.name && data.name !== null) ? data.name : 'User';
      console.log('[SecondBrain] Extracted email:', userEmail);
      
      // Store credentials (replace pending with confirmed)
      await chrome.storage.sync.set({
        apiKey: enteredApiKey,
        userEmail: userEmail,
        isLoggedIn: true,
        loginTimestamp: Date.now()
      });
      // Clear pending state
      await chrome.storage.sync.remove(['pendingApiKey', 'pendingValidation']);
      
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

  hideLoginError() {
    const loginError = this.elements.loginError;
    if (loginError) {
      loginError.textContent = '';
      loginError.classList.add('hidden');
    }
  }

  async handleLogout(silent = false) {
    try {
      // Use SupabaseAuth for logout if available (handles both JWT and API key)
      if (typeof supabaseAuth !== 'undefined') {
        await supabaseAuth.signOut();
      } else {
        // Fallback: clear storage directly
        await chrome.storage.sync.remove([
          'apiKey', 'userEmail', 'isLoggedIn', 'loginTimestamp',
          'accessToken', 'refreshToken', 'expiresAt', 'userId'
        ]);
      }
      
      this.isLoggedIn = false;
      this.apiKey = '';
      this.accessToken = '';
      this.refreshToken = '';
      this.userEmail = '';
      
      this.showLoggedOutState();
      if (!silent) {
        this.showToast('Logged out successfully', 'success');
      }
      
    } catch (error) {
      console.error('Logout failed:', error);
      if (!silent) {
        this.showToast('Failed to logout', 'error');
      }
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

    if (this.uploadInProgress) {
      this.showToast('⏳ Another upload is in progress. Please wait.', 'warning');
      return;
    }

    const tag = this.elements.screenshotTag.value.trim();
    if (!tag) {
      this.showToast('Tag is required', 'warning');
      this.elements.screenshotTag.focus();
      return;
    }

    try {
      this.setUploadLock(true);
      this.setButtonLoading(this.elements.saveScreenshotBtn, true);
      
      // Convert base64 to blob
      const response = await fetch(this.screenshotData.dataUrl);
      const blob = await response.blob();
      
      // Create form data
      const formData = new FormData();
      formData.append('file', blob, `screenshot-${Date.now()}.png`);
      formData.append('tag', tag);
      
      // Submit - Worker returns 202
      const result = await this.apiRequest('/upload/screenshot', {
        method: 'POST',
        body: formData
      });
      
      if (result.trace_id) {
        this.activeTraceId = result.trace_id;
        this.showToast('📸 Screenshot accepted! Processing in background...', 'info');
        this.cancelScreenshot();
        this.pollUploadStatus(result.trace_id, 'screenshot');
      } else {
        this.showToast('Screenshot uploaded successfully! 🎉', 'success');
        this.setUploadLock(false);
        this.triggerCacheSync();
        this.cancelScreenshot();
      }
      
    } catch (error) {
      console.error('Failed to save screenshot:', error);
      // Don't show toast for storage quota errors or session revoked - already handled
      if (!error.isStorageQuota && !error.isSessionRevoked) {
        this.showToast(error.message || 'Failed to save screenshot', 'error');
      }
      this.setUploadLock(false);
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

      // Check for blocked sites (multimedia-heavy, not suitable for text extraction)
      const blockedSiteError = this.getBlockedSiteError(tab.url);
      if (blockedSiteError) {
        throw new Error(blockedSiteError);
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
      if (!error.isSessionRevoked) {
        this.showToast(error.message || 'Failed to prepare webpage', 'error');
      }
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

    if (this.uploadInProgress) {
      this.showToast('⏳ Another upload is in progress. Please wait.', 'warning');
      return;
    }

    try {
      this.setUploadLock(true);
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

      if (result.trace_id) {
        this.activeTraceId = result.trace_id;
        this.showToast('📄 Webpage PDF accepted! Processing in background...', 'info');
        this.cancelWebpage();
        this.pollUploadStatus(result.trace_id, filename);
      } else {
        this.showToast('✅ Webpage saved as PDF!', 'success');
        this.setUploadLock(false);
        this.triggerCacheSync();
        this.cancelWebpage();
      }

    } catch (error) {
      console.error('Failed to save webpage:', error);
      // Don't show toast for storage quota errors or session revoked - already handled
      if (!error.isStorageQuota && !error.isSessionRevoked) {
        this.showToast(error.message || 'Failed to save webpage', 'error');
      }
      this.setUploadLock(false);
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

    if (this.uploadInProgress) {
      this.showToast('⏳ Another upload is in progress. Please wait.', 'warning');
      return;
    }

    const tag = this.elements.fileTag.value.trim();
    if (!tag) {
      this.showToast('Tag is required', 'warning');
      this.elements.fileTag.focus();
      return;
    }

    try {
      this.setUploadLock(true);
      this.setButtonLoading(this.elements.confirmFileUploadBtn, true);
      
      // Create form data
      const formData = new FormData();
      formData.append('file', this.selectedFile);
      formData.append('tag', tag);
      
      // Submit upload - Worker returns 202 immediately
      const result = await this.apiRequest('/upload/file', {
        method: 'POST',
        body: formData
      });
      
      if (result.trace_id) {
        this.activeTraceId = result.trace_id;
        this.showToast('📤 Upload accepted! Processing in background...', 'info');
        this.cancelFileUpload();
        // Poll for completion in background
        this.pollUploadStatus(result.trace_id, result.filename);
      } else {
        this.showToast('File uploaded successfully! ☁️', 'success');
        this.setUploadLock(false);
        this.triggerCacheSync();
        this.cancelFileUpload();
      }
      
    } catch (error) {
      console.error('Failed to upload file:', error);
      // Don't show toast for storage quota errors or session revoked - already handled
      if (!error.isStorageQuota && !error.isSessionRevoked) {
        this.showToast(error.message || 'Failed to upload file', 'error');
      }
      this.setUploadLock(false);
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

    if (this.uploadInProgress) {
      this.showToast('⏳ Another upload is in progress. Please wait.', 'warning');
      return;
    }

    const tag = this.elements.noteTag.value.trim();
    if (!tag) {
      this.showToast('Tag is required', 'warning');
      this.elements.noteTag.focus();
      return;
    }

    try {
      this.setUploadLock(true);
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
      
      if (result.trace_id) {
        this.activeTraceId = result.trace_id;
        this.showToast('📝 Note accepted! Processing in background...', 'info');
        this.cancelNotes();
        this.pollUploadStatus(result.trace_id, 'quick note');
      } else {
        this.showToast('Note saved successfully! ☁️', 'success');
        this.setUploadLock(false);
        this.triggerCacheSync();
        this.cancelNotes();
      }
      
    } catch (error) {
      console.error('Failed to save note:', error);
      // Don't show toast for storage quota errors or session revoked - already handled
      if (!error.isStorageQuota && !error.isSessionRevoked) {
        this.showToast(error.message || 'Failed to save note', 'error');
      }
      this.setUploadLock(false);
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
    // Get auth headers (JWT or API key)
    let authHeaders = {};
    
    // Try JWT auth first (preferred)
    if (typeof supabaseAuth !== 'undefined') {
      authHeaders = await supabaseAuth.getAuthHeaders();
    }
    
    // Fallback to API key if no JWT
    if (!authHeaders.Authorization && !authHeaders['X-API-Key'] && this.apiKey) {
      authHeaders = { 'X-API-Key': this.apiKey };
    }
    
    if (!authHeaders.Authorization && !authHeaders['X-API-Key']) {
      throw new Error('Not authenticated. Please login.');
    }

    // Use uploadBaseUrl for upload endpoints, searchBaseUrl for others
    const baseUrl = endpoint.startsWith('/upload') ? this.uploadBaseUrl : this.searchBaseUrl;
    const url = `${baseUrl}${endpoint}`;
    
    const headers = {
      ...authHeaders,
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
        // Check if session was revoked from another device
        let errorData = {};
        try {
          errorData = await response.json();
          console.log('[SecondBrain] Auth error response:', errorData);
        } catch (e) {
          console.log('[SecondBrain] Could not parse auth error response');
        }
        
        if (errorData.error === 'SESSION_REVOKED' || (typeof errorData.error === 'string' && errorData.error.includes('SESSION_REVOKED'))) {
          // Clear all auth and show message (silent logout - we show our own message)
          console.log('[SecondBrain] Session was revoked - logging out silently');
          await this.handleLogout(true);
          this.showToast('Session signed out from another device', 'warning', 4000);
          const error = new Error('SESSION_REVOKED');
          error.isSessionRevoked = true;  // Mark so we don't show duplicate toast
          throw error;
        }
        
        // Token expired or invalid - logout user
        await this.handleLogout(true);  // Silent logout here too
        this.showToast('Session expired. Please login again.', 'warning', 4000);
        const error = new Error('Session expired');
        error.isSessionRevoked = true;  // Treat expired sessions same as revoked for UI
        throw error;
      }

      // Handle storage quota errors (413)
      if (response.status === 413) {
        const errorData = await response.json().catch(() => ({}));
        if (errorData.code === 'STORAGE_LIMIT_REACHED' || errorData.code === 'INSUFFICIENT_STORAGE') {
          // Show storage quota popup with friendly message
          this.showStorageQuotaError(errorData);
          const error = new Error('STORAGE_QUOTA_EXCEEDED');
          error.isStorageQuota = true;
          error.storageData = errorData;
          throw error;
        }
        throw new Error(errorData.error || 'File too large');
      }

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        throw new Error(errorData.message || errorData.error || `Request failed (${response.status})`);
      }

      return await response.json();
      
    } catch (error) {
      if (error.name === 'TypeError' && error.message.includes('fetch')) {
        throw new Error('Network error. Please check your connection.');
      }
      throw error;
    }
  }

  /**
   * Show a user-friendly popup for storage quota exceeded
   */
  showStorageQuotaError(errorData) {
    const usedMb = errorData.storage_used_mb || '?';
    const limitMb = errorData.storage_limit_mb || '100';
    const remainingMb = errorData.storage_remaining_mb;
    
    let message = '';
    if (errorData.code === 'STORAGE_LIMIT_REACHED') {
      message = `📦 Storage Full!\n\nYou've used ${usedMb}MB of your ${limitMb}MB storage limit.\n\nTo free up space, please visit your dashboard and delete some files you no longer need.`;
    } else if (errorData.code === 'INSUFFICIENT_STORAGE') {
      message = `📦 Not Enough Space!\n\nYou only have ${remainingMb}MB remaining, but this file requires more space.\n\nTo free up space, please visit your dashboard and delete some files you no longer need.`;
    }
    
    // Show the popup modal
    this.showStorageQuotaModal(message, usedMb, limitMb);
  }

  /**
   * Display a modal popup for storage quota with option to go to dashboard
   */
  showStorageQuotaModal(message, usedMb, limitMb) {
    // Remove any existing modal
    const existingModal = document.getElementById('storageQuotaModal');
    if (existingModal) existingModal.remove();

    // Create modal HTML
    const modal = document.createElement('div');
    modal.id = 'storageQuotaModal';
    modal.className = 'storage-quota-modal';
    modal.innerHTML = `
      <div class="storage-quota-content">
        <div class="storage-quota-icon">📦</div>
        <h3>Storage Limit Reached</h3>
        <p>You've utilized your limit of <strong>${limitMb}MB</strong> storage.</p>
        <div class="storage-quota-bar">
          <div class="storage-quota-bar-fill" style="width: ${Math.min(100, (parseFloat(usedMb) / parseFloat(limitMb)) * 100)}%"></div>
        </div>
        <p class="storage-quota-usage">${usedMb}MB / ${limitMb}MB used</p>
        <p class="storage-quota-hint">Please login to the dashboard and delete some files you no longer need to make space for new uploads.</p>
        <div class="storage-quota-buttons">
          <button class="btn-secondary" id="storageQuotaDismiss">Dismiss</button>
          <button class="btn-primary" id="storageQuotaGoToDashboard">Go to Dashboard</button>
        </div>
      </div>
    `;

    document.body.appendChild(modal);

    // Event listeners
    document.getElementById('storageQuotaDismiss').addEventListener('click', () => {
      modal.remove();
    });

    document.getElementById('storageQuotaGoToDashboard').addEventListener('click', () => {
      // Open dashboard in new tab
      chrome.tabs.create({ url: 'https://notesapp.pages.dev/dashboard.html' });
      modal.remove();
    });

    // Close on backdrop click
    modal.addEventListener('click', (e) => {
      if (e.target === modal) {
        modal.remove();
      }
    });
  }

  // ==================== Utility Methods ====================

  hideAllDetailSections() {
    this.elements.fileUploadSection?.classList.add('hidden');
    this.elements.notesEditorSection?.classList.add('hidden');
    this.elements.previewSection?.classList.add('hidden');
    this.elements.webpageSection?.classList.add('hidden');
    // Don't hide uploadProgressSection here - it's managed by pollUploadStatus
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

  // ==================== Upload Status Polling ====================

  async pollUploadStatus(traceId, itemName) {
    const maxAttempts = 144;  // Poll for up to 12 minutes (144 * 5s) to cover 10-min TensorLake timeout
    const pollInterval = 5000; // 5 seconds

    // Store active upload state for session persistence
    this.activeTraceId = traceId;
    this.activeItemName = itemName;
    await this.saveUploadState(traceId, itemName);
    
    // Show upload progress UI
    this.showUploadProgress(itemName, 'Initializing...', '');

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      // Check if cancelled locally (user clicked cancel while polling)
      if (!this.activeTraceId) {
        console.log('[Upload Poll] Cancelled locally');
        return;
      }
      
      // First 3 polls at 2s interval for fast failure detection, then 5s
      const delay = attempt < 3 ? 2000 : pollInterval;
      await new Promise(r => setTimeout(r, delay));

      try {
        const status = await this.apiRequest(`/upload/status/${traceId}`, {
          method: 'GET'
        });

        // Update progress UI with current step info
        const stepInfo = status.current_step ? `Step: ${status.current_step}` : '';
        this.updateUploadProgress(status.status || 'Processing...', stepInfo);

        if (status.status === 'completed') {
          this.showToast(`Screenshot uploaded successfully! 🎉`, 'success');
          this.completeUpload();
          this.triggerCacheSync();
          // Show Chrome notification
          this.showChromeNotification('Upload Complete', `"${itemName}" has been processed and is now searchable.`);
          return;
        }

        if (status.status === 'failed') {
          const errorMsg = status.error_message || 'Processing failed';
          this.showToast(`❌ Upload failed: ${errorMsg}`, 'error');
          this.completeUpload();
          this.showChromeNotification('Upload Failed', `"${itemName}" failed: ${errorMsg}`);
          return;
        }
        
        if (status.status === 'cancelled') {
          this.showToast(`🚫 Upload cancelled`, 'info');
          this.completeUpload();
          return;
        }

        // Still processing - continue polling
        console.log(`[Upload Poll] ${traceId} attempt ${attempt + 1}: status=${status.status}, step=${status.current_step || 'n/a'}`);
      } catch (err) {
        console.error(`[Upload Poll] Error polling status:`, err);
        // Don't break on network errors - keep trying
      }
    }

    // Timed out
    this.showToast('⚠️ Upload is still processing. Check activity logs for status.', 'warning');
    this.completeUpload();
  }
  
  showUploadProgress(itemName, statusText, stepInfo) {
    console.log('[SecondBrain] showUploadProgress called:', { itemName, statusText, stepInfo });
    console.log('[SecondBrain] uploadProgressSection element:', this.elements.uploadProgressSection);
    
    // Show the upload progress section
    if (this.elements.uploadProgressSection) {
      this.elements.uploadProgressSection.classList.remove('hidden');
      console.log('[SecondBrain] Upload progress section shown');
    } else {
      console.error('[SecondBrain] uploadProgressSection element not found!');
    }
    
    // Update the content
    if (this.elements.uploadItemName) {
      this.elements.uploadItemName.textContent = itemName;
    }
    if (this.elements.uploadStatusText) {
      this.elements.uploadStatusText.textContent = statusText;
    }
    if (this.elements.uploadStepInfo) {
      this.elements.uploadStepInfo.textContent = stepInfo;
    }
  }
  
  updateUploadProgress(statusText, stepInfo) {
    if (this.elements.uploadStatusText) {
      this.elements.uploadStatusText.textContent = statusText;
    }
    if (this.elements.uploadStepInfo) {
      this.elements.uploadStepInfo.textContent = stepInfo;
    }
  }
  
  hideUploadProgress() {
    this.elements.uploadProgressSection?.classList.add('hidden');
  }
  
  async handleCancelUpload() {
    if (!this.activeTraceId) {
      this.showToast('No active upload to cancel', 'warning');
      return;
    }
    
    const traceId = this.activeTraceId;
    const itemName = this.activeItemName || 'upload';
    
    // Disable cancel button while processing
    if (this.elements.cancelUploadBtn) {
      this.elements.cancelUploadBtn.disabled = true;
      this.elements.cancelUploadBtn.innerHTML = '<span class="btn-icon">⏳</span><span>Cancelling...</span>';
    }
    
    try {
      await this.apiRequest(`/upload/cancel/${traceId}`, {
        method: 'POST'
      });
      
      this.showToast(`🚫 "${itemName}" cancelled`, 'info');
      this.completeUpload();
      
    } catch (err) {
      console.error('[Cancel Upload] Error:', err);
      this.showToast(`Failed to cancel: ${err.message}`, 'error');
      
      // Re-enable button
      if (this.elements.cancelUploadBtn) {
        this.elements.cancelUploadBtn.disabled = false;
        this.elements.cancelUploadBtn.innerHTML = '<span class="btn-icon">✕</span><span>Cancel Upload</span>';
      }
    }
  }
  
  completeUpload() {
    this.setUploadLock(false);
    this.hideUploadProgress();
    this.activeTraceId = null;
    this.activeItemName = null;
    this.clearUploadState();
    
    // Reset cancel button state
    if (this.elements.cancelUploadBtn) {
      this.elements.cancelUploadBtn.disabled = false;
      this.elements.cancelUploadBtn.innerHTML = '<span class="btn-icon">✕</span><span>Cancel Upload</span>';
    }
  }
  
  // ==================== Upload State Persistence ====================
  
  async saveUploadState(traceId, itemName) {
    try {
      await chrome.storage.local.set({
        activeUpload: {
          traceId,
          itemName,
          startedAt: Date.now()
        }
      });
      console.log('[SecondBrain] Saved upload state:', traceId);
    } catch (err) {
      console.error('[SecondBrain] Failed to save upload state:', err);
    }
  }
  
  async clearUploadState() {
    try {
      await chrome.storage.local.remove('activeUpload');
      console.log('[SecondBrain] Cleared upload state');
    } catch (err) {
      console.error('[SecondBrain] Failed to clear upload state:', err);
    }
  }
  
  async restoreUploadState() {
    console.log('[SecondBrain] restoreUploadState called, isLoggedIn:', this.isLoggedIn, 'apiKey:', !!this.apiKey);
    try {
      // Must be logged in to restore upload state
      if (!this.isLoggedIn || !this.apiKey) {
        console.log('[SecondBrain] Not logged in, skipping upload state restore');
        return;
      }
      
      const result = await chrome.storage.local.get('activeUpload');
      const activeUpload = result.activeUpload;
      console.log('[SecondBrain] activeUpload from storage:', activeUpload);
      
      if (!activeUpload || !activeUpload.traceId) {
        console.log('[SecondBrain] No active upload to restore');
        return; // No active upload to restore
      }
      
      // Check if upload is still active (less than 15 minutes old)
      const maxAge = 15 * 60 * 1000; // 15 minutes
      if (Date.now() - activeUpload.startedAt > maxAge) {
        console.log('[SecondBrain] Upload state too old, clearing');
        await this.clearUploadState();
        return;
      }
      
      console.log('[SecondBrain] Restoring upload state:', activeUpload.traceId);
      
      // Check current status before resuming
      try {
        const status = await this.apiRequest(`/upload/status/${activeUpload.traceId}`, {
          method: 'GET'
        });
        
        if (status.status === 'completed' || status.status === 'failed' || status.status === 'cancelled') {
          console.log('[SecondBrain] Upload already finished:', status.status);
          await this.clearUploadState();
          
          // Show appropriate message
          if (status.status === 'completed') {
            this.showToast(`Screenshot uploaded successfully! 🎉`, 'success');
          } else if (status.status === 'failed') {
            this.showToast(`❌ "${activeUpload.itemName}" failed: ${status.error_message || 'Unknown error'}`, 'error');
          }
          return;
        }
        
        // Upload still in progress - resume polling
        this.setUploadLock(true);
        this.pollUploadStatus(activeUpload.traceId, activeUpload.itemName);
        
      } catch (err) {
        console.error('[SecondBrain] Failed to check upload status:', err);
        await this.clearUploadState();
      }
      
    } catch (err) {
      console.error('[SecondBrain] Failed to restore upload state:', err);
    }
  }

  setUploadLock(locked) {
    this.uploadInProgress = locked;
    // Disable/enable all upload action buttons
    const actionButtons = [
      this.elements.captureBtn,
      this.elements.uploadBtn,
      this.elements.notesBtn,
      this.elements.saveWebpageBtn,
    ];
    actionButtons.forEach(btn => {
      if (btn) {
        btn.disabled = locked;
        if (locked) {
          btn.style.opacity = '0.5';
          btn.title = 'Upload in progress...';
        } else {
          btn.style.opacity = '1';
          btn.title = '';
        }
      }
    });
  }

  showChromeNotification(title, message) {
    try {
      chrome.runtime.sendMessage({
        action: 'showNotification',
        title: title,
        message: message
      }).catch(() => {});
    } catch (e) {
      // Notifications are optional
    }
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

  // Check if URL is a blocked site (multimedia-heavy sites not suitable for text extraction)
  getBlockedSiteError(url) {
    if (!url) return null;
    
    try {
      const urlObj = new URL(url);
      const hostname = urlObj.hostname.toLowerCase();
      
      // Blocked sites: multimedia-heavy, dynamic content, not suitable for PDF/text extraction
      const blockedSites = [
        { pattern: /(\.)?youtube\.com$/, name: 'YouTube' },
        { pattern: /(\.)?youtu\.be$/, name: 'YouTube' },
        { pattern: /(\.)?instagram\.com$/, name: 'Instagram' },
        { pattern: /(\.)?linkedin\.com$/, name: 'LinkedIn' },
        { pattern: /(\.)?twitter\.com$/, name: 'Twitter/X' },
        { pattern: /(\.)?x\.com$/, name: 'Twitter/X' },
        { pattern: /(\.)?msn\.com$/, name: 'MSN' },
        { pattern: /(\.)?facebook\.com$/, name: 'Facebook' },
        { pattern: /(\.)?tiktok\.com$/, name: 'TikTok' },
      ];
      
      for (const site of blockedSites) {
        if (site.pattern.test(hostname)) {
          return `Sorry, ${site.name} pages can't be saved. These sites contain mostly videos, images, and dynamic content that doesn't convert well to text. Try saving articles, documents, or text-based pages instead! 📄`;
        }
      }
    } catch (e) {
      // Invalid URL, let it pass through
    }
    
    return null;
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
