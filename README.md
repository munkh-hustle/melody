# Flutter Disbox - Discord-Powered Cloud Storage

A Flutter Android app that replicates DisboxApp/web - free cloud storage using Discord webhooks as backend.

## 📁 Project Structure

```
lib/
├── main.dart                    # App entry point
├── models/
│   └── disbox_file.dart         # File/folder data model
├── services/
│   └── disbox_service.dart      # Discord API service (upload, download, etc.)
├── utils/
│   └── chunk_utils.dart         # File chunking utilities (>25MB handling)
├── screens/
│   ├── setup_screen.dart        # Webhook URL setup
│   └── file_browser_screen.dart # Main file browser UI
└── widgets/
    ├── file_list_tile.dart      # File item widget
    ├── file_icon.dart           # File type icons
    └── progress_dialog.dart     # Upload/download progress
```

## 🚀 Getting Started

### Prerequisites
- Flutter SDK 3.0+
- Android Studio / VS Code with Flutter extensions
- A Discord server with webhook permissions

### Installation

1. **Clone and install dependencies:**
```bash
cd flutter_disbox
flutter pub get
```

2. **Configure Android permissions** (android/app/src/main/AndroidManifest.xml):
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>
```

3. **Run the app:**
```bash
flutter run
```

## 🎯 MVP Features

✅ **Webhook URL Setup**
- User inputs Discord webhook URL
- URL is hashed locally for account ID
- Stored securely in SharedPreferences

✅ **File Upload (<25MB)**
- Pick file from device
- Upload as attachment to Discord webhook
- Progress tracking

✅ **File Listing**
- Fetch messages from webhook channel
- Parse metadata messages
- Display files with icons

✅ **File Download**
- Download attachment from Discord
- Save to device storage
- Progress tracking

## 🔧 Core Concepts

### How It Works

1. **User provides webhook URL** → App hashes it for local account ID
2. **Upload file** → POST to webhook as multipart attachment
3. **Store metadata** → Create Discord message with JSON containing:
   - Filename, path, size, MIME type
   - List of chunk message IDs (for large files)
4. **List files** → Fetch messages, filter for metadata, parse JSON
5. **Download** → Get attachment URL from message, download bytes

### Chunking Logic (>25MB files)

```dart
// Files are split into 24MB chunks
final chunks = ChunkUtils.splitFile(file);

// Each chunk uploaded separately
for (var chunk in chunks) {
  final messageId = await uploadChunk(chunk);
  chunkIds.add(messageId);
}

// Metadata stores all chunk IDs
await createMetadata(chunkIds: chunkIds);
```

### Metadata Schema

```json
{
  "type": "disbox_metadata",
  "version": "1.0",
  "name": "example.pdf",
  "path": "/documents/example.pdf",
  "size": 1048576,
  "mimeType": "application/pdf",
  "chunkIds": ["msg1", "msg2"],
  "isFolder": false,
  "createdAt": "2024-01-01T00:00:00Z"
}
```

## 📱 Key Screens

### Setup Screen
- Input field for webhook URL
- Validation and error handling
- Help dialog for creating webhooks
- Security warning about URL privacy

### File Browser
- List view with file/folder icons
- Navigation (up, into folders)
- Upload button (FAB)
- Context menu (download, rename, delete, share)
- Progress dialogs for operations

## 🔐 Security Notes

⚠️ **Important:**
- Webhook URL is stored locally only
- Never sent to third-party servers
- Hash generated client-side using SHA256
- Use `flutter_secure_storage` in production

## 🛠️ Next Steps for Full Implementation

1. **Message Fetching**: Implement proper channel message retrieval
2. **Hive Integration**: Add local caching for offline access
3. **Error Recovery**: Retry failed uploads, checksum validation
4. **Share Links**: Generate shareable URLs (requires additional backend)
5. **Search**: Full-text search across filenames
6. **Multiple Accounts**: Support multiple webhook URLs

## 📚 Dependencies

- `dio`: HTTP client for Discord API
- `hive_flutter`: Local database
- `file_picker`: File selection
- `path_provider`: Storage paths
- `crypto`: SHA256 hashing
- `provider`: State management

## 🙏 Credits

Inspired by [DisboxApp/web](https://github.com/DisboxApp/web)

## 📄 License

MIT License - see LICENSE file
