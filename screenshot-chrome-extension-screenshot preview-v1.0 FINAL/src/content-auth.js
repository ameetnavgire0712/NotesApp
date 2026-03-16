/**
 * Content script to auto-capture API key from login success page
 * Runs on: https://notesapp-vector-search.monocle0712.workers.dev/api/v1/auth/chrome-extension/exchange*
 */

(function() {
  'use strict';

  // Look for API key element
  const apiKeyElement = document.getElementById('apiKey');
  const emailElement = document.querySelector('.email strong');

  // Check if we have a valid API key on the page
  if (apiKeyElement && apiKeyElement.textContent.trim().startsWith('na_')) {
    const apiKey = apiKeyElement.textContent.trim();
    const email = emailElement ? emailElement.textContent.trim() : '';

    console.log('infoSnap.ai: Found API key, sending to extension...');

    // Update the page to show connecting status
    showConnectingMessage();

    // Send credentials to background script (it will close the tab)
    chrome.runtime.sendMessage({
      type: 'AUTH_SUCCESS',
      apiKey: apiKey,
      email: email
    });
  }

  /**
   * Show connecting message overlay
   */
  function showConnectingMessage() {
    const overlay = document.createElement('div');
    overlay.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background: rgba(255, 255, 255, 0.98);
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      z-index: 999999;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    `;

    overlay.innerHTML = `
      <div style="text-align: center; padding: 40px;">
        <div style="font-size: 64px; margin-bottom: 24px;">🔄</div>
        <h1 style="color: hsl(155, 70%, 45%); font-size: 28px; margin: 0 0 16px 0;">
          Connecting to infoSnap.ai...
        </h1>
        <p style="color: #666; font-size: 16px; margin: 0;">
          Saving your credentials...
        </p>
      </div>
    `;

    document.body.appendChild(overlay);
  }
})();
