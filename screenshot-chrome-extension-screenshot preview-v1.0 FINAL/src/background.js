/**
 * Background Service Worker for infoSnap.ai
 * Handles tab capture, file downloads, context menus, and Google search monitoring
 */

class BackgroundService {
  constructor() {
    this.CACHE_SYNC_INTERVAL = 5; // 5 minutes (for chrome.alarms)
    this.CACHE_STALE_THRESHOLD = 60 * 60 * 1000; // 1 hour
    this.RATE_LIMIT_MS = 2000; // 2 seconds between API calls
    this.NOTES_APP_URL = 'http://localhost:3000'; // Frontend app URL
    this.SUPABASE_URL = 'https://vnpqsmiuismvwsynpmfu.supabase.co';
    this.SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc5NDM3OTUsImV4cCI6MjA4MzUxOTc5NX0.D-U6mkNHxh8mGYwgQy9-qEKh3e2wLNirppV2ASivrUg';
    this.REFRESH_MARGIN_MS = 5 * 60 * 1000; // Refresh tokens 5 minutes before expiry
    this.lastSearchTime = 0;
    this.lastSearchQuery = '';
    this.currentNotificationId = null;
    this.pendingResults = new Map(); // Store results for notification clicks
    this.init();
  }

  init() {
    this.setupMessageHandlers();
    this.setupActionHandlers();
    this.setupContextMenus();
    this.setupGoogleSearchMonitor();
    // DISABLED: Cache sync - only using backend now
    // this.setupCacheSync();
  }

  // ==================== JWT Token Management ====================

  /**
   * Get auth headers for API calls (prefers JWT over API key)
   * Automatically refreshes JWT if expired
   */
  async getAuthHeaders() {
    try {
      const auth = await chrome.storage.sync.get([
        'accessToken', 'refreshToken', 'expiresAt', 'apiKey'
      ]);
      
      // Check if we have JWT tokens
      if (auth.refreshToken) {
        const now = Date.now();
        const needsRefresh = !auth.accessToken || 
                           !auth.expiresAt || 
                           (now > (auth.expiresAt - this.REFRESH_MARGIN_MS));
        
        if (needsRefresh) {
          console.log('[BackgroundService] JWT expired or expiring, refreshing...');
          try {
            const newToken = await this.refreshJwtToken(auth.refreshToken);
            return { 'Authorization': `Bearer ${newToken}` };
          } catch (refreshError) {
            console.error('[BackgroundService] Token refresh failed:', refreshError);
            // Fall through to API key if available
          }
        } else {
          return { 'Authorization': `Bearer ${auth.accessToken}` };
        }
      }
      
      // Fallback to API key
      if (auth.apiKey) {
        return { 'X-API-Key': auth.apiKey };
      }
      
      return null;
    } catch (error) {
      console.error('[BackgroundService] Failed to get auth headers:', error);
      return null;
    }
  }

  /**
   * Refresh JWT token using Supabase API
   */
  async refreshJwtToken(refreshToken) {
    console.log('[BackgroundService] Refreshing JWT token...');
    
    const response = await fetch(`${this.SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': this.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        refresh_token: refreshToken
      })
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Token refresh failed: ${response.status} - ${errorText}`);
    }

    const data = await response.json();
    
    // Store the new tokens
    const expiresAt = Date.now() + (data.expires_in * 1000);
    await chrome.storage.sync.set({
      accessToken: data.access_token,
      refreshToken: data.refresh_token,
      expiresAt: expiresAt,
      isLoggedIn: true
    });

