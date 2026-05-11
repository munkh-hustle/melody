# JSON Import Feature

## Overview
The app now supports importing webhook configuration from a JSON file instead of manually entering the webhook URL.

## How to Use

### 1. Create Config File
Create a JSON file with your webhook URL:

```json
{
  "webhook_url": "https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN"
}
```

Optionally, include file tree metadata:
```json
{
  "webhook_url": "https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN",
  "file_tree": {
    "id": "root",
    "name": "root",
    "type": "directory",
    "children": {},
    "created_at": "2024-01-01T00:00:00.000Z",
    "updated_at": "2024-01-01T00:00:00.000Z"
  }
}
```

### 2. Import in App
1. Open the app - it will show the Import screen
2. Tap "Select JSON File"
3. Choose your config file
4. The app will automatically load your webhook and navigate to the main screen

## Files Changed

### `lib/services/disbox_service.dart`
- Added `importConfig(File jsonFile)` method
- Class now extends `ChangeNotifier` for reactive updates
- Added `package:flutter/foundation.dart` import

### `lib/screens/import_screen.dart` (NEW)
- New screen for JSON file import
- File picker integration
- Error handling and user feedback
- Help dialog with instructions

### `lib/main.dart`
- Simplified to use `ImportScreen` as home
- Removed `AppStartup` and SharedPreferences logic
- Removed dependency on `setup_screen.dart`

### `config_template.json` (NEW)
- Template file for users to copy and fill in

## Benefits

1. **No Manual Entry**: Users don't need to type long webhook URLs
2. **Easy Sharing**: Config files can be shared between devices
3. **Secure**: Webhook URL stays in user's control
4. **Optional File Tree**: Can import file metadata along with webhook

## Migration

Old setup flow is removed. Users must:
1. Export config from old device (if applicable)
2. Or create new JSON file with their webhook URL
3. Import on new installation

## Testing

1. Create test config file with valid webhook URL
2. Run app and import the file
3. Verify navigation to file browser
4. Upload/download files to confirm webhook works
