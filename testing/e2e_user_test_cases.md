# End-to-End User Test Cases

These test cases are designed from an **end user perspective**, mimicking real user behavior through the Chrome extension and web dashboard. Each test describes what the user does and what they should see.

---

## 1. First-Time User Setup

### 1.1 Install Extension & First Login

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Install extension from Chrome Web Store | Extension icon appears in toolbar | - |
| 2 | Click extension icon | Popup opens showing "Sign In" button | - |
| 3 | Click "Sign In with Google" | Google OAuth popup opens | Supabase Auth |
| 4 | Complete Google login | Popup shows "Welcome! Setting up..." then main interface | User created in DB |
| 5 | Check extension popup | Shows user email, "Upload", "Screenshot", "Notes" tabs | Auth token stored |

### 1.2 First Login via Web Dashboard

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Navigate to `https://notesapp.pages.dev` | Landing page with "Sign In" button | Cloudflare Pages |
| 2 | Click "Sign In with Google" | Google OAuth flow | Supabase Auth |
| 3 | Complete login | Redirects to dashboard, shows empty state: "No notes yet" | JWT validation |
| 4 | Check sidebar | Shows "Your Notes", "Search", "Activity Logs", "Settings" | - |

---

## 2. File Upload Tests (via Extension)

### 2.1 Upload PDF Document

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Click extension icon | Popup opens on "Upload" tab | - |
| 2 | Click "Choose File" button | File picker opens | - |
| 3 | Select a PDF file (e.g., `resume.pdf`) | Filename appears: "resume.pdf (245 KB)" | - |
| 4 | Enter tag: "personal" | Tag input shows "personal" | - |
| 5 | Click "Upload" button | Button changes to "Uploading..." with spinner | POST /upload/file |
| 6 | Wait 2-3 seconds | Progress: "Processing document..." | TensorLake conversion |
| 7 | Wait 5-10 seconds | Progress: "Generating embeddings..." | Vectorization |
| 8 | Upload completes | Green checkmark ✓ "Upload complete!" | Note saved to DB |
| 9 | Click "View" link | New tab opens showing the PDF content | Azure SAS URL |

### 2.2 Upload Text File (Fast Path)

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Select a `.txt` file | Filename shown | - |
| 2 | Leave tag empty | Tag shows placeholder "General" | Default tag logic |
| 3 | Click "Upload" | Uploading spinner | POST /upload/file |
| 4 | Wait 1-2 seconds | ✓ "Upload complete!" (faster than PDF) | Direct text read, skip TensorLake |

### 2.3 Upload Code File

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Select a `.py` or `.js` file | Filename: "app.py (12 KB)" | - |
| 2 | Enter tag: "code" | - | - |
| 3 | Click "Upload" | ✓ Completes in 1-2 seconds | Code file handling |

### 2.4 Upload Word Document

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Select a `.docx` file | Filename shown | - |
| 2 | Click "Upload" | Progress: "Converting document..." | TensorLake DOCX conversion |
| 3 | Wait 5-15 seconds | ✓ "Upload complete!" | Full pipeline |

### 2.5 Upload Failure - File Too Large

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Select a file > 20 MB | Filename shown with size | - |
| 2 | Click "Upload" | ❌ Red error: "File too large. Maximum size is 20 MB." | 413 error handling |

### 2.6 Upload Failure - Empty File

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Select a 0-byte file | Filename: "empty.txt (0 KB)" | - |
| 2 | Click "Upload" | ❌ Red error: "File is empty" | 400 validation |

### 2.7 Cancel Upload Mid-Progress

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Upload a large PDF | Progress: "Processing..." | - |
| 2 | Click "Cancel" button | ⚠️ "Upload cancelled" | POST /upload/cancel |
| 3 | Check dashboard | Document does NOT appear in notes list | Cleanup logic |

### 2.8 Storage Quota - Limit Reached

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | User has 100MB of files already uploaded | - | Storage at limit |
| 2 | Try to upload any file | Click "Upload" | - |
| 3 | Wait 1-2 seconds | Modal popup appears: "📦 Storage Limit Reached" | 413 STORAGE_LIMIT_REACHED |
| 4 | Modal shows | "You've utilized your limit of 100MB storage" | - |
| 5 | Modal shows usage bar | Progress bar showing 100% full (red/orange gradient) | - |
| 6 | Modal shows hint | "Please login to the dashboard and delete some files..." | - |
| 7 | Click "Dismiss" | Modal closes, user stays on extension | - |
| 8 | Or click "Go to Dashboard" | Opens dashboard in new tab | chrome.tabs.create |

