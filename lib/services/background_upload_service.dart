import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import '../models/disbox_file.dart';

/// Callback function for background upload tasks.
/// This runs in a separate isolate, so it must be a top-level function.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    debugPrint('Background task started: $task');
    debugPrint('Input data: $inputData');
    
    try {
      // Initialize Hive for background task
      await Hive.initFlutter();
      
      final filePath = inputData?['filePath'] as String?;
      final webhookUrl = inputData?['webhookUrl'] as String?;
      final folderPath = inputData?['folderPath'] as String? ?? '/';
      final fileName = inputData?['fileName'] as String?;
      final accountId = inputData?['accountId'] as String?;
      
      if (filePath == null || webhookUrl == null || fileName == null) {
        debugPrint('Missing required input data');
        return Future.value(false);
      }
      
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('File does not exist: $filePath');
        return Future.value(false);
      }
      
      // Perform the upload using Dio directly
      final result = await _uploadFileInBackground(
        file,
        webhookUrl,
        folderPath,
        fileName,
        accountId,
      );
      
      debugPrint('Background upload completed: $result');
      return Future.value(result);
    } catch (e) {
      debugPrint('Background task error: $e');
      return Future.value(false);
    }
  });
}

/// Upload a file in the background isolate.
Future<bool> _uploadFileInBackground(
  File file,
  String webhookUrl,
  String folderPath,
  String fileName,
  String? accountId,
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
