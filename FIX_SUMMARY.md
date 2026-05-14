# Fix for "Missing type parameter" Error When Uploading Large Files

## Problem
When uploading large zip files, the app crashes with:
```
Error picking file: PlatformException(error, Missing type parameter., null, java.lang.RuntimeException: Missing type parameter.
at v0.a.<init>(SourceFile:10)
at com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin...
```

This error originates from the `flutter_local_notifications` plugin when trying to cancel notifications during file upload/download operations.

## Root Cause
The `flutter_local_notifications` plugin has a known issue on some Android devices where calling `cancel()` or `cancelAll()` methods can throw a "Missing type parameter" RuntimeException. This happens particularly when:
1. The notification cache contains corrupted data
2. There's a type serialization issue in the plugin's internal storage
3. The plugin tries to deserialize scheduled notifications with missing type information

## Solution Applied

### 1. Added Try-Catch Wrappers in Notification Service
**File:** `lib/services/notification_service.dart`

Wrapped `cancel()` and `cancelAll()` calls with try-catch blocks to prevent crashes:

```dart
Future<void> cancelNotification(int id) async {
  if (!_isInitialized) return;
  try {
    await _flutterLocalNotificationsPlugin.cancel(id);
  } catch (e, stackTrace) {
    // Silently ignore cancellation errors to prevent crashes
    debugPrint('[NotificationService] Failed to cancel notification $id: $e');
    debugPrint('[NotificationService] Stack trace: $stackTrace');
  }
}

Future<void> cancelAllNotifications() async {
  if (!_isInitialized) return;
  try {
    await _flutterLocalNotificationsPlugin.cancelAll();
  } catch (e, stackTrace) {
    // Silently ignore cancellation errors to prevent crashes
    debugPrint('[NotificationService] Failed to cancel all notifications: $e');
    debugPrint('[NotificationService] Stack trace: $stackTrace');
  }
}
```

### 2. Added Try-Catch in File Browser Screen
**File:** `lib/screens/file_browser_screen.dart`

Added additional error handling around all `cancelNotification` calls in both upload and download flows:

```dart
// Cancel upload progress notification
if (_uploadNotificationId != null && _notificationService != null) {
  try {
    await _notificationService!.cancelNotification(_uploadNotificationId!);
  } catch (e) {
    // Ignore cancellation errors
    debugPrint('Failed to cancel upload notification: $e');
  }
  _uploadNotificationId = null;
}
```

### 3. Improved File Picker Error Handling
**File:** `lib/screens/file_browser_screen.dart`

Added dedicated try-catch block around FilePicker operations to provide better error messages:

```dart
FilePickerResult? result;
try {
  result = await FilePicker.pickFiles(
    type: FileType.any,
    allowMultiple: false,
  );
} catch (e) {
  // Handle file picker errors gracefully
  debugPrint('[FilePicker Error] Failed to pick file: $e');
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Error picking file: ${e.toString()}'),
      backgroundColor: Colors.red,
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
    ),
  );
  setState(() => _isPickingFile = false);
  return;
}
```

### 4. Enhanced MainActivity.kt
**File:** `android/app/src/main/kotlin/com/example/flutter_disbox/MainActivity.kt`

Added intent extras cleanup to prevent potential type parameter issues:

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
  // Clean up any problematic extras that might cause type parameter issues
  try {
    intent?.extras?.let { bundle ->
      bundle.keySet().forEach { key ->
        if (bundle.get(key) == null) {
          bundle.remove(key)
        }
      }
    }
  } catch (e: Exception) {
    android.util.Log.w("MainActivity", "Error cleaning intent extras: ${e.message}")
  }
  
  super.onCreate(savedInstanceState)
}
```

### 5. Made Notification Initialization Non-Fatal
**File:** `lib/main.dart`

Changed notification service initialization to not crash the app if it fails:

```dart
try {
  await notificationService.initialize();
  debugPrint('[Main] Notification service initialized');
} catch (e, stackTrace) {
  debugPrint('[Main ERROR] Failed to initialize notification service: $e');
  debugPrint('[Main ERROR] Stack trace: $stackTrace');
  // Continue without notifications - they're optional for core functionality
}
```

## Testing Recommendations

1. **Test with large files (>500MB)**: Verify that uploads complete without crashing
2. **Test notification cancellation**: Upload/download files and verify progress notifications work
3. **Test error scenarios**: Try uploading while notifications are disabled
4. **Test on different Android versions**: Especially Android 11+ where this issue is more common

## Alternative Solutions (If Issues Persist)

If problems continue, consider:

1. **Disable notifications temporarily**: Comment out notification code in `file_browser_screen.dart`
2. **Use a different notification approach**: Switch to simple SnackBar messages only
3. **Update flutter_local_notifications**: Check for newer versions that may have fixed this bug
4. **Clear app data**: Have users clear app data/cache to reset notification cache

## Files Modified

1. `lib/services/notification_service.dart` - Added try-catch to cancel methods
2. `lib/screens/file_browser_screen.dart` - Added error handling for notifications and file picker
3. `lib/main.dart` - Made notification init non-fatal
4. `android/app/src/main/kotlin/com/example/flutter_disbox/MainActivity.kt` - Added intent cleanup