### 2.9 Storage Quota - Insufficient Space for File

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | User has 95MB used (5MB remaining) | - | Some space available |
| 2 | Try to upload a 10MB file | Click "Upload" | - |
| 3 | Wait 1-2 seconds | Modal popup appears: "📦 Not Enough Space!" | 413 INSUFFICIENT_STORAGE |
| 4 | Modal shows | "You only have 5MB remaining, but this file requires more space" | - |
| 5 | Modal shows usage bar | Progress bar showing 95% full | - |
| 6 | User goes to dashboard | Deletes 10MB of old files | - |
| 7 | Returns to extension | Upload succeeds | Space freed up |

### 2.10 Check Storage Quota

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Go to dashboard → Activity Logs | Activity page loads | - |
| 2 | Find "Storage Quota" section | Shows storage usage card | GET /upload/quota |
| 3 | See usage | "45.2MB / 100MB used" with progress bar | - |
| 4 | See remaining | "54.8MB remaining" | Calculated from limit |

---

## 3. Screenshot Capture Tests (via Extension)

### 3.1 Capture Full Page Screenshot

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Navigate to any webpage (e.g., Wikipedia article) | Page loads | - |
| 2 | Click extension icon | Popup opens | - |
| 3 | Click "Screenshot" tab | Shows capture options | - |
| 4 | Click "Capture Full Page" (or press Enter) | Screen flashes, popup shows "Capturing..." | Chrome screenshot API |
| 5 | Wait 1-2 seconds | Preview of screenshot shown | - |
| 6 | Click "Save" | ✓ "Screenshot saved!" | POST /upload/screenshot |
| 7 | Check dashboard | Screenshot appears with title from page URL, tag "Screenshots" | Default screenshot tag |

### 3.2 Capture Selected Area

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Click "Capture Area" | Popup minimizes, crosshair cursor appears on page | - |
| 2 | Click and drag to select region | Selection rectangle with blue border | - |
| 3 | Release mouse | Preview shows cropped area | Image cropping |
| 4 | Enter custom tag: "diagrams" | - | - |
| 5 | Click "Save" | ✓ Saved with custom tag | Tag handling |

### 3.3 Cancel Screenshot

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Start area selection | Crosshair active | - |
| 2 | Press Escape key | Selection cancelled, returns to normal | - |
| 3 | Check dashboard | No new screenshot added | No upload triggered |

---

## 4. Quick Notes Tests (via Extension)

### 4.1 Create Quick Note with Title

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Click extension → "Notes" tab | Note editor opens | - |
| 2 | Enter title: "Meeting Notes" | Title field populated | - |
| 3 | Enter content: "Discussed Q1 roadmap..." | Content field populated | - |
| 4 | Enter tag: "work" | - | - |
| 5 | Click "Save Note" | ✓ "Note saved!" | POST /upload/note |
| 6 | Check dashboard | Note appears with title "Meeting Notes", tag "work" | Markdown formatting |

### 4.2 Create Quick Note without Title

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Leave title empty | - | - |
| 2 | Enter content: "Remember to call mom" | - | - |
| 3 | Leave tag empty | Shows "Quick Notes" placeholder | Default tag |
| 4 | Click "Save Note" | ✓ Saved | - |
| 5 | Check dashboard | Note appears with auto-generated title (first line or "Quick Note") | Title generation |

### 4.3 Save Empty Note (Error)

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Leave content empty | - | - |
| 2 | Click "Save Note" | ❌ "Content is required" | 400 validation |

---

## 5. Search & Chat Tests (via Extension + Dashboard)

### 5.1 Basic Content Search

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Click extension → "Search" or chat input | Chat interface opens | - |
| 2 | Type: "find my resume" | Message appears in chat | - |
| 3 | Press Enter | "Searching..." indicator | POST /rag-search-auth |
| 4 | Wait 1-3 seconds | Results appear: "I found 2 documents matching 'resume':" | Intent: CONTENT_SEARCH |
| 5 | See result cards | Each shows: title, tag, snippet, "View" button | Hybrid search + rerank |
| 6 | Click "View" on a result | New tab opens with document content | View token generation |

