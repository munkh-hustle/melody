import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:typed_data';
import '../models/disbox_file.dart';

/// Initialize background service for uploads.
@pragma('vm:entry-point')
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'disbox_upload_channel',
      initialNotificationTitle: 'Disbox Upload',
      initialNotificationContent: 'Initializing...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(),
  );
}

/// Background service entry point.
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // DartPluginRegistrant is not needed for flutter_background_service
  // The plugin handles isolate initialization automatically
  
  // Create notification channel and show initial notification
  // Use invoke to update notification since setForegroundNotificationInfo doesn't exist
  service.invoke('notification', {
    'title': 'Disbox Upload',
    'content': 'Initializing...',
  });
  
  service.on('upload').listen((event) async {
    final filePath = event!['filePath'] as String;
    final webhookUrl = event['webhookUrl'] as String;
    final folderPath = event['folderPath'] as String? ?? '/';
    final fileName = event['fileName'] as String;
    final accountId = event['accountId'] as String?;
    
    debugPrint('Background upload started: $fileName');
    
    // Update notification to show upload starting
    service.invoke('notification', {
      'title': 'Uploading $fileName',
      'content': 'Starting upload...',
    });
    
    try {
      // Initialize Hive
      await Hive.initFlutter();
      
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('File does not exist: $filePath');
        service.invoke('error', {'message': 'File not found'});
        service.invoke('notification', {
          'title': 'Upload Failed',
          'content': 'File not found: $fileName',
        });
        return;
      }
      
      // Perform upload
      final result = await _uploadFileInBackground(
        file,
        webhookUrl,
        folderPath,
        fileName,
        accountId,
        service, // Pass service for progress updates
      );
      
      if (result) {
        service.invoke('complete', {'success': true});
        debugPrint('Background upload completed successfully');
        service.invoke('notification', {
          'title': 'Upload Complete',
          'content': '$fileName uploaded successfully',
        });
      } else {
        service.invoke('complete', {'success': false});
        debugPrint('Background upload failed');
        service.invoke('notification', {
          'title': 'Upload Failed',
          'content': 'Failed to upload $fileName',
        });
      }
    } catch (e) {
      debugPrint('Background upload error: $e');
      service.invoke('error', {'message': e.toString()});
      service.invoke('notification', {
        'title': 'Upload Error',
        'content': 'Error: ${e.toString()}',
      });
    } finally {
      // Stop the service after completion
      await Future.delayed(const Duration(seconds: 2)); // Delay to let user see notification
      await service.stopSelf();
    }
  });
}

/// Callback function for background upload tasks.
/// This runs in a separate isolate, so it must be a top-level function.
@pragma('vm:entry-point')
void callbackDispatcher() {
  // This is kept for compatibility but not used with flutter_background_service
}

