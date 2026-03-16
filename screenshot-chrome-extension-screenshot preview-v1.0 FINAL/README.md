# Screenshot Selector Pro - Chrome Extension

A professional Chrome extension for taking precise screenshots with area selection capabilities. Screenshots are automatically saved to your local Downloads folder.

## 🚀 Features

- **🎯 Precise Area Selection**: Click and drag to select specific screen areas
- **🖥️ Full Screen Capture**: One-click full viewport screenshots  
- **💾 Auto-Save to C Drive**: Screenshots automatically save to Downloads folder
- **⚡ High Performance**: Optimized for speed and quality
- **🎨 Professional UI**: Clean, modern interface
- **⌨️ Keyboard Shortcuts**: ESC to cancel, Enter for full screen
- **📱 High DPI Support**: Perfect quality on all screen types
- **🔒 Privacy First**: No data collection, works offline

## 📁 Project Structure

```
screenshot-chrome-extension/
├── manifest.json           # Extension configuration
├── src/
│   ├── background.js      # Background service worker
│   ├── content.js         # Content script for UI overlay
│   ├── popup/             # Extension popup interface
│   │   ├── popup.html
│   │   ├── popup.js
│   │   └── popup.css
│   └── screenshot/        # Screenshot-specific styles
│       └── screenshot.css
├── icons/                 # Extension icons (need to be added)
│   ├── icon16.png
│   ├── icon48.png
│   └── icon128.png
└── README.md
```

## 🛠️ Installation & Setup

### Step 1: Prepare Icons
You need to create three icon files in the `icons/` folder:
- `icon16.png` (16x16 pixels)
- `icon48.png` (48x48 pixels) 
- `icon128.png` (128x128 pixels)

### Step 2: Load Extension in Chrome

1. **Open Chrome Extensions Page**
   - Go to `chrome://extensions/`
   - Or: Chrome Menu → More Tools → Extensions

2. **Enable Developer Mode**
   - Toggle "Developer mode" in the top-right corner

3. **Load the Extension**
   - Click "Load unpacked"
   - Select the `screenshot-chrome-extension` folder
   - The extension should now appear in your extensions list

4. **Pin the Extension** (Optional)
   - Click the puzzle piece icon in Chrome toolbar
   - Click the pin icon next to "Screenshot Selector Pro"

## 🎮 Usage

### Method 1: Extension Popup
1. Click the extension icon in your toolbar
2. Click "Select Area" or "Full Screen"
3. For area selection: drag to select your desired area
4. Screenshot automatically saves to Downloads folder

### Method 2: Keyboard Shortcuts (when overlay is active)
- **ESC**: Cancel current selection
- **Enter**: Capture full screen

## 💾 Save Location

Screenshots are automatically saved to:
```
C:\Users\[YourUsername]\Downloads\
```

Files are named with timestamp format:
```
screenshot-YYYY-MM-DDTHH-MM-SS.png
```

## 🔧 Troubleshooting

### Common Issues

**Extension not working on some pages**
- Chrome extensions cannot capture chrome:// pages
- Some sites may block extension functionality

**Screenshots appear blurry**
- This is usually due to high DPI displays
- The extension automatically handles pixel ratio scaling

**Downloads not working**
- Check Chrome's download permissions
- Ensure Downloads folder is accessible

**Selection area not showing**
- Try refreshing the page
- Check if the page allows content scripts

### Error Messages

**"Cannot capture screenshots on this page"**
- You're on a restricted page (chrome://, chrome-extension://, etc.)
- Navigate to a regular webpage

**"No active tab found"**
- Make sure you have an active tab open
- Try clicking the extension icon again

## 🚧 Development

### Prerequisites
- Chrome Browser (version 88+)
- Basic knowledge of JavaScript, HTML, CSS

### Making Changes
1. Edit the source files
2. Go to `chrome://extensions/`
3. Click the refresh icon on your extension
4. Test your changes

### Debugging
- **Popup**: Right-click extension icon → "Inspect popup"
- **Content Script**: F12 on webpage → Console tab
- **Background Script**: `chrome://extensions/` → Click "Errors"

## 📋 Permissions

This extension requires:
- **activeTab**: To capture screenshots of the current tab
- **downloads**: To save screenshots to your computer
- **storage**: To store user preferences and statistics
- **scripting**: To inject the selection overlay

## 🔐 Privacy

- ✅ No data is collected or transmitted
- ✅ Screenshots are processed locally
- ✅ No external servers or APIs used
- ✅ All data remains on your device

## 🌐 Browser Compatibility

- ✅ Chrome 88+
- ✅ Edge 88+
- ✅ Brave
- ✅ Other Chromium-based browsers

## 📝 License

MIT License - Feel free to modify and distribute

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📞 Support

If you encounter any issues:
1. Check the troubleshooting section above
2. Refresh the extension and try again
3. Check the browser console for error messages

## ⚡ Performance Tips

- Close unused tabs for better performance
- Use area selection instead of full screen when possible
- Clear browser cache if experiencing issues

---

**Enjoy taking perfect screenshots! 📸**