### 5.2 Search with Synthesis (Question)

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Type: "what does my resume say about work experience?" | - | - |
| 2 | Press Enter | "Searching..." then "Generating answer..." | - |
| 3 | Wait 2-5 seconds | LLM-generated answer: "Based on your resume, your work experience includes..." | Synthesis with Groq |
| 4 | Below answer | "Sources:" section with clickable document links | Source attribution |

### 5.3 Search with No Results

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Type: "quantum physics recipes for aliens" | - | - |
| 2 | Press Enter | Response: "I couldn't find any documents matching that query." | Empty result handling |
| 3 | Suggestion shown | "Try different keywords or check your saved documents." | Graceful fallback |

### 5.4 Tag-Based Search

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Type: "show me documents with tag work" | - | - |
| 2 | Press Enter | List of all documents under "work" tag | Intent: TAG_BROWSE |
| 3 | Results shown | Each doc with title, date, "View" link | get_notes_by_tag |

### 5.5 Specific Tag Search

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Type: "find my aadhaar in personal documents" | - | - |
| 2 | Press Enter | Searches only within "personal" tag | Tag-filtered hybrid search |
| 3 | Results | Only documents from "personal" tag shown | Filter in vector search |

### 5.6 Exploratory Query

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Type: "do I have anything about machine learning?" | - | - |
| 2 | Press Enter | Response: "Yes, I found X documents related to machine learning..." | Intent: EXPLORATORY |
| 3 | Shows sample docs | Brief list with option to "See all" | LLM summary |

### 5.7 Collection Summary

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Type: "summarize my notes" or "what topics do I have?" | - | - |
| 2 | Press Enter | Overview: "You have 45 documents across 8 tags..." | Intent: COLLECTION_SUMMARY |
| 3 | Shows breakdown | By tag with counts, recent activity | get_tags_with_counts |

### 5.8 Date Query (Not Yet Supported)

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Type: "what did I save yesterday?" | - | - |
| 2 | Press Enter | Response: "Date-based search is coming soon! For now, check the 'Your Notes' tab..." | Intent: DATE_QUERY canned response |

### 5.9 Multi-Step Query (Not Yet Supported)

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Type: "compare my two resumes" | - | - |
| 2 | Press Enter | Response: "Multi-document comparison is not yet supported..." | Intent: MULTI_STEP canned response |

---

## 6. Dashboard - Your Notes Tab

### 6.1 View All Notes

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Go to dashboard → "Your Notes" | Grid/list of all notes | GET /notes |
| 2 | See note cards | Each shows: title, tag pill, date, file type icon | - |
| 3 | Scroll down | More notes load (pagination) | offset/limit params |

### 6.2 Filter by Tag

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Click tag dropdown | List of all tags with counts | GET /notes/tags/all |
| 2 | Select "work" | Only "work" tagged notes shown | GET /notes?tag=work |
| 3 | Clear filter | All notes shown again | - |

### 6.3 View a Note

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Click on a note card | Note detail view opens | - |
| 2 | For uploaded file | PDF/image viewer or download link | Azure SAS redirect |
| 3 | For quick note | Formatted markdown content displayed | HTML rendering |
| 4 | See metadata | Created date, tag, file size | - |

### 6.4 Delete a Note

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Click "..." menu on note | Options dropdown | - |
| 2 | Click "Delete" | Confirmation dialog: "Are you sure?" | - |
| 3 | Confirm delete | Note removed from list, toast: "Note deleted" | DELETE /notes/{id} |
| 4 | Search for deleted note | Does NOT appear in results | Soft delete + status filter |

---

## 7. Dashboard - Activity Logs

### 7.1 View Recent Activity

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Go to "Activity Logs" tab | Timeline of recent activities | search_traces + upload_traces |
| 2 | See entries | Search queries, uploads with timestamps | - |
| 3 | See metrics | "5 searches, 2 uploads today" | Aggregation queries |

### 7.2 View Search Trace Details

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Click on a search entry | Expands to show details | - |
| 2 | See timing breakdown | Embed: 45ms, Search: 120ms, Rerank: 300ms | Trace data |
| 3 | See result count | "Found 3 results" | - |

