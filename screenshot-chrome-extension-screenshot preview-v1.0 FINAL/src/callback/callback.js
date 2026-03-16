/**
 * OAuth Callback Handler for infoSnap.ai
 * Handles the redirect from the OAuth server and stores credentials
 */

class CallbackHandler {
  constructor() {
    this.init();
  }

  async init() {
    try {
      const params = this.parseUrlParams();
      
      if (params.error) {
        this.showError(params.error);
        return;
      }

      if (!params.api_key || !params.email) {
        this.showError('Missing authentication data. Please try again.');
        return;
      }

      // Store credentials in chrome.storage.sync
      await this.storeCredentials(params.api_key, params.email);
      
      // Show success state
      this.showSuccess(params.email);
      
      // Close tab after countdown
      this.startCloseCountdown();

    } catch (error) {
      console.error('Callback handling error:', error);
      this.showError(error.message || 'An unexpected error occurred.');
    }
  }

  parseUrlParams() {
    const urlParams = new URLSearchParams(window.location.search);
    return {
      api_key: urlParams.get('api_key'),
      email: urlParams.get('email'),
      error: urlParams.get('error')
    };
  }

  async storeCredentials(apiKey, email) {
    return new Promise((resolve, reject) => {
      chrome.storage.sync.set({
        apiKey: apiKey,
        userEmail: email,
        isLoggedIn: true,
        loginTimestamp: Date.now()
      }, () => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
        } else {
          console.log('Credentials stored successfully');
          resolve();
        }
      });
    });
  }

  showSuccess(email) {
    document.getElementById('loadingState').style.display = 'none';
    document.getElementById('successState').style.display = 'block';
    document.getElementById('userEmail').textContent = email;
  }

  showError(message) {
    document.getElementById('loadingState').style.display = 'none';
    document.getElementById('errorState').style.display = 'block';
    document.getElementById('errorMessage').textContent = message;
  }

  startCloseCountdown() {
    let seconds = 3;
    const countdownEl = document.getElementById('countdown');
    
    const interval = setInterval(() => {
      seconds--;
      countdownEl.textContent = seconds;
      
      if (seconds <= 0) {
        clearInterval(interval);
        window.close();
        
        // If window.close() doesn't work (popup blocker), show message
        setTimeout(() => {
          countdownEl.parentElement.innerHTML = 
            'You can now close this tab and return to infoSnap.ai.';
        }, 500);
      }
    }, 1000);
  }
}

// Retry login function (global for onclick)
function retryLogin() {
  const extensionId = chrome.runtime.id;
  // Use Worker directly for auth
  const loginUrl = `https://notesapp-vector-search.monocle0712.workers.dev/api/v1/auth/chrome-extension/login?extension_id=${extensionId}`;
  window.location.href = loginUrl;
}

// Initialize callback handler
document.addEventListener('DOMContentLoaded', () => {
  new CallbackHandler();
});
