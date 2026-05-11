# Quick Start Guide - Flutter Disbox

## 1. Project Structure Summary

```
flutter_disbox/
├── lib/
│   ├── main.dart                    # ✅ App entry point, theme, startup logic
│   ├── models/
│   │   └── disbox_file.dart         # ✅ File/folder data model with JSON serialization
│   ├── services/
│   │   └── disbox_service.dart      # ✅ Discord API service (upload/download/delete)
│   ├── utils/
│   │   └── chunk_utils.dart         # ✅ File chunking for >25MB files
│   ├── screens/
│   │   ├── setup_screen.dart        # ✅ Webhook URL setup screen
│   │   └── file_browser_screen.dart # ✅ Main file browser UI
│   └── widgets/
│       ├── file_list_tile.dart      # ✅ File item widget with icons
│       ├── file_icon.dart           # ✅ File type icon selector
│       └── progress_dialog.dart     # ✅ Progress indicator dialog
├── pubspec.yaml                     # ✅ Dependencies configuration
├── README.md                        # ✅ Full documentation
└── QUICK_START.md                   # 📍 You are here
```

## 2. Core Service Class Skeleton (DisboxService)

**Location:** `lib/services/disbox_service.dart`

```dart
class DisboxService {
  // Key Methods:
  Future<void> setWebhookUrl(String url)      // Configure webhook
  Future<DisboxFile> uploadFile(...)          // Upload with progress
  Future<File> downloadFile(...)              // Download with progress
  Future<void> deleteFile(DisboxFile file)    // Delete file/folder
  Future<List<DisboxFile>> listFiles(...)     // List folder contents
  Future<DisboxFile> createFolder(...)        // Create virtual folder
  Future<DisboxFile> renameFile(...)          // Rename file/folder
}
```

**Key Features:**
- Automatic chunking for files >25MB
- Progress callbacks for upload/download
- Metadata stored as JSON in Discord messages
- SHA256 hashing of webhook URL for account ID

## 3. Chunking Utility Example

**Location:** `lib/utils/chunk_utils.dart`

```dart
// Calculate chunks needed
int chunks = ChunkUtils.calculateChunkCount(fileSize); 
// e.g., 60MB file → 3 chunks

// Split file into chunks
List<FileChunk> chunks = ChunkUtils.splitFile(myFile);

// Read specific chunk
Uint8List chunkData = await ChunkUtils.readChunk(myFile, chunkIndex);

// Reassemble after download
await ChunkUtils.assembleChunks(chunks, outputPath);
```

**Constants:**
- `maxAttachmentSize = 25 MB` (Discord limit)
- `chunkSize = 24 MB` (safety margin)

## 4. Discord Webhook Upload Code Snippet

**From:** `lib/services/disbox_service.dart`

```dart
Future<String> _uploadAttachment(
  Uint8List data, {
  required String filename,
  required String contentType,
}) async {
  final apiUrl = _getWebhookApiUrl();
  
  final formData = FormData.fromMap({
    'file': MultipartFile.fromBytes(
      data,
      filename: filename,
      contentType: MediaType.parse(contentType),
    ),
  });

  final response = await _dio.post(
    apiUrl,
    data: formData,
    queryParameters: {'wait': 'true'},
  );

  return response.data['id']; // Message ID
}
```

**API Endpoints Used:**
- `POST /webhooks/{id}/{token}` - Upload attachment
- `GET /webhooks/{id}/{token}/messages/{msg_id}` - Fetch metadata
- `DELETE /webhooks/{id}/{token}/messages/{msg_id}` - Delete chunk
- `PATCH /webhooks/{id}/{token}/messages/{msg_id}` - Update metadata

## 5. Basic File Browser UI Widget Outline

**Location:** `lib/screens/file_browser_screen.dart`

```dart
class FileBrowserScreen extends StatefulWidget {
  // Features:
  // ✅ AppBar with upload/new folder buttons
  // ✅ Breadcrumb navigation (go up)
  // ✅ ListView with FileListTile items
  // ✅ FAB for quick upload
  // ✅ Empty state with helpful message
  // ✅ Loading and error states
  
  // User Actions:
  // - Tap folder → Navigate into it
  // - Tap file → Show options menu
  // - Long press → Show options menu
  // - Pull to refresh (TODO)
}
```

**Options Menu:**
- Details (show file info)
- Download (save to device)
- Rename (edit name)
- Share (coming soon)
- Delete (with confirmation)

## 6. Running the MVP

```bash
# 1. Navigate to project
cd flutter_disbox

# 2. Install dependencies
flutter pub get

# 3. Run on Android device/emulator
flutter run

# 4. Enter your Discord webhook URL
#    (See README.md for webhook creation steps)

# 5. Upload a test file (<25MB for MVP)
```

## 7. What's Implemented vs TODO

### ✅ MVP (Done)
- Webhook URL setup with validation
- File upload (<25MB single chunk)
- File listing (mock data for demo)
- File download
- Delete files
- Rename files
- Create folders
- Progress tracking
- File type icons
- Responsive UI

### 🔧 TODO (Next Steps)
1. **Message Fetching**: Implement `_fetchMessages()` to actually retrieve Discord channel messages
2. **Hive Integration**: Add local caching for offline access
3. **Multi-chunk Upload**: Test with files >25MB
4. **Error Recovery**: Retry failed uploads, checksum validation
5. **Share Links**: Generate shareable URLs
6. **Search**: Search across filenames
7. **Multiple Accounts**: Support multiple webhook URLs

## 8. Key Challenges & Solutions

| Challenge | Solution |
|-----------|----------|
| **Chunking >25MB** | Split into 24MB chunks, track message IDs |
| **Metadata Storage** | JSON in Discord message content with `[DISBOX]` prefix |
| **Progress Handling** | Stream callbacks with byte counting |
| **Error Recovery** | Try-catch with retry logic (implement in production) |
| **Security** | SHA256 hash client-side, never send webhook to third parties |
| **CORS Bypass** | Direct HTTP from mobile (no browser restrictions!) |

## 9. Testing Checklist

- [ ] Enter valid webhook URL
- [ ] Enter invalid webhook URL (should show error)
- [ ] Upload small file (<1MB)
- [ ] Upload medium file (10-20MB)
- [ ] Create new folder
- [ ] Navigate into folder
- [ ] Navigate back up
- [ ] Rename file
- [ ] Download file
- [ ] Delete file
- [ ] Long press for context menu

---

**Need Help?** Check the full README.md for detailed documentation.