### 7.3 View Upload Trace Details

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Click on an upload entry | Expands with pipeline steps | - |
| 2 | See step timings | Upload: 500ms, Convert: 2s, Chunk: 100ms, Vectorize: 800ms | upload_traces |
| 3 | See status | ✓ Completed or ❌ Failed with error | - |

---

## 8. Dashboard - Settings / API Keys

### 8.1 Create New API Key

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Go to "Settings" → "API Keys" | List of existing keys (or empty) | GET /auth/api-keys |
| 2 | Click "Create New Key" | Modal opens | - |
| 3 | Enter name: "Mobile App" | - | - |
| 4 | Click "Create" | Shows key: `na_Abc123...` with copy button | POST /auth/api-keys |
| 5 | Warning shown | "Copy this key now. You won't be able to see it again!" | Key only shown once |
| 6 | Click "Copy" | Copied to clipboard, toast: "Copied!" | - |
| 7 | Close modal | New key appears in list with prefix `na_Abc...` | - |

### 8.2 View API Keys

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | View API keys list | Shows: name, prefix, created date, last used | - |
| 2 | Note: full key hidden | Only `na_Abc1234...` prefix visible | Security |

### 8.3 Delete API Key

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Click trash icon on a key | Confirmation: "Delete this API key?" | - |
| 2 | Confirm | Key removed from list | DELETE /auth/api-keys/{id} |
| 3 | Try using deleted key | API returns 401 Unauthorized | Key invalidated |

---

## 9. Error States & Edge Cases

### 9.1 Network Offline

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Disconnect internet | - | - |
| 2 | Try to upload file | ❌ "Network error. Please check your connection." | Offline handling |
| 3 | Try to search | ❌ "Unable to connect. Please try again." | - |

### 9.2 Session Expired

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Leave browser idle for 24+ hours | - | - |
| 2 | Try any action | Redirected to login: "Session expired. Please sign in again." | JWT expiration |

### 9.3 Server Error

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | (Simulated server issue) | - | - |
| 2 | Any action | ❌ "Something went wrong. Please try again later." | 500 error handling |

### 9.4 Rate Limiting

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Send 50+ searches rapidly | - | - |
| 2 | After limit hit | ⚠️ "Too many requests. Please wait a moment." | 429 handling |

---

## 10. Cross-Platform Tests

### 10.1 Extension on Different Sites

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Open extension on Google Docs | Works normally | - |
| 2 | Open extension on GitHub | Works normally | - |
| 3 | Open extension on `chrome://` page | Shows warning: "Cannot access this page" | Chrome restrictions |

### 10.2 Dashboard on Mobile (Responsive)

| Step | User Action | Expected Frontend Result | Backend Tested |
|------|-------------|-------------------------|----------------|
| 1 | Open dashboard on phone browser | Responsive layout, hamburger menu | CSS responsive |
| 2 | Navigate tabs | Touch-friendly, swipe support | - |
| 3 | Upload file | Works via mobile file picker | - |

---

## Test Summary

| Category | Test Cases | Priority |
|----------|------------|----------|
| First-Time Setup | 1.1 - 1.2 | High |
| File Upload | 2.1 - 2.10 | High |
| Screenshot | 3.1 - 3.3 | Medium |
| Quick Notes | 4.1 - 4.3 | Medium |
| Search & Chat | 5.1 - 5.9 | High |
| Dashboard Notes | 6.1 - 6.4 | High |
| Activity Logs | 7.1 - 7.3 | Low |
| API Keys | 8.1 - 8.3 | Medium |
| Error States | 9.1 - 9.4 | Medium |
| Cross-Platform | 10.1 - 10.2 | Low |

**Total: ~55 user journey test cases**

---

## Automation Priority

For Playwright automation:

1. **High Priority (automate first):**
   - 2.1 Upload PDF → verify in dashboard → search for it
   - 2.8-2.9 Storage quota error handling
   - 5.1-5.2 Basic search and synthesis
   - 6.1-6.3 View and filter notes

2. **Medium Priority:**
   - 3.1 Screenshot capture
   - 4.1 Quick notes
   - 8.1 API key creation

3. **Manual Testing Recommended:**
   - 9.x Error states (hard to simulate)
   - 10.2 Mobile responsive (use browser dev tools)
