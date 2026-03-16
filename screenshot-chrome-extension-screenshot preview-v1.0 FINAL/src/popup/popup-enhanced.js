// Enhanced popup test script with better error handling
console.log('Enhanced popup script loaded');

document.addEventListener('DOMContentLoaded', () => {
  console.log('DOM loaded');
  
  const captureBtn = document.getElementById('captureBtn');
  const uploadBtn = document.getElementById('uploadBtn');
  const fileInput = document.getElementById('fileInput');
  const previewSection = document.getElementById('previewSection');
  const previewImage = document.getElementById('previewImage');
  const previewDimensions = document.getElementById('previewDimensions');
  const previewSize = document.getElementById('previewSize');
  const saveBtn = document.getElementById('saveBtn');
  const retakeBtn = document.getElementById('retakeBtn');
  const cancelBtn = document.getElementById('cancelBtn');
  const primarySection = document.querySelector('.primary-section');
  const uploadSection = document.querySelector('.upload-section');
  const notesBtn = document.getElementById('notesBtn');
  const notesSection = document.querySelector('.notes-section');
  const notesEditorSection = document.getElementById('notesEditorSection');
  const notesTextarea = document.getElementById('notesTextarea');
  const resizeNotesBtn = document.getElementById('resizeNotesBtn');
  const saveNotesBtn = document.getElementById('saveNotesBtn');
  const cancelNotesBtn = document.getElementById('cancelNotesBtn');
  const screenshotCategorySelect = document.getElementById('screenshotCategorySelect');
  const screenshotCategoryInput = document.getElementById('screenshotCategoryInput');
  const notesCategorySelect = document.getElementById('notesCategorySelect');
  const notesCategoryInput = document.getElementById('notesCategoryInput');
  const fileCategorySelect = document.getElementById('fileCategorySelect');
  const fileCategoryInput = document.getElementById('fileCategoryInput');
  const fileUploadCategorySection = document.getElementById('fileUploadCategorySection');
  const confirmFileUploadBtn = document.getElementById('confirmFileUploadBtn');
  const cancelFileUploadBtn = document.getElementById('cancelFileUploadBtn');
  
  let selectedFile = null;
  let isProcessingSave = false;
  
  console.log('Buttons found, attaching listeners', {
    captureBtn: !!captureBtn,
    uploadBtn: !!uploadBtn,
    notesBtn: !!notesBtn
  });
  
  if (!captureBtn) {
    console.error('Capture button not found!');
    // Don't return early - let other buttons work
  }
  
  // Initialize popup in capture mode
  document.body.className = 'capture-mode';
  
  // Load and populate categories
  loadCategories();
  
  // Check for existing preview on load
  checkForPreview();
  
  // Category management functions
  async function loadCategories() {
    try {
      const result = await chrome.storage.sync.get(['categories']);
      const categories = result.categories || [];
      populateCategoryDropdowns(categories);
    } catch (error) {
      console.error('Error loading categories:', error);
    }
  }

  function populateCategoryDropdowns(categories) {
    const selects = [screenshotCategorySelect, notesCategorySelect, fileCategorySelect];
    
    selects.forEach(select => {
      if (!select) return;
      
      // Clear existing options except the first two (placeholder and add new)
      while (select.options.length > 2) {
        select.remove(2);
      }
      
      // Add saved categories
      categories.forEach(category => {
        const option = document.createElement('option');
        option.value = category;
        option.textContent = category;
        select.appendChild(option);
      });
    });
  }

  async function addCategory(categoryName) {
    if (!categoryName || !categoryName.trim()) {
      return false;
    }
    
    const category = categoryName.trim();
    
    try {
      const result = await chrome.storage.sync.get(['categories']);
      const categories = result.categories || [];
      
      // Check if category already exists
      if (!categories.includes(category)) {
        categories.push(category);
        await chrome.storage.sync.set({ categories: categories });
        populateCategoryDropdowns(categories);
      }
      
      return category;
    } catch (error) {
      console.error('Error adding category:', error);
      return false;
    }
  }

  function setupCategoryHandlers(select, input) {
    if (!select || !input) return;
    
    select.addEventListener('change', () => {
      if (select.value === '__add_new__') {
        input.classList.remove('hidden');
        input.focus();
        // Don't reset select.value here - keep it as '__add_new__' so we can detect it
      } else if (select.value) {
        // A category was selected, hide input
        input.classList.add('hidden');
        input.value = '';
      } else {
        // Empty selection, hide input
        input.classList.add('hidden');
        input.value = '';
      }
    });
    
    input.addEventListener('keypress', async (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        const category = await addCategory(input.value);
        if (category) {
          select.value = category;
          input.classList.add('hidden');
          input.value = '';
        }
      }
    });
    
    input.addEventListener('blur', async (e) => {
      // Don't process blur if we're processing a save action
      if (isProcessingSave) {
        return;
      }
      
      // Small delay to check if user clicked a button
      setTimeout(async () => {
        if (isProcessingSave) {
          return;
        }
        
        if (input.value.trim()) {
          const category = await addCategory(input.value);
          if (category) {
            select.value = category;
            input.classList.add('hidden');
            input.value = '';
          }
        } else {
          // If input is empty, reset select to empty
          if (select.value === '__add_new__') {
            select.value = '';
          }
          input.classList.add('hidden');
        }
      }, 100);
    });
  }

  // Setup category handlers for all three sections
  setupCategoryHandlers(screenshotCategorySelect, screenshotCategoryInput);
  setupCategoryHandlers(notesCategorySelect, notesCategoryInput);
  setupCategoryHandlers(fileCategorySelect, fileCategoryInput);
  
  // Preview handling functions
  async function checkForPreview() {
    try {
      const result = await chrome.storage.local.get(['preview_screenshot']);
      if (result.preview_screenshot) {
        const previewData = result.preview_screenshot;
        showPreview(previewData.dataUrl, previewData.dimensions);
      }
    } catch (error) {
      console.error('Error checking for preview:', error);
    }
  }
  
  function showPreview(dataUrl, dimensions) {
    // Set preview image
    previewImage.src = dataUrl;
    
    // Set dimensions info
    previewDimensions.textContent = `${dimensions.width} × ${dimensions.height}px`;
    
    // Calculate and show file size
    const sizeInBytes = Math.round((dataUrl.length - 'data:image/png;base64,'.length) * 3/4);
    const sizeInKB = Math.round(sizeInBytes / 1024);
    previewSize.textContent = `${sizeInKB} KB`;
    
    // Switch to preview mode (larger size)
    document.body.className = 'preview-mode';
    
    // Show preview section, hide main sections
    previewSection.classList.remove('hidden');
    primarySection.style.display = 'none';
    
    // Hide upload section when preview is shown
    if (uploadSection) {
      uploadSection.style.display = 'none';
    }
    
    // Reset category selection
    if (screenshotCategorySelect) {
      screenshotCategorySelect.value = '';
    }
    if (screenshotCategoryInput) {
      screenshotCategoryInput.value = '';
      screenshotCategoryInput.classList.add('hidden');
    }
    
    // Reload categories to ensure dropdown is up to date
    loadCategories();
    
    console.log('Preview shown with dimensions:', dimensions);
  }
  
  function hidePreview() {
    // Switch back to capture mode (smaller size)
    document.body.className = 'capture-mode';
    
    // Hide preview section, show main sections
    previewSection.classList.add('hidden');
    primarySection.style.display = 'flex';
    
    // Show upload section again
    if (uploadSection) {
      uploadSection.style.display = 'flex';
    }
    
    // Clear preview data
    chrome.storage.local.remove(['preview_screenshot']);
    
    console.log('Preview hidden, returned to capture mode');
  }
  
  // Helper function to get category value (checks both select and input)
  async function getCategoryValue(select, input) {
    if (!select) return '';
    
    // Check if input is visible and has a value (user is adding new category)
    if (input && !input.classList.contains('hidden') && input.value.trim()) {
      const categoryName = input.value.trim();
      const newCategory = await addCategory(categoryName);
      if (newCategory) {
        select.value = newCategory;
        input.classList.add('hidden');
        input.value = '';
        return newCategory;
      }
      return ''; // Failed to add category
    }
    
    // If "__add_new__" is selected but input is empty or hidden, return empty
    if (select.value === '__add_new__') {
      return '';
    }
    
    // Return the selected category value
    return select.value || '';
  }

  // Save button handler
  if (saveBtn) {
    saveBtn.addEventListener('click', async (e) => {
      e.preventDefault();
      e.stopPropagation();
      
      isProcessingSave = true;
      try {
        const result = await chrome.storage.local.get(['preview_screenshot']);
        if (result.preview_screenshot) {
          // Get selected category (check input if visible)
          const category = await getCategoryValue(screenshotCategorySelect, screenshotCategoryInput);
          if (!category || category === '__add_new__') {
            showStatusMessage('⚠️ Please select or add a category before saving.', 'warning');
            return;
          }
          
          const filename = `screenshot-${new Date().toISOString().slice(0, 19).replace(/:/g, '-')}.png`;
          
          const response = await chrome.runtime.sendMessage({
            action: 'downloadImage',
            dataUrl: result.preview_screenshot.dataUrl,
            filename: filename
          });
          
          if (response.success) {
            // Save screenshot metadata with category
            const screenshotData = {
              filename: filename,
              category: category,
              createdAt: new Date().toISOString(),
              type: 'screenshot'
            };
            
            const savedScreenshots = (await chrome.storage.local.get(['saved_screenshots'])).saved_screenshots || [];
            savedScreenshots.push(screenshotData);
            await chrome.storage.local.set({ saved_screenshots: savedScreenshots });
            
            showStatusMessage('Screenshot saved successfully! 🎉', 'success');
            setTimeout(() => hidePreview(), 1500);
          } else {
            showStatusMessage('Failed to save screenshot: ' + response.error, 'error');
          }
        }
      } catch (error) {
        console.error('Error saving screenshot:', error);
        showStatusMessage('Error saving screenshot: ' + error.message, 'error');
      } finally {
        setTimeout(() => {
          isProcessingSave = false;
        }, 200);
      }
    });
  }
  
  // Retake button handler
  if (retakeBtn) {
    retakeBtn.addEventListener('click', () => {
      hidePreview();
    });
  }

  // Cancel button handler
  if (cancelBtn) {
    cancelBtn.addEventListener('click', () => {
      hidePreview();
    });
  }

  // Notes functionality
  function showNotesEditor() {
    // Hide homepage sections
    if (primarySection) {
      primarySection.style.display = 'none';
    }
    if (uploadSection) {
      uploadSection.style.display = 'none';
    }
    if (notesSection) {
      notesSection.style.display = 'none';
    }
    
    // Show notes editor
    if (notesEditorSection) {
      notesEditorSection.classList.remove('hidden');
    }
    
    // Reload categories to ensure dropdown is up to date
    loadCategories();
    
    // Focus on textarea
    if (notesTextarea) {
      setTimeout(() => notesTextarea.focus(), 100);
    }
  }

  function hideNotesEditor() {
    // Hide notes editor
    if (notesEditorSection) {
      notesEditorSection.classList.add('hidden');
    }
    
    // Show homepage sections
    if (primarySection) {
      primarySection.style.display = 'flex';
    }
    if (uploadSection) {
      uploadSection.style.display = 'flex';
    }
    if (notesSection) {
      notesSection.style.display = 'flex';
    }
    
    // Clear textarea and category
    if (notesTextarea) {
      notesTextarea.value = '';
      notesTextarea.classList.remove('expanded');
    }
    if (notesCategorySelect) {
      notesCategorySelect.value = '';
    }
    if (notesCategoryInput) {
      notesCategoryInput.value = '';
      notesCategoryInput.classList.add('hidden');
    }
  }

  // Take Notes button handler
  if (notesBtn) {
    notesBtn.addEventListener('click', () => {
      showNotesEditor();
    });
  }

  // Resize notes textarea button handler
  if (resizeNotesBtn && notesTextarea) {
    resizeNotesBtn.addEventListener('click', () => {
      notesTextarea.classList.toggle('expanded');
      if (notesTextarea.classList.contains('expanded')) {
        resizeNotesBtn.title = 'Make smaller';
      } else {
        resizeNotesBtn.title = 'Make larger';
      }
    });
  }

  // Save notes button handler
  if (saveNotesBtn && notesTextarea) {
    saveNotesBtn.addEventListener('click', async (e) => {
      e.preventDefault();
      e.stopPropagation();
      
      isProcessingSave = true;
      try {
        const notesContent = notesTextarea.value.trim();
        
        if (!notesContent) {
          showStatusMessage('⚠️ Please enter some notes before saving.', 'warning');
          return;
        }
        
        // Get selected category (check input if visible)
        const category = await getCategoryValue(notesCategorySelect, notesCategoryInput);
        if (!category || category === '__add_new__') {
          showStatusMessage('⚠️ Please select or add a category before saving.', 'warning');
          return;
        }
        
        // Save notes to storage
        const noteData = {
          content: notesContent,
          category: category,
          createdAt: new Date().toISOString(),
          type: 'note'
        };
        
        // Get existing notes or create new array
        const result = await chrome.storage.local.get(['saved_notes']);
        const savedNotes = result.saved_notes || [];
        savedNotes.push(noteData);
        
        // Save updated notes array
        await chrome.storage.local.set({ saved_notes: savedNotes });
        
        showStatusMessage('✅ Notes saved successfully!', 'success');
        setTimeout(() => {
          hideNotesEditor();
        }, 1000);
      } catch (error) {
        console.error('Error saving notes:', error);
        showStatusMessage('❌ Error saving notes: ' + error.message, 'error');
      } finally {
        setTimeout(() => {
          isProcessingSave = false;
        }, 200);
      }
    });
  }

  // Cancel notes button handler
  if (cancelNotesBtn) {
    cancelNotesBtn.addEventListener('click', () => {
      hideNotesEditor();
    });
  }
  
  function showStatusMessage(message, type) {
    const statusMessage = document.getElementById('statusMessage');
    if (statusMessage) {
      statusMessage.textContent = message;
      statusMessage.className = `status-message ${type}`;
      statusMessage.classList.remove('hidden');
      
      setTimeout(() => {
        statusMessage.classList.add('hidden');
      }, 3000);
    }
  }
  
  // Function to test content script communication
  async function testContentScript(tabId) {
    try {
      console.log('Testing content script with ping...');
      const pingResponse = await chrome.tabs.sendMessage(tabId, { action: 'ping' });
      console.log('Ping response:', pingResponse);
      return pingResponse && pingResponse.success;
    } catch (error) {
      console.log('Ping failed:', error.message);
      return false;
    }
  }
  
  // Function to inject content script manually
  async function injectContentScript(tabId) {
    try {
      console.log('Injecting content script manually...');
      
      // Inject JavaScript
      await chrome.scripting.executeScript({
        target: { tabId: tabId },
        files: ['src/content.js']
      });
      
      // Inject CSS
      await chrome.scripting.insertCSS({
        target: { tabId: tabId },
        files: ['src/screenshot/screenshot.css']
      });
      
      console.log('Scripts injected successfully');
      
      // Wait for script to initialize
      await new Promise(resolve => setTimeout(resolve, 500));
      
      return true;
    } catch (error) {
      console.error('Failed to inject scripts:', error);
      throw error;
    }
  }
  
  if (captureBtn) {
    captureBtn.addEventListener('click', async () => {
      console.log('Capture button clicked');
      
      try {
        // Get active tab
        const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
        console.log('Active tab:', tab);
        
        if (!tab) {
          alert('❌ No active tab found');
          return;
        }
        
        // Check if tab URL is supported
        if (tab.url.startsWith('chrome://') || tab.url.startsWith('chrome-extension://') || 
            tab.url.startsWith('edge://') || tab.url.startsWith('about:')) {
          alert('⚠️ Cannot capture screenshots on this page.\n\n📝 Please try on:\n• google.com\n• Any regular website\n\n❌ Avoid:\n• chrome:// pages\n• Extension pages');
          return;
        }
        
        console.log('Testing content script communication...');
        
        // Test if content script is available
        let contentScriptReady = await testContentScript(tab.id);
        
        if (!contentScriptReady) {
          console.log('Content script not ready, attempting injection...');
          
          try {
            await injectContentScript(tab.id);
            contentScriptReady = await testContentScript(tab.id);
          } catch (injectionError) {
            alert('❌ Failed to load screenshot functionality:\n\n' + injectionError.message + 
                  '\n\n🔄 Try:\n1. Refresh this webpage\n2. Reload the extension\n3. Try on google.com');
            return;
          }
        }
        
        if (!contentScriptReady) {
          alert('❌ Screenshot functionality not available.\n\n🔄 Try:\n1. Refresh this webpage\n2. Reload the extension');
          return;
        }
        
        console.log('Content script ready, starting capture...');
        
        // Start capture
        const response = await chrome.tabs.sendMessage(tab.id, { action: 'startCapture' });
        console.log('Capture response:', response);
        
        if (response && response.success) {
          console.log('✅ Screenshot tool started successfully');
          // Hide upload section when screenshot capture starts
          if (uploadSection) {
            uploadSection.style.display = 'none';
          }
          // Close popup after a short delay
          setTimeout(() => window.close(), 300);
        } else {
          alert('❌ Failed to start screenshot tool:\n' + (response?.error || 'Unknown error'));
        }
        
      } catch (error) {
        console.error('Error in capture handler:', error);
        alert('❌ Error starting screenshot:\n\n' + error.message + 
              '\n\n🔄 Try refreshing the page and trying again.');
      }
    });
  }
  
  // File upload handling
  if (uploadBtn && fileInput) {
    // Trigger file input when upload button is clicked
    uploadBtn.addEventListener('click', () => {
      fileInput.click();
    });

    // Handle file selection
    fileInput.addEventListener('change', (event) => {
      const file = event.target.files[0];
      if (file) {
        handleFileSelection(file);
      }
    });
  }

  // File selection handler with validation
  function handleFileSelection(file) {
    // Get file extension
    const fileName = file.name.toLowerCase();
    const fileExtension = fileName.substring(fileName.lastIndexOf('.'));
    
    // Allowed file types
    const allowedExtensions = ['.txt', '.xlsx', '.xls'];
    
    // Validate file type
    if (!allowedExtensions.includes(fileExtension)) {
      showStatusMessage(`❌ Invalid file type. Please upload only .txt, .xlsx, or .xls files.`, 'error');
      fileInput.value = '';
      return;
    }

    // Validate file size (optional - limit to 10MB)
    const maxSize = 10 * 1024 * 1024; // 10MB
    if (file.size > maxSize) {
      showStatusMessage(`❌ File is too large. Maximum size is 10MB.`, 'error');
      fileInput.value = '';
      return;
    }

    // File is valid, store it and show category section
    selectedFile = file;
    
    // Hide all homepage sections, show category section
    if (uploadSection) {
      uploadSection.style.display = 'none';
    }
    if (primarySection) {
      primarySection.style.display = 'none';
    }
    if (notesSection) {
      notesSection.style.display = 'none';
    }
    if (fileUploadCategorySection) {
      fileUploadCategorySection.classList.remove('hidden');
    }
    
    // Reload categories to ensure dropdown is up to date
    loadCategories();
    
    showStatusMessage(`✅ File "${file.name}" selected. Please choose a category.`, 'success');
  }

  // Confirm file upload button handler
  if (confirmFileUploadBtn) {
    confirmFileUploadBtn.addEventListener('click', async (e) => {
      e.preventDefault();
      e.stopPropagation();
      
      isProcessingSave = true;
      try {
        if (!selectedFile) {
          showStatusMessage('❌ No file selected.', 'error');
          return;
        }
        
        // Get selected category (check input if visible)
        const category = await getCategoryValue(fileCategorySelect, fileCategoryInput);
        if (!category || category === '__add_new__') {
          showStatusMessage('⚠️ Please select or add a category before uploading.', 'warning');
          return;
        }
        
        const fileName = selectedFile.name.toLowerCase();
        const fileExtension = fileName.substring(fileName.lastIndexOf('.'));
        
        const fileData = {
          name: selectedFile.name,
          size: selectedFile.size,
          type: fileExtension === '.txt' ? 'text' : 'excel',
          extension: fileExtension,
          category: category,
          uploadedAt: new Date().toISOString()
        };
        
        // Read file content for text files
        if (fileExtension === '.txt') {
          const reader = new FileReader();
          reader.onload = async (e) => {
            fileData.content = e.target.result;
            await saveFileData(fileData);
          };
          reader.readAsText(selectedFile);
        } else {
          await saveFileData(fileData);
        }
      } catch (error) {
        console.error('Error uploading file:', error);
        showStatusMessage('❌ Error uploading file: ' + error.message, 'error');
      } finally {
        setTimeout(() => {
          isProcessingSave = false;
        }, 200);
      }
    });
  }

  async function saveFileData(fileData) {
    try {
      const result = await chrome.storage.local.get(['uploaded_files']);
      const uploadedFiles = result.uploaded_files || [];
      uploadedFiles.push(fileData);
      await chrome.storage.local.set({ uploaded_files: uploadedFiles });
      
      showStatusMessage(`✅ File "${fileData.name}" uploaded successfully!`, 'success');
      
      // Reset and return to homepage
      selectedFile = null;
      fileInput.value = '';
      if (fileCategorySelect) {
        fileCategorySelect.value = '';
      }
      if (fileCategoryInput) {
        fileCategoryInput.value = '';
        fileCategoryInput.classList.add('hidden');
      }
      
      setTimeout(() => {
        if (fileUploadCategorySection) {
          fileUploadCategorySection.classList.add('hidden');
        }
        // Show all homepage sections
        if (uploadSection) {
          uploadSection.style.display = 'flex';
        }
        if (primarySection) {
          primarySection.style.display = 'flex';
        }
        if (notesSection) {
          notesSection.style.display = 'flex';
        }
      }, 1500);
    } catch (error) {
      throw error;
    }
  }

  // Cancel file upload button handler
  if (cancelFileUploadBtn) {
    cancelFileUploadBtn.addEventListener('click', () => {
      selectedFile = null;
      fileInput.value = '';
      if (fileCategorySelect) {
        fileCategorySelect.value = '';
      }
      if (fileCategoryInput) {
        fileCategoryInput.value = '';
        fileCategoryInput.classList.add('hidden');
      }
      if (fileUploadCategorySection) {
        fileUploadCategorySection.classList.add('hidden');
      }
      // Show all homepage sections
      if (uploadSection) {
        uploadSection.style.display = 'flex';
      }
      if (primarySection) {
        primarySection.style.display = 'flex';
      }
      if (notesSection) {
        notesSection.style.display = 'flex';
      }
    });
  }

  // Listen for storage changes (new preview available)
  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName === 'local' && changes.preview_screenshot) {
      const newValue = changes.preview_screenshot.newValue;
      if (newValue) {
        showPreview(newValue.dataUrl, newValue.dimensions);
      }
    }
    
    // Listen for category changes (sync across devices)
    if (areaName === 'sync' && changes.categories) {
      const newCategories = changes.categories.newValue || [];
      populateCategoryDropdowns(newCategories);
      console.log('Categories synced from another device:', newCategories);
    }
  });
});

// Test chrome APIs availability
console.log('Chrome APIs check:', {
  tabs: !!chrome?.tabs,
  runtime: !!chrome?.runtime,
  scripting: !!chrome?.scripting,
  storage: !!chrome?.storage
});

// Add error listener for unhandled errors
window.addEventListener('error', (event) => {
  console.error('Unhandled error in popup:', event.error);
});

console.log('Popup script setup complete');