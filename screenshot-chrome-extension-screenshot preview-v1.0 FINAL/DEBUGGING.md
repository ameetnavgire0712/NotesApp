# Chrome Extension Debugging Guide

## Step-by-Step Troubleshooting

### 1. Reload the Extension
1. Go to `chrome://extensions/`
2. Find "Screenshot Selector Pro"
3. Click the **refresh/reload** button (circular arrow icon)
4. Try using the extension again

### 2. Check for Errors
1. Go to `chrome://extensions/`
2. Find "Screenshot Selector Pro"
3. Click **"Errors"** if it appears in red
4. Look for any error messages

### 3. Debug the Popup
1. Right-click the extension icon in Chrome toolbar
2. Select **"Inspect popup"**
3. This opens Developer Tools for the popup
4. Click "Select Area" button
5. Check the **Console** tab for any error messages
6. Look for messages starting with "Popup script loaded"

### 4. Debug the Content Script
1. Open any webpage (like google.com)
2. Press **F12** to open Developer Tools
3. Go to **Console** tab
4. Click the extension's "Select Area" button
5. Look for messages like "Content script received message"

### 5. Check Permissions
1. Go to `chrome://extensions/`
2. Find "Screenshot Selector Pro"
3. Click **"Details"**
4. Scroll down to **"Permissions"**
5. Make sure it has:
   - Read and change all your data on all websites
   - Manage your downloads

## Common Issues & Solutions

### Issue 1: Extension Not Loading
**Symptoms:** Extension icon missing or grayed out
**Solutions:**
- Make sure all files are in correct folders
- Reload the extension
- Check for syntax errors in manifest.json

### Issue 2: "No active tab found"
**Symptoms:** Error message when clicking buttons
**Solutions:**
- Make sure you're on a regular webpage (not chrome:// pages)
- Try on google.com or any normal website
- Reload the current tab

### Issue 3: Content Script Not Injecting
**Symptoms:** No overlay appears when clicking "Select Area"
**Solutions:**
- Refresh the webpage after loading the extension
- Check if the website blocks content scripts
- Try on a different website

### Issue 4: Permissions Denied
**Symptoms:** Extension loads but doesn't work
**Solutions:**
- Go to chrome://extensions/
- Click "Details" on your extension
- Make sure "Allow in incognito" is checked if testing in incognito
- Grant all requested permissions

## Testing Steps

1. **Load Extension:**
   ```
   chrome://extensions/ → Enable Developer Mode → Load Unpacked
   ```

2. **Test on Simple Site:**
   - Go to `https://www.google.com`
   - Click extension icon
   - Click "Select Area"
   - Should see dark overlay with instructions

3. **Check Console Messages:**
   - Popup console should show: "Popup script loaded"
   - Page console should show: "Content script received message"

## If Still Not Working

Try this manual test:

1. **Open Developer Console** (F12) on any webpage
2. **Paste this code** in the console:
   ```javascript
   // Test if content script is loaded
   console.log('Testing content script...');
   
   // Try to trigger the screenshot selector manually
   if (typeof chrome !== 'undefined' && chrome.runtime) {
     chrome.runtime.sendMessage({action: 'test'}, (response) => {
       console.log('Extension communication test:', response);
     });
   } else {
     console.log('Chrome extension APIs not available');
   }
   ```

3. **Press Enter** and check for any error messages

## Files to Check

Make sure these files exist and have content:
- ✅ `manifest.json`
- ✅ `src/background.js`
- ✅ `src/content.js`
- ✅ `src/popup/popup.html`
- ✅ `src/popup/popup-test.js`
- ✅ `src/screenshot/screenshot.css`
- ✅ `icons/icon16.png`
- ✅ `icons/icon48.png`
- ✅ `icons/icon128.png`

## Next Steps

If you're still having issues:
1. Follow the debugging steps above
2. Share any error messages you see in the console
3. Let me know which step fails
4. I'll help you fix the specific issue

The extension should work - we just need to identify where the issue is occurring!