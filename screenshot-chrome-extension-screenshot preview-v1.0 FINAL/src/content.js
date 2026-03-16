/**
 * Content Script for Screenshot Selector Pro
 * Handles UI overlay and area selection
 */

class ScreenshotSelector {
  constructor() {
    this.isSelecting = false;
    this.startX = 0;
    this.startY = 0;
    this.endX = 0;
    this.endY = 0;
    this.overlay = null;
    this.selectionBox = null;
    this.instructionsEl = null;
    this.pixelRatio = window.devicePixelRatio || 1;
  }

  async init() {
    try {
      console.log('ScreenshotSelector.init() called');
      await this.createOverlay();
      console.log('Overlay created');
      this.attachEventListeners();
      console.log('Event listeners attached');
      this.showInstructions();
      console.log('Instructions shown');
    } catch (error) {
      console.error('Failed to initialize screenshot selector:', error);
      this.showNotification('Failed to initialize screenshot tool', 'error');
    }
  }

  async createOverlay() {
    // Remove existing overlay
    this.removeOverlay();

    // Create main overlay
    this.overlay = document.createElement('div');
    this.overlay.id = 'screenshot-overlay';
    this.overlay.className = 'screenshot-overlay';

    // Create selection box
    this.selectionBox = document.createElement('div');
    this.selectionBox.id = 'selection-box';
    this.selectionBox.className = 'selection-box';
    
    // Set initial display state
    this.selectionBox.style.display = 'none';

    // Create instructions panel
    this.instructionsEl = document.createElement('div');
    this.instructionsEl.className = 'instructions-panel';
    this.instructionsEl.innerHTML = `
      <div class="instructions-content">
        <h3>📷 Screenshot Selector</h3>
        <p>Click and drag to select an area</p>
        <div class="instructions-controls">
          <kbd>ENTER</kbd> Full Screen &nbsp;&nbsp; <kbd>ESC</kbd> Cancel
        </div>
      </div>
    `;

    // Append elements
    this.overlay.appendChild(this.selectionBox);
    this.overlay.appendChild(this.instructionsEl);
    document.body.appendChild(this.overlay);

    // Animate in
    requestAnimationFrame(() => {
      this.overlay.classList.add('active');
    });
  }

  attachEventListeners() {
    // Mouse events
    this.overlay.addEventListener('mousedown', this.onMouseDown.bind(this));
    this.overlay.addEventListener('mousemove', this.onMouseMove.bind(this));
    this.overlay.addEventListener('mouseup', this.onMouseUp.bind(this));

    // Keyboard events
    this.keydownHandler = this.onKeyDown.bind(this);
    document.addEventListener('keydown', this.keydownHandler);

    // Prevent context menu
    this.overlay.addEventListener('contextmenu', (e) => e.preventDefault());
  }

  onMouseDown(e) {
    if (e.target !== this.overlay) return;

    this.isSelecting = true;
    this.startX = e.clientX;
    this.startY = e.clientY;
    this.endX = e.clientX;
    this.endY = e.clientY;

    this.selectionBox.style.display = 'block';
    this.selectionBox.classList.add('visible');
    this.hideInstructions();
    this.updateSelectionBox();
    
    console.log('Selection box should now be visible:', {
      display: this.selectionBox.style.display,
      className: this.selectionBox.className,
      position: { x: this.startX, y: this.startY }
    });

    // Add visual feedback
    this.overlay.style.cursor = 'crosshair';
  }

  onMouseMove(e) {
    if (!this.isSelecting) return;

    this.endX = e.clientX;
    this.endY = e.clientY;
    this.updateSelectionBox();
  }

  async onMouseUp(e) {
    if (!this.isSelecting) return;

    this.isSelecting = false;
    this.endX = e.clientX;
    this.endY = e.clientY;

    const rect = this.getSelectionRect();

    if (rect.width > 10 && rect.height > 10) {
      await this.captureSelectedArea(rect);
    } else {
      this.showNotification('Selection too small. Please select a larger area.', 'warning');
      this.showInstructions();
    }
  }

