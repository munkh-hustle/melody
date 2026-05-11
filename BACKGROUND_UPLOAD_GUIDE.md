# Background Upload Implementation Guide

## Overview

This guide explains how to implement background file uploads in the Disbox Flutter app using `flutter_background_service`. This allows users to upload files and then close the app while the upload continues in the background.

## Changes Made

### 1. Dependencies (`pubspec.yaml`)

Replaced `workmanager` with `flutter_background_service`:

```yaml
dependencies:
  flutter_background_service: ^5.0.5
  flutter_background_service_android: ^6.2.2
```

**Why?** The `workmanager` package had compatibility issues with newer Flutter versions. `flutter_background_service` provides more reliable foreground service support for Android.

### 2. Main Entry Point (`lib/main.dart`)

Updated initialization to use the new background service:

```dart
import 'package:flutter_background_service/flutter_background_service.dart';
import 'services/background_upload_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize background service
  await initializeBackgroundService();
  
  runApp(const DisboxApp());
}
```

### 3. Background Upload Service (`lib/services/background_upload_service.dart`)

Completely rewritten to use `flutter_background_service`:

- **`initializeBackgroundService()`**: Configures the background service with Android-specific settings
- **`onStart()`**: Entry point for the background service that listens for upload commands
- **`_uploadFileInBackground()`**: Handles the actual file upload logic with chunked support

Key features:
- Runs as a foreground service with persistent notification
- Supports chunked uploads for large files (20MB chunks)
- Automatically stops when upload completes
- Works even when app is closed

### 4. File Browser Screen (`lib/screens/file_browser_screen.dart`)

Updated import and background upload scheduling:

```dart
import 'package:flutter_background_service/flutter_background_service.dart';
import '../services/background_upload_service.dart';

// In _scheduleBackgroundUpload method:
final service = FlutterBackgroundService();
await service.startService();
service.invoke('upload', {
  'filePath': filePath,
  'fileName': fileName,
  'folderPath': folderPath,
  'webhookUrl': webhookUrl,
  'accountId': accountId ?? '',
});
```

### 5. Android Manifest (`android/app/src/main/AndroidManifest.xml`)

Added required permissions for foreground service:

```xml
<!-- Foreground service permission for background uploads -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

Removed WorkManager initialization provider.

### 6. Android Build Configuration (`android/app/build.gradle.kts`)

Updated minimum SDK version:

```kotlin
minSdk = 21  // Required for flutter_background_service
```

## How It Works

### User Flow

1. **User selects file to upload** - File picker opens
2. **File size check** - If file > 50MB, prompt appears
3. **User chooses upload mode**:
   - **Foreground**: Shows progress bar, user stays in app
   - **Background**: Notification appears, user can close app
4. **Background upload starts**:
   - Service starts with persistent notification
   - File uploads in chunks (20MB each)
   - Service stops automatically when complete
5. **User receives completion notification**

### Technical Flow

```
┌─────────────┐
│   User      │
│  selects    │
│    file     │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ FileBrowser │
│   Screen    │
└──────┬──────┘
       │
       │ _scheduleBackgroundUpload()
       ▼
┌─────────────┐
│    Flask    │
│ Background  │
│   Service   │
└──────┬──────┘
       │
       │ startService()
       ▼
┌─────────────┐
│   onStart() │
│  callback   │
└──────┬──────┘
       │
       │ Listen for 'upload' event
       ▼
┌─────────────┐
│  Upload     │
│   File      │
│  in Chunks  │
└──────┬──────┘
       │
       │ Complete
       ▼
┌─────────────┐
│ Stop Self   │
│  & Notify   │
└─────────────┘
```

## Usage

### For Small Files (< 50MB)

Files upload in foreground by default with progress indicator.

### For Large Files (≥ 50MB)

A dialog prompts the user:

```dart
final useBackground = await showDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Large File Upload'),
    content: const Text(
      'This file is larger than 50MB. Would you like to upload in the background? '
      'You can close the app and the upload will continue.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('No, keep app open'),
      ),
      ElevatedButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Yes, upload in background'),
      ),
    ],
  ),
);

if (useBackground == true) {
  await _scheduleBackgroundUpload(...);
} else {
  // Foreground upload with progress
}
```

## Testing

### On Real Device

1. Connect Android device
2. Run: `flutter run`
3. Upload a large file (> 50MB)
4. Choose "Upload in background"
5. Close the app
6. Check notification - upload should continue
7. Wait for completion notification

### Debugging

Enable verbose logging in `background_upload_service.dart`:

```dart
debugPrint('Upload started: $fileName');
debugPrint('Chunk $i/${numChunks - 1} uploaded');
```

Check logs with:
```bash
adb logcat | grep -i "disbox\|background"
```

## Troubleshooting

### Issue: Build fails with workmanager errors

**Solution**: Already fixed by replacing workmanager with flutter_background_service.

### Issue: Background service doesn't start

**Check**:
1. Permissions granted in AndroidManifest.xml
2. minSdk >= 21 in build.gradle.kts
3. Service properly initialized in main.dart
4. On Android 13+, notification permission must be granted

### Issue: Upload stops when app closes

**Possible causes**:
1. Battery optimization killing the service
2. Missing FOREGROUND_SERVICE permission
3. Service not properly configured

**Solution**: 
- Ask user to disable battery optimization for the app
- Verify all permissions in AndroidManifest.xml
- Check service configuration in `initializeBackgroundService()`

### Issue: Notification doesn't appear

**Check**:
1. POST_NOTIFICATIONS permission granted (Android 13+)
2. Notification channel created
3. Service running in foreground mode

## Best Practices

1. **Always test on real devices** - Emulators don't fully replicate background behavior
2. **Handle network interruptions** - Implement retry logic for failed chunks
3. **Show clear feedback** - Use notifications to inform users of progress
4. **Respect battery life** - Use appropriate chunk sizes and stop service when done
5. **Request permissions at runtime** - Especially for Android 13+ notifications

## Future Enhancements

- [ ] Add upload resume capability
- [ ] Show progress in notification
- [ ] Support multiple concurrent uploads
- [ ] Add download in background
- [ ] Implement queue management
- [ ] Add settings for background upload preferences

## References

- [flutter_background_service Documentation](https://pub.dev/packages/flutter_background_service)
- [Android Foreground Services](https://developer.android.com/guide/components/foreground-services)
- [Flutter Background Execution](https://docs.flutter.dev/development/packages-and-plugins/background-execution)
