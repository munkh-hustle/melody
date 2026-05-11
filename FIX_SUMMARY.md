# Fix for "Webhook URL not configured" Error

## Problem
The app was showing error "Error: Bad state: Webhook URL not configured" because the `FileBrowserScreen` was creating a new `DisboxService` instance and immediately calling `listFiles()` without first setting the webhook URL.

## Root Cause
1. `FileBrowserScreen` created `DisboxService` as a final field initialized at declaration
2. Called `_loadFiles()` in `initState()` which called `listFiles()` 
3. But `setWebhookUrl()` was never called on that service instance
4. The webhook URL was only saved in SharedPreferences by `SetupScreen`, but not loaded into the service

## Solution

### 1. Updated `file_browser_screen.dart`

**Key Changes:**
- Changed `_disboxService` from `final` to `late final` so it can be initialized in `initState()`
- Added `_isInitialized` flag to track service initialization state
- Created `_initializeService()` method that:
  - Loads webhook URL from SharedPreferences
  - Validates it exists
  - Calls `setWebhookUrl()` on the service (which also loads file tree from Hive)
  - Only then calls `_loadFiles()`
- Added extensive debug logging with `[DEBUG]` prefix

**Flow:**
```
initState()
  → _initializeService()
    → Load webhook_url from SharedPreferences
    → Validate webhook exists
    → Call _disboxService.setWebhookUrl(webhookUrl)
      → This initializes Hive
      → This loads file tree from local storage
    → Set _isInitialized = true
    → Call _loadFiles()
      → Now service is configured, listFiles() works
```

### 2. Updated `disbox_service.dart`

**Added Debug Logging:**
- All methods now log when they're called
- All errors print detailed context before throwing
- `_loadFileTree()` logs account ID and number of items loaded
- `_saveFileTree()` logs success/failure
- `setWebhookUrl()` logs the accountId generation
- All file operations (`uploadFile`, `downloadFile`, `deleteFile`, `listFiles`, `createFolder`, `renameFile`) check configuration and log errors

**Improved Error Messages:**
- Changed from generic "Webhook URL not configured" to "Webhook URL not configured. Please call setWebhookUrl() first."
- Added context logging showing current state (_webhookUrl, _accountId, isConfigured)

### 3. Updated `main.dart`

**Added Debug Logging:**
- Logs when checking setup
- Shows if webhook_url exists and its length
- Shows account_id value
- Logs navigation decision

## How It Works Now

### First Launch (No Webhook Configured)
1. `AppStartup._checkSetup()` finds no webhook_url in SharedPreferences
2. Navigates to `SetupScreen`
3. User enters webhook URL
4. `SetupScreen._saveWebhookUrl()` saves to SharedPreferences
5. Navigates to `FileBrowserScreen`

### Subsequent Launchs (Webhook Already Configured)
1. `AppStartup._checkSetup()` finds webhook_url in SharedPreferences
2. Navigates directly to `FileBrowserScreen`
3. `FileBrowserScreen._initializeService()`:
   - Loads webhook_url from SharedPreferences
   - Calls `setWebhookUrl()` which:
     - Initializes Hive
     - Generates accountId (SHA256 hash of webhook URL)
     - Loads file tree from Hive using accountId as key
   - Sets `_isInitialized = true`
4. Calls `_loadFiles()` which successfully lists files from the loaded file tree

### File Operations
All file operations now work with local Hive storage:
- **Create folder**: Adds to file tree, saves to Hive
- **Upload file**: Uploads to Discord, adds metadata to file tree, saves to Hive
- **Delete file**: Deletes from Discord, removes from file tree, saves to Hive
- **List files**: Reads from loaded file tree (no network needed for metadata)

## Debug Output Example

When app starts successfully:
```
[AppStartup] Checking setup...
[AppStartup] Loaded webhook_url: exists (78 chars)
[AppStartup] Loaded account_id: null
[AppStartup] Navigation decision: hasWebhook=true
[DEBUG] Initializing DisboxService...
[DEBUG] Loaded webhook_url: exists
[DEBUG] Loaded account_id: null
[DisboxService] Setting webhook URL...
[DisboxService] Webhook URL set, accountId: a1b2c3d4e5f6g7h8
[DisboxService] Loading file tree from local storage...
[DisboxService] Account ID: a1b2c3d4e5f6g7h8
[DisboxService] Loaded file tree with 5 items
[DEBUG] Service initialized successfully
[DEBUG] Service isConfigured: true
[DEBUG] Service accountId: a1b2c3d4e5f6g7h8
[DEBUG] Loading files from path: /
[DisboxService] Listing files in: /
[DEBUG] Loaded 5 files
```

When there's an error:
```
[DisboxService ERROR] listFiles called but webhook not configured
[DisboxService ERROR] isConfigured: false, _webhookUrl: null, _accountId: null
```

## Testing Checklist

- [ ] First launch shows SetupScreen
- [ ] Entering valid webhook URL navigates to FileBrowserScreen
- [ ] Creating folders persists across app restarts
- [ ] Uploading files works and shows in file list
- [ ] App restart shows files from previous session
- [ ] Delete operations work correctly
- [ ] Check debug logs in console for any errors