  onKeyDown(e) {
    switch (e.key) {
      case 'Escape':
        this.removeOverlay();
        break;
      case 'Enter':
        e.preventDefault();
        this.captureFullScreen();
        break;
    }
  }

  updateSelectionBox() {
    const rect = this.getSelectionRect();
    
    console.log('Updating selection box:', rect);
    
    Object.assign(this.selectionBox.style, {
      left: `${rect.x}px`,
      top: `${rect.y}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`
    });

    // Ensure the selection box is visible
    if (!this.selectionBox.classList.contains('visible')) {
      this.selectionBox.classList.add('visible');
    }

    // Update selection info
    this.updateSelectionInfo(rect);
  }

  updateSelectionInfo(rect) {
    const info = `${Math.round(rect.width)} × ${Math.round(rect.height)}`;
    
    if (!this.selectionInfo) {
      this.selectionInfo = document.createElement('div');
      this.selectionInfo.className = 'selection-info';
      this.overlay.appendChild(this.selectionInfo);
    }

    this.selectionInfo.textContent = info;
    this.selectionInfo.style.left = `${rect.x + rect.width + 5}px`;
    this.selectionInfo.style.top = `${rect.y}px`;
  }

  getSelectionRect() {
    const x = Math.min(this.startX, this.endX);
    const y = Math.min(this.startY, this.endY);
    const width = Math.abs(this.endX - this.startX);
    const height = Math.abs(this.endY - this.startY);

    return { x, y, width, height };
  }

  async captureSelectedArea(rect) {
    try {
      this.showLoadingState();
      
      // Hide the overlay temporarily while capturing
      this.hideOverlayForCapture();
      
      // Wait a moment for the overlay to hide
      await new Promise(resolve => setTimeout(resolve, 100));

      const response = await chrome.runtime.sendMessage({
        action: 'captureVisibleTab'
      });

      if (!response.success) {
        throw new Error(response.error);
      }

      await this.processCapture(response.dataUrl, rect);

    } catch (error) {
      console.error('Capture failed:', error);
      this.showNotification(`Capture failed: ${error.message}`, 'error');
    } finally {
      this.removeOverlay();
    }
  }

  async captureFullScreen() {
    try {
      this.showLoadingState();
      
      // Hide the overlay temporarily while capturing
      this.hideOverlayForCapture();
      
      // Wait a moment for the overlay to hide
      await new Promise(resolve => setTimeout(resolve, 100));

      const response = await chrome.runtime.sendMessage({
        action: 'captureVisibleTab'
      });

      if (!response.success) {
        throw new Error(response.error);
      }

      const fullRect = {
        x: 0,
        y: 0,
        width: window.innerWidth,
        height: window.innerHeight
      };

      await this.processCapture(response.dataUrl, fullRect);

    } catch (error) {
      console.error('Full screen capture failed:', error);
      this.showNotification(`Capture failed: ${error.message}`, 'error');
    } finally {
      this.removeOverlay();
    }
  }

  async processCapture(dataUrl, rect) {
    try {
      const croppedDataUrl = await this.cropImage(dataUrl, rect);
      
      // Send screenshot data to popup for preview instead of auto-downloading
      await chrome.runtime.sendMessage({
        action: 'showPreview',
        dataUrl: croppedDataUrl,
        dimensions: {
          width: Math.round(rect.width),
          height: Math.round(rect.height)
        }
      });

      this.showNotification('Screenshot captured! Opening preview... 📷', 'success');

    } catch (error) {
      throw new Error(`Processing failed: ${error.message}`);
    }
  }

  cropImage(dataUrl, rect) {
    return new Promise((resolve, reject) => {
      const canvas = document.createElement('canvas');
      const ctx = canvas.getContext('2d');
      const img = new Image();

      img.onload = () => {
        try {
          const scaledRect = {
            x: rect.x * this.pixelRatio,
            y: rect.y * this.pixelRatio,
            width: rect.width * this.pixelRatio,
            height: rect.height * this.pixelRatio
          };

          canvas.width = scaledRect.width;
          canvas.height = scaledRect.height;

          ctx.drawImage(
            img,
            scaledRect.x, scaledRect.y, scaledRect.width, scaledRect.height,
            0, 0, scaledRect.width, scaledRect.height
          );

          resolve(canvas.toDataURL('image/png', 1.0));

        } catch (error) {
          reject(error);
        }
      };

      img.onerror = () => reject(new Error('Failed to load captured image'));
      img.src = dataUrl;
    });
  }

