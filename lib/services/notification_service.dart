import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'rxdart/rxdart.dart';

/// Service for managing local notifications for upload/download progress.
class NotificationService extends ChangeNotifier {
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;
  int _notificationId = 0;

  // Broadcast streams for notification actions
  final _stopUploadController = PublishSubject<int>();
  final _resumeUploadController = PublishSubject<int>();
  final _stopDownloadController = PublishSubject<int>();
  final _resumeDownloadController = PublishSubject<int>();

  /// Stream of stop upload actions with notification ID
  Stream<int> get onStopUpload => _stopUploadController.stream;

  /// Stream of resume upload actions with notification ID
  Stream<int> get onResumeUpload => _resumeUploadController.stream;

  /// Stream of stop download actions with notification ID
  Stream<int> get onStopDownload => _stopDownloadController.stream;

  /// Stream of resume download actions with notification ID
  Stream<int> get onResumeDownload => _resumeDownloadController.stream;

  /// Action button IDs
  static const String stopUploadActionId = 'stop_upload';
  static const String resumeUploadActionId = 'resume_upload';
  static const String stopDownloadActionId = 'stop_download';
  static const String resumeDownloadActionId = 'resume_download';

  /// Channel for upload notifications
  static const AndroidNotificationChannel _uploadChannel =
      AndroidNotificationChannel(
    'upload_progress',
    'Upload Progress',
    description: 'Notifications for file upload progress',
    importance: Importance.low,
    showBadge: false,
  );

  /// Channel for download notifications
  static const AndroidNotificationChannel _downloadChannel =
      AndroidNotificationChannel(
    'download_progress',
    'Download Progress',
    description: 'Notifications for file download progress',
    importance: Importance.low,
    showBadge: false,
  );

  /// Channel for completion notifications
  static const AndroidNotificationChannel _completionChannel =
      AndroidNotificationChannel(
    'transfer_complete',
    'Transfer Complete',
    description: 'Notifications for completed uploads and downloads',
    importance: Importance.high,
    playSound: true,
    enableVibration: true,
  );

  bool get isInitialized => _isInitialized;

  /// Initialize the notification service.
  ///
  /// This should be called early in the app lifecycle (e.g., in main()).
  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    try {
      // Request notification permission for Android 13+
      if (Platform.isAndroid) {
        final status = await Permission.notification.status;
        if (!status.isGranted) {
          await Permission.notification.request();
        }
      }

      // Initialize Android settings
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

      // Initialize iOS settings
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _flutterLocalNotificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onNotificationResponse,
      );

      // Create notification channels for Android
      await _createNotificationChannels();

