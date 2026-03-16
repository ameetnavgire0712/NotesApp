// Simple test script to debug extension issues
console.log('Popup script loaded');

document.addEventListener('DOMContentLoaded', () => {
  console.log('DOM loaded');
  
  const captureBtn = document.getElementById('captureBtn');
  const fullScreenBtn = document.getElementById('fullScreenBtn');
  
  if (!captureBtn || !fullScreenBtn) {
    console.error('Buttons not found!');
    return;
  }
  
  console.log('Buttons found, attaching listeners');
  
  captureBtn.addEventListener('click', async () => {
    console.log('Capture button clicked');
    
    try {
      // Test if we can get active tab
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      console.log('Active tab:', tab);
      
      if (!tab) {
        console.error('No active tab found');
        alert('No active tab found');
        return;
      }
      
      // Check if tab URL is supported
      if (tab.url.startsWith('chrome://') || tab.url.startsWith('chrome-extension://') || tab.url.startsWith('edge://') || tab.url.startsWith('about:')) {
        alert('Cannot capture screenshots on this page. Please navigate to a regular website (like google.com) and try again.');
        return;
      }
      
      try {
        // First try to send message to existing content script
        console.log('Sending message to content script...');
        const response = await chrome.tabs.sendMessage(tab.id, { action: 'startCapture' });
        console.log('Response from content script:', response);
        
        if (response && response.success) {
          console.log('Success! Closing popup...');
          setTimeout(() => window.close(), 500);
          return;
        }
      } catch (msgError) {
        console.log('Content script not available, injecting manually...');
        
        // If content script not available, inject it manually
        try {
          await chrome.scripting.executeScript({
            target: { tabId: tab.id },
            files: ['src/content.js']
          });
          
          await chrome.scripting.insertCSS({
            target: { tabId: tab.id },
            files: ['src/screenshot/screenshot.css']
          });
          
          console.log('Scripts injected, trying again...');
          
          // Wait a bit for scripts to load
          setTimeout(async () => {
            try {
              const response = await chrome.tabs.sendMessage(tab.id, { action: 'startCapture' });
              console.log('Response after injection:', response);
              
              if (response && response.success) {
                console.log('Success after injection! Closing popup...');
                setTimeout(() => window.close(), 500);
              } else {
                alert('Failed to start capture after injection: ' + (response?.error || 'Unknown error'));
              }
            } catch (error) {
              console.error('Error after injection:', error);
              alert('Still unable to communicate with content script: ' + error.message);
            }
          }, 1000);
          
        } catch (injectionError) {
          console.error('Failed to inject scripts:', injectionError);
          alert('Failed to inject content script: ' + injectionError.message + '\n\nTry refreshing the page and loading the extension again.');
        }
      }
      
    } catch (error) {
      console.error('Error in capture handler:', error);
      alert('Error: ' + error.message);
    }
  });
  
  fullScreenBtn.addEventListener('click', () => {
    console.log('Full screen button clicked');
    alert('Full screen capture - feature coming soon!');
  });
});

// Test if chrome APIs are available
console.log('Chrome APIs available:', {
  tabs: !!chrome.tabs,
  runtime: !!chrome.runtime,
  storage: !!chrome.storage,
  downloads: !!chrome.downloads
});