/// Upload a file in the background isolate.
Future<bool> _uploadFileInBackground(
  File file,
  String webhookUrl,
  String folderPath,
  String fileName,
  String? accountId,
  ServiceInstance? service, // Optional service for progress updates
) async {
  final dio = Dio();
  
  try {
    // Extract webhook ID and token from URL
    final uri = Uri.parse(webhookUrl);
    final pathSegments = uri.pathSegments;
    
    if (pathSegments.length < 5) {
      debugPrint('Invalid webhook URL format');
      return false;
    }
    
    final webhookId = pathSegments[4];
    final webhookToken = pathSegments[5];
    
    // Generate file ID
    final fileBytes = await file.readAsBytes();
    final hash = sha256.convert(fileBytes).toString();
    final fileId = '${accountId ?? 'unknown'}_${hash.substring(0, 16)}';
    
    final fileSize = fileBytes.length;
    const chunkSize = 20 * 1024 * 1024; // 20MB chunks
    
    debugPrint('Starting background upload: $fileName (${fileSize} bytes)');
    
    // Update notification with file size
    final fileSizeMB = (fileSize / (1024 * 1024)).toStringAsFixed(1);
    service?.invoke('notification', {
      'title': 'Uploading $fileName',
      'content': '$fileSizeMB MB - Starting...',
    });
    
    // For small files, upload directly
    if (fileSize <= chunkSize) {
      // Create metadata
      final metadata = {
        'type': 'disbox_metadata',
        'version': '1.0',
        'name': fileName,
        'size': fileSize,
        'path': folderPath,
        'chunks': 1,
        'id': fileId,
        'mimeType': _getMimeType(fileName),
        'uploadedAt': DateTime.now().toIso8601String(),
        'accountId': accountId,
      };
      
      final metadataJson = jsonEncode(metadata);
      final metadataBytes = utf8.encode(metadataJson);
      
      // Create form data
      final formData = FormData();
      formData.files.add(MapEntry(
        'file',
        MultipartFile.fromBytes(
          metadataBytes,
          filename: '[DISBOX] $fileName.meta.json',
        ),
      ));
      
      // Upload metadata
      final metadataResponse = await dio.post(
        webhookUrl,
        data: formData,
      );
      
      if (metadataResponse.statusCode != 200 && metadataResponse.statusCode != 201) {
        debugPrint('Metadata upload failed: ${metadataResponse.statusCode}');
        return false;
      }
      
      // Calculate number of chunks
      final numChunks = (fileSize / chunkSize).ceil();
      
      // Upload file chunks
      for (int i = 0; i < numChunks; i++) {
        final start = i * chunkSize;
        final end = ((i + 1) * chunkSize > fileSize) ? fileSize : (i + 1) * chunkSize;
        final chunk = fileBytes.sublist(start, end);
        
        final chunkFormData = FormData();
        chunkFormData.files.add(MapEntry(
          'file',
          MultipartFile.fromBytes(
            chunk,
            filename: '$fileName.chunk.$i',
          ),
        ));
        
        final chunkResponse = await dio.post(
          webhookUrl,
          data: chunkFormData,
        );
        
        if (chunkResponse.statusCode != 200 && chunkResponse.statusCode != 201) {
          debugPrint('Chunk $i upload failed: ${chunkResponse.statusCode}');
          return false;
        }
        
        debugPrint('Chunk $i/${numChunks - 1} uploaded');
        
        // Update notification with progress
        final progress = ((i + 1) / numChunks * 100).toInt();
        service?.invoke('notification', {
          'title': 'Uploading $fileName',
          'content': '$progress% complete',
        });
      }
      
      debugPrint('Background upload completed successfully');
      return true;
    } else {
      // For large files, implement chunked reading
      debugPrint('Large file upload - reading in chunks');
      
      final numChunks = (fileSize / chunkSize).ceil();
      
      // Upload metadata first
      final metadata = {
        'type': 'disbox_metadata',
        'version': '1.0',
        'name': fileName,
        'size': fileSize,
        'path': folderPath,
        'chunks': numChunks,
        'id': fileId,
        'mimeType': _getMimeType(fileName),
        'uploadedAt': DateTime.now().toIso8601String(),
        'accountId': accountId,
      };
      
      final metadataJson = jsonEncode(metadata);
      final metadataBytes = utf8.encode(metadataJson);
      
      final metadataFormData = FormData();
      metadataFormData.files.add(MapEntry(
        'file',
        MultipartFile.fromBytes(
          metadataBytes,
          filename: '[DISBOX] $fileName.meta.json',
        ),
      ));
      
      final metadataResponse = await dio.post(
        webhookUrl,
        data: metadataFormData,
      );
      
      if (metadataResponse.statusCode != 200 && metadataResponse.statusCode != 201) {
        debugPrint('Metadata upload failed: ${metadataResponse.statusCode}');
        return false;
      }
      
      // Read and upload chunks
      final randomAccessFile = await file.open();
      try {
        for (int i = 0; i < numChunks; i++) {
          final start = i * chunkSize;
          final length = ((i + 1) * chunkSize > fileSize) 
              ? fileSize - start 
              : chunkSize;
          
          final chunk = Uint8List(length);
          await randomAccessFile.setPosition(start);
          await randomAccessFile.readInto(chunk);
          
          final chunkFormData = FormData();
          chunkFormData.files.add(MapEntry(
            'file',
            MultipartFile.fromBytes(
              chunk,
              filename: '$fileName.chunk.$i',
            ),
          ));
          
          final chunkResponse = await dio.post(
            webhookUrl,
            data: chunkFormData,
          );
          
          if (chunkResponse.statusCode != 200 && chunkResponse.statusCode != 201) {
            debugPrint('Chunk $i upload failed: ${chunkResponse.statusCode}');
            return false;
          }
          
          debugPrint('Chunk $i/${numChunks - 1} uploaded');
          
          // Update notification with progress
          final progress = ((i + 1) / numChunks * 100).toInt();
          service?.invoke('notification', {
            'title': 'Uploading $fileName',
            'content': '$progress% complete ($fileSizeMB MB)',
          });
        }
      } finally {
        await randomAccessFile.close();
      }
      
      debugPrint('Large file background upload completed successfully');
      return true;
    }
  } catch (e) {
    debugPrint('Background upload error: $e');
    return false;
  }
}

String _getMimeType(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'mp4':
      return 'video/mp4';
    case 'avi':
      return 'video/avi';
    case 'mkv':
      return 'video/x-matroska';
    case 'mp3':
      return 'audio/mpeg';
    case 'wav':
      return 'audio/wav';
    case 'pdf':
      return 'application/pdf';
    case 'txt':
      return 'text/plain';
    case 'json':
      return 'application/json';
    default:
      return 'application/octet-stream';
  }
}