  async downloadImage(dataUrl) {
    try {
      const filename = `screenshot-${new Date().toISOString().slice(0, 19).replace(/:/g, '-')}.png`;
      
      const response = await chrome.runtime.sendMessage({
        action: 'downloadImage',
        dataUrl: dataUrl,
        filename: filename
      });

      if (!response.success) {
        // Fallback to direct download
        this.fallbackDownload(dataUrl, filename);
      }

    } catch (error) {
      // Fallback to direct download
      const filename = `screenshot-${Date.now()}.png`;
      this.fallbackDownload(dataUrl, filename);
    }
  }

  fallbackDownload(dataUrl, filename) {
    const link = document.createElement('a');
    link.href = dataUrl;
    link.download = filename;
    link.style.display = 'none';
    
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  }

  showLoadingState() {
    if (this.instructionsEl) {
      this.instructionsEl.innerHTML = `
        <div class="instructions-content loading">
          <div class="spinner"></div>
          <p>Processing screenshot...</p>
        </div>
      `;
    }
  }

  showInstructions() {
    if (this.instructionsEl) {
      this.instructionsEl.style.display = 'block';
    }
  }

  hideInstructions() {
    if (this.instructionsEl) {
      this.instructionsEl.style.display = 'none';
    }
  }

  hideOverlayForCapture() {
    if (this.overlay) {
      this.overlay.style.opacity = '0';
      this.overlay.style.visibility = 'hidden';
      this.overlay.classList.add('capturing');
    }
    if (this.selectionBox) {
      this.selectionBox.classList.add('capturing');
    }
    if (this.instructionsEl) {
      this.instructionsEl.style.display = 'none';
    }
  }

  showNotification(message, type = 'info') {
    const notification = document.createElement('div');
    notification.className = `screenshot-notification ${type}`;
    notification.textContent = message;

    document.body.appendChild(notification);

    // Auto-remove after delay
    const delay = type === 'error' ? 5000 : 3000;
    setTimeout(() => {
      if (notification.parentNode) {
        notification.style.animation = 'slideOut 0.3s ease-in forwards';
        setTimeout(() => notification.remove(), 300);
      }
    }, delay);
  }

  removeOverlay() {
    if (this.selectionBox) {
      this.selectionBox.classList.remove('visible');
    }
    
    if (this.overlay) {
      this.overlay.classList.add('closing');
      setTimeout(() => {
        if (this.overlay && this.overlay.parentNode) {
          this.overlay.remove();
        }
        this.cleanup();
      }, 200);
    } else {
      this.cleanup();
    }
  }

  cleanup() {
    this.overlay = null;
    this.selectionBox = null;
    this.instructionsEl = null;
    this.selectionInfo = null;
    this.isSelecting = false;

    if (this.keydownHandler) {
      document.removeEventListener('keydown', this.keydownHandler);
      this.keydownHandler = null;
    }
  }
}

// Content script initialization
console.log('Content script loaded and ready');

// Content script message handler
let screenshotSelector = null;

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  console.log('Content script received message:', request);
  
  if (request.action === 'ping') {
    console.log('Received ping, sending pong');
    sendResponse({ success: true, message: 'pong' });
    return true;
  }
  
  if (request.action === 'startCapture') {
    try {
      console.log('Starting capture...');
      
      // Clean up existing selector
      if (screenshotSelector) {
        screenshotSelector.removeOverlay();
      }

      // Create new selector
      screenshotSelector = new ScreenshotSelector();
      screenshotSelector.init();

      console.log('Screenshot selector initialized successfully');
      sendResponse({ success: true });

    } catch (error) {
      console.error('Failed to start capture:', error);
      sendResponse({ success: false, error: error.message });
    }
  }
  
  return true;
});

// Handle page unload
window.addEventListener('beforeunload', () => {
  if (screenshotSelector) {
    screenshotSelector.removeOverlay();
  }
});