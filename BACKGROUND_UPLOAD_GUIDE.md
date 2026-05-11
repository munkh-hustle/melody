# Background Upload Feature Guide

## Overview

This guide explains how the background upload feature works in Disbox, allowing you to upload files and close the app while the upload continues in the background.

## How It Works

### Automatic Prompt for Large Files
- When you select a file larger than **50 MB**, you'll be prompted to choose between:
  - **Foreground Upload**: You see the progress but must keep the app open
  - **Background Upload**: You can close the app and the upload continues

### For Smaller Files (< 50 MB)
- Files upload in foreground by default with progress indicator
- The app stays open showing upload progress

## Technical Implementation

### Dependencies Added
```yaml
dependencies:
  workmanager: ^0.5.2      # For background task scheduling
  flutter_isolate: ^2.0.2  # For running tasks in separate isolate
```

### Key Components

1. **WorkManager Initialization** (`lib/main.dart`)
   - Initializes WorkManager when the app starts
   - Registers the callback dispatcher for background tasks

2. **Background Upload Service** (`lib/services/background_upload_service.dart`)
   - `callbackDispatcher()`: Entry point for background tasks
   - `_uploadFileInBackground()`: Handles the actual file upload in background
   - Supports chunked uploads for large files (20MB chunks)

3. **Modified Upload Logic** (`lib/screens/file_browser_screen.dart`)
   - `_uploadFile({bool useBackground})`: Now accepts a parameter to control upload mode
   - `_scheduleBackgroundUpload()`: Schedules the background task with WorkManager
   - Shows dialog for files > 50MB to let user choose upload mode

4. **Android Configuration** (`android/app/src/main/AndroidManifest.xml`)
   - Added WorkManager initialization provider
   - Ensures background tasks are properly registered

## Usage Flow

1. User taps "Upload" button
2. File picker opens
3. User selects a file
4. If file > 50MB:
   - Dialog appears asking "Foreground or Background?"
   - User chooses option
5. If Background selected:
   - Task is scheduled with WorkManager
   - User gets confirmation message: "Upload started in background. You can close the app."
   - User can close app
   - Upload continues in background
6. If Foreground selected (or file < 50MB):
   - Progress dialog shows upload progress
   - User must keep app open until upload completes

## Limitations & Considerations

### Android Background Restrictions
- Android may kill background tasks if system needs resources
- WorkManager tries to guarantee execution but timing isn't guaranteed
- Best for uploads that complete within a few minutes

### Network Requirements
- Background uploads need network connectivity
- If network is lost, upload will retry when connection is restored

### Battery Optimization
- Some devices may restrict background activity to save battery
- Users may need to whitelist the app in battery settings for reliable background uploads

### File Size Limits
- Discord has a 25MB limit per message (for free accounts)
- The implementation splits files into 20MB chunks
- Very large files may take longer in background

## Testing

To test background uploads:

1. Run the app on a real Android device (emulators don't fully support background tasks)
2. Select a file larger than 50MB
3. Choose "Background" when prompted
4. Close the app immediately
5. Check Discord channel - file should appear after upload completes

## Troubleshooting

### Upload doesn't start in background
- Check if WorkManager is initialized in `main.dart`
- Verify AndroidManifest.xml has WorkManager provider
- Check logs for error messages

### Upload stops when app is closed
- Android may be killing the background task due to battery optimization
- Try whitelisting the app in battery settings
- Ensure proper permissions are granted

### File not appearing in Discord
- Check network connectivity
- Verify webhook URL is correct
- Check if file size exceeds Discord limits

## Future Improvements

- Add notification to show upload progress
- Implement retry logic for failed uploads
- Add upload queue management
- Show upload status when app reopens
- Support for uploading multiple files in background