      _isInitialized = true;
      notifyListeners();
      debugPrint('[NotificationService] Initialized successfully');
    } catch (e, stackTrace) {
      debugPrint('[NotificationService ERROR] Failed to initialize: $e');
      debugPrint('[NotificationService ERROR] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Create Android notification channels with action buttons.
  Future<void> _createNotificationChannels() async {
    if (Platform.isAndroid) {
      final androidPlugin =
          _flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidPlugin != null) {
        // Create notification categories for grouping
        final uploadCategory = AndroidNotificationCategory(
          'transfer',
          AndroidNotificationCategoryPriority.high,
        );

        // Create action buttons for upload notifications
        final stopUploadAction = const AndroidNotificationAction(
          stopUploadActionId,
          'Stop',
          showsUserInterface: false,
          cancelNotification: false,
        );
        
        final resumeUploadAction = const AndroidNotificationAction(
          resumeUploadActionId,
          'Resume',
          showsUserInterface: false,
          cancelNotification: false,
        );

        // Create action buttons for download notifications
        final stopDownloadAction = const AndroidNotificationAction(
          stopDownloadActionId,
          'Stop',
          showsUserInterface: false,
          cancelNotification: false,
        );
        
        final resumeDownloadAction = const AndroidNotificationAction(
          resumeDownloadActionId,
          'Resume',
          showsUserInterface: false,
          cancelNotification: false,
        );

        // Create upload channel with actions
        final uploadChannelWithActions = AndroidNotificationChannel(
          _uploadChannel.id,
          _uploadChannel.name,
          description: _uploadChannel.description,
          importance: Importance.low,
          showBadge: false,
          category: uploadCategory,
        );
        
        // Create download channel with actions
        final downloadChannelWithActions = AndroidNotificationChannel(
          _downloadChannel.id,
          _downloadChannel.name,
          description: _downloadChannel.description,
          importance: Importance.low,
          showBadge: false,
          category: uploadCategory,
        );

        await androidPlugin.createNotificationChannel(uploadChannelWithActions);
        await androidPlugin.createNotificationChannel(downloadChannelWithActions);
        await androidPlugin.createNotificationChannel(_completionChannel);
        
        // Store action sets for later use
        _uploadActionSet = AndroidNotificationActionGroup(
          'upload_actions',
          [stopUploadAction, resumeUploadAction],
        );
        
        _downloadActionSet = AndroidNotificationActionGroup(
          'download_actions',
          [stopDownloadAction, resumeDownloadAction],
        );
        
        debugPrint('[NotificationService] Created notification channels with action buttons');
      }
    }
  }

  // Action sets for notifications
  AndroidNotificationActionGroup? _uploadActionSet;
  AndroidNotificationActionGroup? _downloadActionSet;

  /// Handle notification tap response including action buttons.
  void _onNotificationResponse(NotificationResponse response) {
    debugPrint('[NotificationService] Notification response: ${response.type}, actionId: ${response.actionId}, payload: ${response.payload}');
    
    // Extract notification ID from payload (format: "upload:id" or "download:id")
    final payload = response.payload ?? '';
    final parts = payload.split(':');
    if (parts.length < 2) return;
    
    final type = parts[0]; // 'upload' or 'download'
    final id = int.tryParse(parts[1]);
    if (id == null) return;
    
    // Handle action button taps
    if (response.type == NotificationResponseType.selectedNotificationActionInput) {
      final actionId = response.actionId;
      
      if (type == 'upload') {
        if (actionId == stopUploadActionId) {
          debugPrint('[NotificationService] Stop upload action triggered for notification $id');
          _stopUploadController.add(id);
        } else if (actionId == resumeUploadActionId) {
          debugPrint('[NotificationService] Resume upload action triggered for notification $id');
          _resumeUploadController.add(id);
        }
      } else if (type == 'download') {
        if (actionId == stopDownloadActionId) {
          debugPrint('[NotificationService] Stop download action triggered for notification $id');
          _stopDownloadController.add(id);
        } else if (actionId == resumeDownloadActionId) {
          debugPrint('[NotificationService] Resume download action triggered for notification $id');
          _resumeDownloadController.add(id);
        }
      }
    } else if (response.type == NotificationResponseType.selectedNotification) {
      // Regular notification tap - could navigate to app
      debugPrint('[NotificationService] Notification tapped: $payload');
    }
  }

  /// Generate a unique notification ID.
  int _generateNotificationId() {
    _notificationId++;
    return _notificationId;
  }

  /// Show a progress notification for upload.
  ///
  /// [fileName] - Name of the file being uploaded
  /// [progress] - Progress from 0.0 to 1.0
  /// [notificationId] - Optional ID to update an existing notification
  /// [isPaused] - Whether the upload is paused (shows resume button)
  Future<int> showUploadProgress({
    required String fileName,
    required double progress,
    int? notificationId,
    bool isPaused = false,
  }) async {
    if (!_isInitialized) {
      debugPrint('[NotificationService] Not initialized, skipping notification');
      return -1;
    }

    final id = notificationId ?? _generateNotificationId();
    final percent = (progress * 100).toInt().clamp(0, 100);

    // Build actions list based on pause state
    List<AndroidNotificationAction>? actions;
    if (_uploadActionSet != null) {
      // Always show stop button, show resume only when paused
      actions = [
        const AndroidNotificationAction(
          stopUploadActionId,
          'Stop',
          showsUserInterface: false,
          cancelNotification: false,
        ),
        if (isPaused)
          const AndroidNotificationAction(
            resumeUploadActionId,
            'Resume',
            showsUserInterface: false,
            cancelNotification: false,
          ),
      ];
    }

    final androidDetails = AndroidNotificationDetails(
      _uploadChannel.id,
      _uploadChannel.name,
      channelDescription: _uploadChannel.description,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
      actions: actions,
      styleInformation: BigTextStyleInformation(
        isPaused ? 'Upload paused: $fileName' : 'Uploading $fileName...',
        contentTitle: isPaused ? 'Upload Paused' : 'Uploading',
        summaryText: '$percent% complete',
      ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );

    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _flutterLocalNotificationsPlugin.show(
      id,
      isPaused ? 'Upload Paused: $fileName' : 'Uploading $fileName',
      '$percent% complete',
      details,
      payload: 'upload:$id',
    );

    return id;
  }

  /// Show a progress notification for download.
  ///
  /// [fileName] - Name of the file being downloaded
  /// [progress] - Progress from 0.0 to 1.0
  /// [notificationId] - Optional ID to update an existing notification
  /// [isPaused] - Whether the download is paused (shows resume button)
  Future<int> showDownloadProgress({
    required String fileName,
    required double progress,
    int? notificationId,
    bool isPaused = false,
  }) async {
    if (!_isInitialized) {
      debugPrint('[NotificationService] Not initialized, skipping notification');
      return -1;
    }

    final id = notificationId ?? _generateNotificationId();
    final percent = (progress * 100).toInt().clamp(0, 100);

    // Build actions list based on pause state
    List<AndroidNotificationAction>? actions;
    if (_downloadActionSet != null) {
      // Always show stop button, show resume only when paused
      actions = [
        const AndroidNotificationAction(
          stopDownloadActionId,
          'Stop',
          showsUserInterface: false,
          cancelNotification: false,
        ),
        if (isPaused)
          const AndroidNotificationAction(
            resumeDownloadActionId,
            'Resume',
            showsUserInterface: false,
            cancelNotification: false,
          ),
      ];
    }

    final androidDetails = AndroidNotificationDetails(
      _downloadChannel.id,
      _downloadChannel.name,
      channelDescription: _downloadChannel.description,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
      actions: actions,
      styleInformation: BigTextStyleInformation(
        isPaused ? 'Download paused: $fileName' : 'Downloading $fileName...',
        contentTitle: isPaused ? 'Download Paused' : 'Downloading',
        summaryText: '$percent% complete',
      ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );

    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _flutterLocalNotificationsPlugin.show(
      id,
      isPaused ? 'Download Paused: $fileName' : 'Downloading $fileName',
      '$percent% complete',
      details,
      payload: 'download:$id',
    );

    return id;
  }

  /// Show a completion notification for successful transfer.
  ///
  /// [fileName] - Name of the transferred file
  /// [isUpload] - True if upload, false if download
  /// [destinationPath] - Optional path where file was saved
  Future<void> showTransferComplete({
    required String fileName,
    required bool isUpload,
    String? destinationPath,
  }) async {
    if (!_isInitialized) {
      debugPrint('[NotificationService] Not initialized, skipping notification');
      return;
    }

    final actionType = isUpload ? 'Uploaded' : 'Downloaded';
    final message = destinationPath != null
        ? '$actionType to $destinationPath'
        : '$actionType successfully';

    final androidDetails = AndroidNotificationDetails(
      _completionChannel.id,
      _completionChannel.name,
      channelDescription: _completionChannel.description,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      styleInformation: BigTextStyleInformation(
        message,
        contentTitle: '$actionType: $fileName',
        summaryText: 'Transfer complete',
      ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _flutterLocalNotificationsPlugin.show(
      _generateNotificationId(),
      '$actionType: $fileName',
      message,
      details,
      payload: '${isUpload ? "upload" : "download"}:complete:$fileName',
    );
  }

  /// Show an error notification for failed transfer.
  ///
  /// [fileName] - Name of the file
  /// [error] - Error message
  /// [isUpload] - True if upload, false if download
  Future<void> showTransferError({
    required String fileName,
    required String error,
    required bool isUpload,
  }) async {
    if (!_isInitialized) {
      debugPrint('[NotificationService] Not initialized, skipping notification');
      return;
    }

    final actionType = isUpload ? 'Upload' : 'Download';

    final androidDetails = AndroidNotificationDetails(
      _completionChannel.id,
      _completionChannel.name,
      channelDescription: _completionChannel.description,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      styleInformation: BigTextStyleInformation(
        error,
        contentTitle: '$actionType Failed: $fileName',
        summaryText: 'Transfer failed',
      ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _flutterLocalNotificationsPlugin.show(
      _generateNotificationId(),
      '$actionType Failed: $fileName',
      error,
      details,
      payload: '${isUpload ? "upload" : "download"}:error:$fileName',
    );
  }

  /// Cancel a notification by ID.
  Future<void> cancelNotification(int id) async {
    if (!_isInitialized) return;
    try {
      await _flutterLocalNotificationsPlugin.cancel(id);
    } catch (e, stackTrace) {
      // Silently ignore cancellation errors to prevent crashes
      // This can happen with certain Android versions due to type parameter issues
      debugPrint('[NotificationService] Failed to cancel notification $id: $e');
      debugPrint('[NotificationService] Stack trace: $stackTrace');
    }
  }

  /// Cancel all notifications.
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

  @override
  void dispose() {
    // Close streams
    _stopUploadController.close();
    _resumeUploadController.close();
    _stopDownloadController.close();
    _resumeDownloadController.close();
    
    cancelAllNotifications();
    super.dispose();
  }
}
