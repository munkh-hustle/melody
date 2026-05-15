import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service for managing local notifications for upload/download progress.
class NotificationService extends ChangeNotifier {
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;
  int _notificationId = 0;

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

  /// Create Android notification channels.
  Future<void> _createNotificationChannels() async {
    if (Platform.isAndroid) {
      final androidPlugin =
          _flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidPlugin != null) {
        await androidPlugin.createNotificationChannel(_uploadChannel);
        await androidPlugin.createNotificationChannel(_downloadChannel);
        await androidPlugin.createNotificationChannel(_completionChannel);
        debugPrint('[NotificationService] Created notification channels');
      }
    }
  }

  /// Handle notification tap response.
  void _onNotificationResponse(NotificationResponse response) {
    debugPrint('[NotificationService] Notification tapped: ${response.payload}');
    // You can add navigation logic here based on notification payload
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
  Future<int> showUploadProgress({
    required String fileName,
    required double progress,
    int? notificationId,
  }) async {
    if (!_isInitialized) {
      debugPrint('[NotificationService] Not initialized, skipping notification');
      return -1;
    }

    final id = notificationId ?? _generateNotificationId();
    final percent = (progress * 100).toInt().clamp(0, 100);

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
      styleInformation: BigTextStyleInformation(
        'Uploading $fileName...',
        contentTitle: 'Uploading',
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
      'Uploading $fileName',
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
  Future<int> showDownloadProgress({
    required String fileName,
    required double progress,
    int? notificationId,
  }) async {
    if (!_isInitialized) {
      debugPrint('[NotificationService] Not initialized, skipping notification');
      return -1;
    }

    final id = notificationId ?? _generateNotificationId();
    final percent = (progress * 100).toInt().clamp(0, 100);

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
      styleInformation: BigTextStyleInformation(
        'Downloading $fileName...',
        contentTitle: 'Downloading',
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
      'Downloading $fileName',
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
    cancelAllNotifications();
    super.dispose();
  }
}