    console.log('[BackgroundService] JWT token refreshed successfully');
    return data.access_token;
  }

  // ==================== Google Search Monitoring ====================

  setupGoogleSearchMonitor() {
    // Listen for completed navigation to Google search (from google.com search box)
    chrome.webNavigation.onCompleted.addListener(
      (details) => this.handleGoogleSearch(details),
      { url: [{ hostSuffix: 'google.com', pathPrefix: '/search' }] }
    );
    
    // Also listen for address bar (omnibox) searches that redirect to Google
    // This catches searches typed directly in Chrome's URL bar
    chrome.webNavigation.onCommitted.addListener(
      (details) => {
        // Only handle main frame and user-initiated navigations
        if (details.frameId !== 0) return;
        // transitionType 'generated' means the URL was generated (e.g., from address bar search)
        // transitionType 'typed' with transitionQualifiers containing 'from_address_bar' also works
        if (details.transitionType === 'generated' || 
            (details.transitionType === 'typed' && details.url.includes('google.com/search'))) {
          // The onCompleted handler will pick this up, but we log for debugging
          console.log('[SearchMonitor] 🔍 Address bar search detected:', details.url, 'transition:', details.transitionType);
        }
      },
      { url: [{ hostSuffix: 'google.com', pathPrefix: '/search' }] }
    );

    // Handle notification clicks
    chrome.notifications.onClicked.addListener((notificationId) => {
      this.handleNotificationClick(notificationId);
    });

    // Handle notification button clicks
    chrome.notifications.onButtonClicked.addListener((notificationId, buttonIndex) => {
      this.handleNotificationButtonClick(notificationId, buttonIndex);
    });
  }

  handleNotificationClick(notificationId) {
    if (!notificationId.startsWith('secondbrain-search-')) return;
    
    const results = this.pendingResults.get(notificationId);
    if (results && results.length > 0) {
      // Open each result in a new tab
      results.forEach(result => {
        const url = result.url || `${this.NOTES_APP_URL}/notes/${result.id}`;
        chrome.tabs.create({ url });
      });
    }
    
    chrome.notifications.clear(notificationId);
    this.pendingResults.delete(notificationId);
  }

  handleNotificationButtonClick(notificationId, buttonIndex) {
    if (!notificationId.startsWith('secondbrain-search-')) return;
    
    const data = this.pendingResults.get(notificationId);
    
    if (buttonIndex === 0 && data) {
      // "View Notes" button - open search URL
      const searchUrl = data.searchUrl || `${this.NOTES_APP_URL}/notes?q=${encodeURIComponent(data.query)}`;
      chrome.tabs.create({ url: searchUrl });
    }
    // Button 1 is "Dismiss" - just close
    
    chrome.notifications.clear(notificationId);
    this.pendingResults.delete(notificationId);
    this.clearBadge();
  }

  async handleGoogleSearch(details) {
    // Only handle main frame navigations
    if (details.frameId !== 0) return;

    const flowTimings = {
      flowStart: performance.now(),
      settingsCheck: 0,
      searchStart: 0,
      searchEnd: 0,
      notificationStart: 0,
      notificationEnd: 0
    };

    console.log('[SearchMonitor] 🔍 Google search detected, URL:', details.url);

    try {
      // Check if feature is enabled and user is logged in
      const { searchSuggestions, isLoggedIn, apiKey, accessToken, refreshToken } = await chrome.storage.sync.get([
        'searchSuggestions',
        'isLoggedIn',
        'apiKey',
        'accessToken',
        'refreshToken'
      ]);

      flowTimings.settingsCheck = performance.now();
      console.log(`[SearchMonitor] ⏱️ Settings check: ${(flowTimings.settingsCheck - flowTimings.flowStart).toFixed(0)}ms`);
      
      // Check for JWT auth (preferred) or API key auth (legacy)
      const hasAuth = accessToken || refreshToken || apiKey;
      console.log('[SearchMonitor] Settings:', { 
        searchSuggestions, 
        isLoggedIn, 
        hasJWT: !!(accessToken || refreshToken), 
        hasApiKey: !!apiKey 
      });

      if (searchSuggestions === false) {
        console.log('[SearchMonitor] Feature disabled in settings');
        return;
      }
      if (!isLoggedIn || !hasAuth) {
        console.log('[SearchMonitor] ⚠️ Not logged in - user needs to sign in');
        // Try to show a badge to indicate login needed
        try {
          chrome.action.setBadgeText({ text: '!' });
          chrome.action.setBadgeBackgroundColor({ color: '#ff6b6b' });
        } catch (e) {}
        return;
      }

      // Extract query from URL
      const url = new URL(details.url);
      const query = url.searchParams.get('q');
      const tabId = details.tabId;
      
      if (!query || query.trim().length < 2) return;
      
      // Skip if the query looks like a URL (user navigating, not searching)
      if (this.isLikelyUrl(query)) {
        console.log('[SearchMonitor] ⏭️ Skipping - query looks like a URL:', query);
        return;
      }
      // Rate limiting - skip if same query or too soon
      const now = Date.now();
      if (query === this.lastSearchQuery && (now - this.lastSearchTime) < this.RATE_LIMIT_MS) {
        console.log('Rate limited, skipping search');
        return;
      }
      this.lastSearchTime = now;
      this.lastSearchQuery = query;

      console.log(`[SearchMonitor] 🔎 Starting search for: "${query}"`);
      flowTimings.searchStart = performance.now();

      // DISABLED: Local cache check - only using backend now
      // await this.ensureFreshCache();
      // const localResults = await this.searchLocalCache(query);
      // console.log('Local cache results:', localResults.length);
      
      // Only use backend search
      const semanticResults = await this.searchBackend(query);
      
      flowTimings.searchEnd = performance.now();
      console.log(`[SearchMonitor] ⏱️ Backend search completed: ${(flowTimings.searchEnd - flowTimings.searchStart).toFixed(0)}ms, Results: ${semanticResults.length}`);
      
      if (semanticResults.length > 0) {
        flowTimings.notificationStart = performance.now();
        
        // Small delay to ensure page is ready for injection
        setTimeout(async () => {
          try {
            await this.showSearchNotification(query, semanticResults, tabId);
            flowTimings.notificationEnd = performance.now();
            
            // Log complete flow timing
            const totalFlow = flowTimings.notificationEnd - flowTimings.flowStart;
            const settingsTime = flowTimings.settingsCheck - flowTimings.flowStart;
            const searchTime = flowTimings.searchEnd - flowTimings.searchStart;
            const delayTime = 100; // The setTimeout delay
            const notificationTime = flowTimings.notificationEnd - flowTimings.notificationStart - delayTime;
            
            console.log(`[SearchMonitor] ✅ COMPLETE FLOW TIMING:
              ┌─────────────────────────────────────────┐
              │ Total End-to-End: ${totalFlow.toFixed(0)}ms
              ├─────────────────────────────────────────┤
              │ 1. Settings Check:     ${settingsTime.toFixed(0)}ms
              │ 2. Backend Search:     ${searchTime.toFixed(0)}ms
              │ 3. setTimeout Delay:   ${delayTime}ms
              │ 4. Notification Show:  ${notificationTime.toFixed(0)}ms
              └─────────────────────────────────────────┘
              Worker Request ID: ${this.lastSearchTiming?.workerRequestId || 'N/A'}`);
            
            // Send timing data to backend for logging
            this.logExtensionTiming({
              query,
              totalFlow,
              settingsTime,
              searchTime,
              notificationTime,
              delayTime,
              backendReported: this.lastSearchTiming?.backendReported,
              workerRequestId: this.lastSearchTiming?.workerRequestId,
              resultsCount: semanticResults.length
            });
            
          } catch (err) {
            console.error('[SearchMonitor] ❌ Notification failed:', err);
          }
        }, 100);
      } else {
        console.log(`[SearchMonitor] No matching notes found for: "${query}"`);
      }

    } catch (error) {
      console.error('[SearchMonitor] ❌ Failed to handle Google search:', error);
    }
  }

  async logExtensionTiming(timingData) {
    try {
      const { apiKey } = await chrome.storage.sync.get(['apiKey']);
      if (!apiKey || !timingData.workerRequestId) return;
      
      // Fire and forget - use Worker endpoint (not Fly.io)
      fetch('https://notesapp-vector-search.monocle0712.workers.dev/logs/extension-timing', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': apiKey
        },
        body: JSON.stringify({
          correlation_id: timingData.workerRequestId,
          query: timingData.query,
          timing_total_flow_ms: Math.round(timingData.totalFlow),
          timing_settings_check_ms: Math.round(timingData.settingsTime),
          timing_backend_search_ms: Math.round(timingData.searchTime),
          timing_notification_ms: Math.round(timingData.notificationTime),
          timing_delay_ms: timingData.delayTime,
          timing_backend_reported_ms: timingData.backendReported,
          results_count: timingData.resultsCount,
          source: 'chrome-extension'
        })
      }).catch(err => console.log('[SearchMonitor] Failed to log timing:', err.message));
      
    } catch (error) {
      // Ignore errors - this is just for analytics
    }
  }

  /**
   * Check if a query string looks like a URL rather than a search query.
   * This prevents triggering backend search when user is navigating to a site.
   */
  isLikelyUrl(query) {
    if (!query) return false;
    const trimmed = query.trim().toLowerCase();
    
    // Check for common URL patterns
    // 1. Starts with protocol
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://') || trimmed.startsWith('ftp://')) {
      return true;
    }
    
    // 2. Looks like a domain (has TLD and no spaces)
    // Common TLDs: .com, .org, .net, .io, .dev, .co, .ai, .app, etc.
    const domainPattern = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.(com|org|net|io|dev|co|ai|app|gov|edu|info|biz|me|us|uk|in|de|fr|jp|cn|ru|br|au|ca|it|es|nl|se|no|fi|dk|pl|cz|at|ch|be|pt|gr|ie|nz|sg|hk|tw|kr|mx|ar|cl|za|my|th|ph|vn|id|pk|bd|eg|ng|ke|ae|sa|il|tr)$/;
    if (domainPattern.test(trimmed) && !trimmed.includes(' ')) {
      return true;
    }
    
    // 3. Has www. prefix
    if (trimmed.startsWith('www.')) {
      return true;
    }
    
    // 4. Looks like IP address
    const ipPattern = /^(\d{1,3}\.){3}\d{1,3}(:\d+)?(\/.*)?$/;
    if (ipPattern.test(trimmed)) {
      return true;
    }
    
    // 5. localhost or local dev URLs
    if (trimmed.startsWith('localhost') || trimmed.startsWith('127.0.0.1')) {
      return true;
    }
    
    return false;
  }

  async ensureFreshCache() {
    try {
      const { cacheLastSync } = await chrome.storage.local.get('cacheLastSync');
      const now = Date.now();
      
      if (!cacheLastSync || (now - cacheLastSync) > this.CACHE_STALE_THRESHOLD) {
        console.log('Cache is stale, syncing...');
        await this.syncKeywordCache();
      }
    } catch (error) {
      console.error('Failed to check cache freshness:', error);
    }
  }

  async searchLocalCache(query) {
    try {
      const { keywordCache } = await chrome.storage.local.get('keywordCache');
      if (!keywordCache) return [];

      const queryWords = query.toLowerCase().split(/\s+/);
      const matchedNotes = new Map();

      // Search through keywords
      for (const [keyword, notes] of Object.entries(keywordCache)) {
        const keywordLower = keyword.toLowerCase();
        for (const word of queryWords) {
          if (keywordLower.includes(word) || word.includes(keywordLower)) {
            for (const note of notes) {
              if (!matchedNotes.has(note.id)) {
                matchedNotes.set(note.id, { ...note, score: 1 });
              } else {
                matchedNotes.get(note.id).score++;
              }
            }
          }
        }
      }

      // Sort by score and return top 5
      return Array.from(matchedNotes.values())
        .sort((a, b) => b.score - a.score)
        .slice(0, 5);

    } catch (error) {
      console.error('Local cache search failed:', error);
      return [];
    }
  }

  async searchBackend(query, retryCount = 0) {
    const MAX_RETRIES = 1;
    const timings = {
      start: performance.now(),
      apiCallStart: 0,
      apiCallEnd: 0,
      parseStart: 0,
      parseEnd: 0
    };
    
    try {
      // Get auth credentials - prefer JWT over API key
      const authHeaders = await this.getAuthHeaders();
      if (!authHeaders) {
        console.log('[SearchMonitor] ⚠️ No auth credentials found in storage');
        return [];
      }

      timings.apiCallStart = performance.now();
      
      // Call Worker directly for better performance (bypasses Gateway/Fly.io)
      // Worker validates JWT or API key and extracts user_id
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 15000); // 15s timeout
      
      const response = await fetch(
        `https://notesapp-vector-search.monocle0712.workers.dev/rag-search-auth`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...authHeaders
          },
          body: JSON.stringify({
            query: query,
            client_source: 'google-search'  // Track that this came from Google search monitoring
            // max_results defaults to Worker's default (usually 5)
          }),
          signal: controller.signal
        }
      );
      
      clearTimeout(timeoutId);

      timings.apiCallEnd = performance.now();

      if (!response.ok) {
        console.warn(`[SearchMonitor] ⚠️ Backend search failed with status ${response.status}`);
        // If 401/403, check if session was revoked
        if (response.status === 401 || response.status === 403) {
          try {
            const errorData = await response.json();
            if (errorData.error === 'SESSION_REVOKED' || errorData.error?.includes('SESSION_REVOKED')) {
              console.warn('[SearchMonitor] ⚠️ Session was revoked - clearing auth and requiring re-login');
              // Clear all auth data
              await chrome.storage.sync.remove([
                'accessToken', 'refreshToken', 'expiresAt', 'userEmail', 'userId', 'isLoggedIn', 'apiKey'
              ]);
              // Show badge indicating re-login needed
              chrome.action.setBadgeText({ text: '!' });
              chrome.action.setBadgeBackgroundColor({ color: '#ff6b6b' });
              chrome.action.setTitle({ title: 'Session expired - Click to sign in again' });
              return [];
            }
          } catch (e) {
            // If error parsing fails, continue with generic handling
          }
          console.warn('[SearchMonitor] ⚠️ API key appears invalid - user may need to re-login');
          try {
            chrome.action.setBadgeText({ text: '!' });
            chrome.action.setBadgeBackgroundColor({ color: '#ff6b6b' });
          } catch (e) {}
        }
        return [];
      }

      timings.parseStart = performance.now();
      const data = await response.json();
      timings.parseEnd = performance.now();
      
      // Log detailed timing breakdown
      const totalTime = timings.parseEnd - timings.start;
      const apiTime = timings.apiCallEnd - timings.apiCallStart;
      const parseTime = timings.parseEnd - timings.parseStart;
      const overhead = totalTime - apiTime - parseTime;
      
      console.log(`[SearchMonitor] ⏱️ Backend Search Timing:
        Total: ${totalTime.toFixed(0)}ms
        API Call: ${apiTime.toFixed(0)}ms
        JSON Parse: ${parseTime.toFixed(0)}ms
        Overhead: ${overhead.toFixed(0)}ms
        Backend reported: ${data.duration_ms || data.metadata?.timing?.total_ms || 'N/A'}ms
        Worker Request ID: ${data.worker_request_id || data.metadata?.worker_request_id || 'N/A'}`);
      
      // Store timing for later use in notification
      this.lastSearchTiming = {
        query,
        totalTime,
        apiTime,
        parseTime,
        backendReported: data.duration_ms || data.metadata?.timing?.total_ms,
        workerRequestId: data.worker_request_id || data.metadata?.worker_request_id,
        timestamp: Date.now()
      };
      
      // Clear any error badge on successful search
      try {
        chrome.action.setBadgeText({ text: '' });
      } catch (e) {}
      
      console.log('[SearchMonitor] ✅ Backend returned:', data.results?.length || 0, 'results');
      return data.results || data.notes || [];

    } catch (error) {
      // Retry on network errors (but not on abort)
      if (error.name !== 'AbortError' && retryCount < MAX_RETRIES) {
        console.log(`[SearchMonitor] ⚠️ Backend search failed, retrying (${retryCount + 1}/${MAX_RETRIES})...`);
        await new Promise(r => setTimeout(r, 500)); // Wait 500ms before retry
        return this.searchBackend(query, retryCount + 1);
      }
      console.error('[SearchMonitor] ❌ Backend search failed:', error.message || error);
      return [];
    }
  }

  mergeResults(localResults, semanticResults) {
    const merged = new Map();
    
    // Add local results first
    for (const result of localResults) {
      merged.set(result.id, result);
    }
    
    // Add semantic results (may override with better data)
    for (const result of semanticResults) {
      if (!merged.has(result.id)) {
        merged.set(result.id, result);
      }
    }
    
    return Array.from(merged.values()).slice(0, 5);
  }

  async showSearchNotification(query, results, tabId) {
    if (results.length === 0) return;

    const notifTimings = {
      start: performance.now(),
      dataPrep: 0,
      cssInjection: 0,
      scriptInjection: 0,
      end: 0
    };

    try {
      // Build the notification data - url comes from backend response as view_url
      const notificationData = {
        query: query,
        results: results.slice(0, 3).map(r => ({
          id: r.id || r.note_id,
          title: r.title || 'Untitled',
          snippet: r.snippet || r.content?.substring(0, 100) || '',
          tag: r.tag || '',
          url: r.view_url || r.url  // Backend returns view_url, fallback to url
        })),
        appUrl: `${this.NOTES_APP_URL}/notes?q=${encodeURIComponent(query)}`
      };
      
      notifTimings.dataPrep = performance.now();
      console.log(`[SearchMonitor] ⏱️ Data prep: ${(notifTimings.dataPrep - notifTimings.start).toFixed(0)}ms`);
      console.log('[SearchMonitor] Notification data:', notificationData);

      // First inject the external CSS file for faster loading
      await chrome.scripting.insertCSS({
        target: { tabId: tabId },
        files: ['src/styles/search-notification.css']
      });
      
      notifTimings.cssInjection = performance.now();
      console.log(`[SearchMonitor] ⏱️ CSS injection: ${(notifTimings.cssInjection - notifTimings.dataPrep).toFixed(0)}ms`);

      // Then inject the HTML and event handlers (no inline CSS needed)
      const injectionResult = await chrome.scripting.executeScript({
        target: { tabId: tabId },
        func: (data) => {
          // Remove any existing notification
          const existing = document.getElementById('secondbrain-search-notification');
          if (existing) existing.remove();

          // Create notification container (CSS is injected externally)
          const container = document.createElement('div');
          container.id = 'secondbrain-search-notification';
          container.innerHTML = `
            <div class="sb-header">
              <span class="sb-title">📚 Found ${data.results.length} note${data.results.length > 1 ? 's' : ''} in infoSnap.ai</span>
              <button class="sb-close" id="sb-close-btn">✕</button>
            </div>
            <div class="sb-results">
              ${data.results.map((r, index) => `
                <div class="sb-result" data-index="${index}">
                  <div class="sb-result-title">${r.title}</div>
                  ${r.snippet ? `<div class="sb-result-snippet">${r.snippet}</div>` : ''}
                  ${r.tag ? `<span class="sb-tag">#${r.tag}</span>` : ''}
                </div>
              `).join('')}
            </div>
            <div class="sb-footer">
              <button class="sb-view-all" id="sb-view-all-btn">View All Notes</button>
            </div>
          `;

          document.body.appendChild(container);

          // Dismiss function
          const dismissNotification = () => {
            const notif = document.getElementById('secondbrain-search-notification');
            if (notif) {
              notif.style.animation = 'sbSlideOut 0.3s ease-in forwards';
              setTimeout(() => notif.remove(), 300);
            }
          };

          // Event handlers
          document.getElementById('sb-close-btn').onclick = dismissNotification;

          document.getElementById('sb-view-all-btn').onclick = () => {
            data.results.forEach(result => {
              if (result.url) window.open(result.url, '_blank');
            });
            dismissNotification();
          };

          // Click handler for individual results
          container.querySelectorAll('.sb-result').forEach(el => {
            el.onclick = (e) => {
              e.preventDefault();
              e.stopPropagation();
              const index = parseInt(el.dataset.index, 10);
              const url = data.results[index]?.url;
              if (url) window.open(url, '_blank');
            };
          });

          // No auto-dismiss - user closes manually
          return 'Notification injected';
        },
        args: [notificationData]
      });

      // Check if injection succeeded, fallback to native notification if not
      notifTimings.scriptInjection = performance.now();
      console.log(`[SearchMonitor] ⏱️ Script injection: ${(notifTimings.scriptInjection - notifTimings.cssInjection).toFixed(0)}ms`);
      
      const injectionSucceeded = injectionResult?.[0]?.result && !injectionResult[0].error;
      if (!injectionSucceeded) {
        await this.showNativeNotification(query, results);
      }
      
      notifTimings.end = performance.now();
      
      // Log notification timing breakdown
      console.log(`[SearchMonitor] 📢 NOTIFICATION TIMING:
        ┌─────────────────────────────────────────┐
        │ Total Notification: ${(notifTimings.end - notifTimings.start).toFixed(0)}ms
        ├─────────────────────────────────────────┤
        │ 1. Data Preparation: ${(notifTimings.dataPrep - notifTimings.start).toFixed(0)}ms
        │ 2. CSS Injection:    ${(notifTimings.cssInjection - notifTimings.dataPrep).toFixed(0)}ms
        │ 3. Script Injection: ${(notifTimings.scriptInjection - notifTimings.cssInjection).toFixed(0)}ms
        │ 4. Badge/Cleanup:    ${(notifTimings.end - notifTimings.scriptInjection).toFixed(0)}ms
        └─────────────────────────────────────────┘`);
      
      // Show badge with count
      this.showMatchBadge(results.length);
      
      // Clear badge after 10 seconds
      setTimeout(() => this.clearBadge(), 10000);

    } catch (error) {
      console.error('[SearchMonitor] Failed to inject notification:', error.message);
      // Try fallback native notification
      try {
        await this.showNativeNotification(query, results);
      } catch (fallbackError) {
        console.error('[SearchMonitor] Fallback notification also failed:', fallbackError);
      }
    }
  }

  async showNativeNotification(query, results) {
    const notificationId = `secondbrain-search-${Date.now()}`;
    
    // Store results for when user clicks the notification
    this.pendingResults.set(notificationId, results);
    
    const titles = results.slice(0, 3).map(r => r.title || 'Untitled').join(', ');
    
    await chrome.notifications.create(notificationId, {
      type: 'basic',
      iconUrl: chrome.runtime.getURL('icons/icon128.png'),
      title: `📚 Found ${results.length} note${results.length > 1 ? 's' : ''} in infoSnap.ai`,
      message: titles,
      priority: 2,
      requireInteraction: false
    });
    
    console.log('[SearchMonitor] Native notification shown:', notificationId);
  }

  showMatchBadge(count) {
    chrome.action.setBadgeText({ text: count.toString() });
    chrome.action.setBadgeBackgroundColor({ color: '#22c55e' });
  }

  clearBadge() {
    chrome.action.setBadgeText({ text: '' });
  }

  // ==================== Cache Sync ====================

  setupCacheSync() {
    // Sync on install/update
    chrome.runtime.onInstalled.addListener(() => {
      this.syncKeywordCache();
      // Create alarm for periodic sync
      chrome.alarms.create('cache-sync', { periodInMinutes: this.CACHE_SYNC_INTERVAL });
    });

    // Listen for alarm
    chrome.alarms.onAlarm.addListener((alarm) => {
      if (alarm.name === 'cache-sync') {
        this.syncKeywordCache();
      }
    });

    // Initial sync after startup (in case alarm wasn't created yet)
    setTimeout(() => {
      this.syncKeywordCache();
      // Ensure alarm exists
      chrome.alarms.get('cache-sync', (alarm) => {
        if (!alarm) {
          chrome.alarms.create('cache-sync', { periodInMinutes: this.CACHE_SYNC_INTERVAL });
        }
      });
    }, 5000);
  }

  async syncKeywordCache() {
    try {
      const { apiKey, searchBaseUrl, isLoggedIn } = await chrome.storage.sync.get([
        'apiKey',
        'searchBaseUrl',
        'isLoggedIn'
      ]);

      if (!isLoggedIn || !apiKey) {
        console.log('Not logged in, skipping cache sync');
        return;
      }

      // Use Worker directly (no Gateway/Fly.io)
      const baseUrl = searchBaseUrl || 'https://notesapp-vector-search.monocle0712.workers.dev/api/v1';

      // Try /search/keywords first (more reliable), fallback to /notes/keywords
      let response = await fetch(`${baseUrl}/search/keywords`, {
        method: 'GET',
        headers: {
          'X-API-Key': apiKey
        }
      });

      // Fallback to /notes/keywords if /search/keywords fails
      if (!response.ok) {
        console.log('Trying fallback /notes/keywords endpoint...');
        response = await fetch(`${baseUrl}/notes/keywords`, {
          method: 'GET',
          headers: {
            'X-API-Key': apiKey
          }
        });
      }

      if (!response.ok) {
        console.warn('Keyword cache sync failed:', response.status, '- Backend search will still work');
        // Set empty cache but mark as synced to avoid repeated failures
        await chrome.storage.local.set({
          keywordCache: {},
          cacheLastSync: Date.now()
        });
        return;
      }

      const data = await response.json();
      
      // Store in local storage for fast access
      await chrome.storage.local.set({
        keywordCache: data.keywords || {},
        cacheLastSync: Date.now()
      });

      console.log('Keyword cache synced:', Object.keys(data.keywords || {}).length, 'keywords');

    } catch (error) {
      console.error('Cache sync failed:', error);
    }
  }

  // Trigger cache sync after upload (called from popup)
  async triggerCacheSync() {
    await this.syncKeywordCache();
  }

  // Show notification for upload status (called from popup)
  showUploadNotification(title, message) {
    try {
      chrome.notifications.create(`infosnap-upload-${Date.now()}`, {
        type: 'basic',
        iconUrl: chrome.runtime.getURL('icons/icon128.png'),
        title: title || 'infoSnap.ai',
        message: message || '',
        priority: 2,
      });
    } catch (e) {
      console.warn('[Background] Failed to show notification:', e);
    }
  }

  setupMessageHandlers() {
    chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
      // Handle AUTH_SUCCESS from content-auth.js
      if (request.type === 'AUTH_SUCCESS') {
        this.handleAuthSuccess(request, sender, sendResponse);
        return true;
      }

      switch (request.action) {
        case 'captureVisibleTab':
          this.handleCaptureTab(sender, sendResponse);
          return true; // Will respond asynchronously

        case 'downloadImage':
          this.handleDownload(request, sendResponse);
          return true; // Will respond asynchronously

        case 'showPreview':
          this.handleShowPreview(request, sendResponse);
          return true; // Will respond asynchronously

        case 'checkPermissions':
          this.handlePermissionCheck(sendResponse);
          return true;

        case 'saveToCloud':
          this.handleSaveToCloud(request, sendResponse);
          return true;

        case 'syncCache':
          this.triggerCacheSync().then(() => {
            sendResponse({ success: true });
          }).catch(err => {
            sendResponse({ success: false, error: err.message });
          });
          return true;

        case 'showNotification':
          this.showUploadNotification(request.title, request.message);
          sendResponse({ success: true });
          return true;

        default:
          sendResponse({ success: false, error: 'Unknown action' });
      }
    });
  }

  async handleAuthSuccess(request, sender, sendResponse) {
    try {
      const { apiKey, email } = request;
      
      if (!apiKey || !apiKey.startsWith('na_')) {
        sendResponse({ success: false, error: 'Invalid API key' });
        return;
      }

      // Store credentials in chrome.storage.sync
      await chrome.storage.sync.set({
        apiKey: apiKey,
        userEmail: email,
        isLoggedIn: true,
        loginTimestamp: Date.now()
      });

      console.log('Auth success: API key stored for', email);
      
      // Show success badge
      this.showBadge('✓', '#22c55e');
      
      // Sync keyword cache after login
      this.syncKeywordCache();
      
      // Close the auth tab after a short delay
      if (sender && sender.tab && sender.tab.id) {
        setTimeout(() => {
          chrome.tabs.remove(sender.tab.id).catch(err => {
            console.log('Tab already closed or could not be closed:', err);
          });
        }, 1500);
      }
      
      sendResponse({ success: true });

    } catch (error) {
      console.error('Failed to store auth credentials:', error);
      sendResponse({ success: false, error: error.message });
    }
  }

  setupActionHandlers() {
    chrome.action.onClicked.addListener((tab) => {
      this.initiateCapture(tab);
    });
  }

  setupContextMenus() {
    // Create context menus on install
    chrome.runtime.onInstalled.addListener(() => {
      this.createContextMenus();
    });

    // Handle context menu clicks
    chrome.contextMenus.onClicked.addListener((info, tab) => {
      this.handleContextMenuClick(info, tab);
    });
  }

  createContextMenus() {
    // Remove existing menus first
    chrome.contextMenus.removeAll(() => {
      // Parent menu
      chrome.contextMenus.create({
        id: 'secondbrain-parent',
        title: '📷 infoSnap.ai',
        contexts: ['page', 'selection', 'image']
      });

      // Save selection as note
      chrome.contextMenus.create({
        id: 'save-selection',
        parentId: 'secondbrain-parent',
        title: '📝 Save selection as note',
        contexts: ['selection']
      });

      // Save image
      chrome.contextMenus.create({
        id: 'save-image',
        parentId: 'secondbrain-parent',
        title: '🖼️ Save image',
        contexts: ['image']
      });

      // Take screenshot of page
      chrome.contextMenus.create({
        id: 'screenshot-page',
        parentId: 'secondbrain-parent',
        title: '📷 Take screenshot',
        contexts: ['page']
      });

      // Separator
      chrome.contextMenus.create({
        id: 'separator-1',
        parentId: 'secondbrain-parent',
        type: 'separator',
        contexts: ['page', 'selection', 'image']
      });

      // Open infoSnap.ai
      chrome.contextMenus.create({
        id: 'open-popup',
        parentId: 'secondbrain-parent',
        title: '🚀 Open infoSnap.ai',
        contexts: ['page', 'selection', 'image']
      });
    });
  }

  async handleContextMenuClick(info, tab) {
    try {
      switch (info.menuItemId) {
        case 'save-selection':
          await this.saveSelectionAsNote(info.selectionText, tab);
          break;

        case 'save-image':
          await this.saveImageFromUrl(info.srcUrl, tab);
          break;

        case 'screenshot-page':
          await this.initiateCapture(tab);
          break;

        case 'open-popup':
          await chrome.action.openPopup();
          break;
      }
    } catch (error) {
      console.error('Context menu action failed:', error);
    }
  }

  async saveSelectionAsNote(text, tab) {
    if (!text) return;

    try {
      // Get API credentials
      const { apiKey, uploadBaseUrl } = await chrome.storage.sync.get(['apiKey', 'uploadBaseUrl']);
      
      if (!apiKey) {
        // Open popup to login
        await chrome.action.openPopup();
        return;
      }

      const baseUrl = uploadBaseUrl || 'https://notesapp-upload.fly.dev/api/v1';
      
      // Save note via API
      const response = await fetch(`${baseUrl}/upload/quick-note`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': apiKey
        },
        body: JSON.stringify({
          content: text,
          title: `Selection from ${new URL(tab.url).hostname}`,
          tag: 'web-selection'
        })
      });

      if (!response.ok) {
        throw new Error('Failed to save note');
      }

      // Sync cache and show notification
      this.syncKeywordCache();
      this.showBadge('✓', '#38a169');

    } catch (error) {
      console.error('Failed to save selection:', error);
      this.showBadge('!', '#c53030');
    }
  }

  async saveImageFromUrl(imageUrl, tab) {
    if (!imageUrl) return;

    try {
      // Get API credentials
      const { apiKey, uploadBaseUrl } = await chrome.storage.sync.get(['apiKey', 'uploadBaseUrl']);
      
      if (!apiKey) {
        await chrome.action.openPopup();
        return;
      }

      const baseUrl = uploadBaseUrl || 'https://notesapp-upload.fly.dev/api/v1';

      // Fetch the image
      const imageResponse = await fetch(imageUrl);
      const blob = await imageResponse.blob();

      // Create form data
      const formData = new FormData();
      const filename = imageUrl.split('/').pop().split('?')[0] || `image-${Date.now()}.png`;
      formData.append('file', blob, filename);
      formData.append('tag', 'web-image');
      formData.append('title', `Image from ${new URL(tab.url).hostname}`);

      // Upload to API
      const response = await fetch(`${baseUrl}/upload/file`, {
        method: 'POST',
        headers: {
          'X-API-Key': apiKey
        },
        body: formData
      });

      if (!response.ok) {
        throw new Error('Failed to save image');
      }

      // Sync cache and show notification
      this.syncKeywordCache();
      this.showBadge('✓', '#38a169');

    } catch (error) {
      console.error('Failed to save image:', error);
      this.showBadge('!', '#c53030');
    }
  }

  showBadge(text, color) {
    chrome.action.setBadgeText({ text });
    chrome.action.setBadgeBackgroundColor({ color });
    
    // Clear badge after 2 seconds
    setTimeout(() => {
      chrome.action.setBadgeText({ text: '' });
    }, 2000);
  }

  async handleCaptureTab(sender, sendResponse) {
    try {
      if (!sender.tab) {
        throw new Error('No active tab found');
      }

      const dataUrl = await chrome.tabs.captureVisibleTab(
        sender.tab.windowId,
        { 
          format: 'png', 
          quality: 100 
        }
      );

      sendResponse({ 
        success: true, 
        dataUrl: dataUrl,
        timestamp: Date.now()
      });

    } catch (error) {
      console.error('Capture failed:', error);
      sendResponse({ 
        success: false, 
        error: error.message || 'Screenshot capture failed'
      });
    }
  }

  async handleDownload(request, sendResponse) {
    try {
      const filename = request.filename || `screenshot-${Date.now()}.png`;
      
      const downloadId = await chrome.downloads.download({
        url: request.dataUrl,
        filename: `Downloads\\${filename}`,
        saveAs: false,
        conflictAction: 'uniquify'
      });

      // Store download info
      await chrome.storage.local.set({
        [`download_${downloadId}`]: {
          timestamp: Date.now(),
          filename: filename,
          status: 'completed'
        }
      });

      sendResponse({ 
        success: true, 
        downloadId: downloadId,
        filename: filename
      });

    } catch (error) {
      console.error('Download failed:', error);
      sendResponse({ 
        success: false, 
        error: error.message || 'Download failed'
      });
    }
  }

  async handleShowPreview(request, sendResponse) {
    try {
      // Store the screenshot data for the popup to access
      await chrome.storage.local.set({
        'preview_screenshot': {
          dataUrl: request.dataUrl,
          dimensions: request.dimensions,
          timestamp: Date.now()
        }
      });

      // Auto-open popup to show preview
      await chrome.action.openPopup();

      sendResponse({ 
        success: true,
        message: 'Preview data stored and popup opened'
      });

    } catch (error) {
      console.error('Failed to store preview data or open popup:', error);
      sendResponse({ 
        success: false, 
        error: error.message || 'Failed to store preview data'
      });
    }
  }

  async handlePermissionCheck(sendResponse) {
    try {
      const permissions = await chrome.permissions.getAll();
      const hasRequiredPermissions = [
        'activeTab',
        'downloads',
        'storage'
      ].every(permission => permissions.permissions.includes(permission));

      sendResponse({
        success: true,
        hasPermissions: hasRequiredPermissions,
        permissions: permissions.permissions
      });

    } catch (error) {
      sendResponse({
        success: false,
        error: error.message
      });
    }
  }

  async handleSaveToCloud(request, sendResponse) {
    try {
      const { apiKey, uploadBaseUrl } = await chrome.storage.sync.get(['apiKey', 'uploadBaseUrl']);
      
      if (!apiKey) {
        sendResponse({ success: false, error: 'Not authenticated' });
        return;
      }

      const baseUrl = uploadBaseUrl || 'https://notesapp-upload.fly.dev/api/v1';
      const { type, data } = request;

      let response;
      
      if (type === 'note') {
        response = await fetch(`${baseUrl}/upload/quick-note`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-API-Key': apiKey
          },
          body: JSON.stringify(data)
        });
      } else {
        // For files/screenshots, create FormData
        const formData = new FormData();
        formData.append('file', data.file);
        if (data.tag) formData.append('tag', data.tag);
        if (data.title) formData.append('title', data.title);

        const endpoint = type === 'screenshot' ? '/upload/screenshot' : '/upload/file';
        response = await fetch(`${baseUrl}${endpoint}`, {
          method: 'POST',
          headers: {
            'X-API-Key': apiKey
          },
          body: formData
        });
      }

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        throw new Error(errorData.message || 'Upload failed');
      }

      const result = await response.json();
      sendResponse({ success: true, data: result });

    } catch (error) {
      console.error('Save to cloud failed:', error);
      sendResponse({ success: false, error: error.message });
    }
  }

  async initiateCapture(tab) {
    try {
      if (this.isRestrictedUrl(tab.url)) {
        this.showBadge('!', '#c53030');
        return;
      }

      await chrome.tabs.sendMessage(tab.id, { action: 'startCapture' });

    } catch (error) {
      console.error('Failed to initiate capture:', error);
      this.showBadge('!', '#c53030');
    }
  }

  isRestrictedUrl(url) {
    const restrictedPatterns = [
      /^chrome:\/\//,
      /^chrome-extension:\/\//,
      /^chrome-search:\/\//,
      /^edge:\/\//,
      /^about:/
    ];

    return restrictedPatterns.some(pattern => pattern.test(url));
  }
}

// Initialize background service
new BackgroundService();