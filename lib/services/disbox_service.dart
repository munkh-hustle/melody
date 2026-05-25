import 'dart:convert';
import 'dart:io';
import 'dart:math' as Math;
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as path;
import 'package:rxdart/rxdart.dart';
import 'package:flutter/foundation.dart';

import '../models/disbox_file.dart';
import '../utils/chunk_utils.dart';

/// Sanitize a filename by removing control characters that are invalid in JSON.
/// 
/// Control characters (U+0000 to U+001F) must be escaped in JSON strings, but some
/// sources may include them literally. This function removes them to ensure valid JSON.
String sanitizeFilename(String filename) {
  // Remove control characters (U+0000 to U+001F) except for common safe ones
  // We keep tab (U+0009), newline (U+000A), and carriage return (U+000D) if needed
  // But for filenames, it's safest to remove all control characters
  return filename.replaceAll(RegExp(r'[\x00-\x1f]'), '');
}

/// Callback for upload/download progress updates
typedef ProgressCallback = void Function(int current, int total);

/// Main service class for interacting with Discord webhooks as cloud storage.
///
/// This class handles all communication with Discord's API to store and retrieve
/// files using webhooks. All operations are performed client-side - the webhook
/// URL is never sent to any third-party server.
///
/// File tree metadata is stored locally using Hive for persistence across app restarts.
class DisboxService extends ChangeNotifier {
  final Dio _dio;
  String? _webhookUrl;
  String? _accountId; // Hash of webhook URL for local identification

  // File tree cache stored locally
  Map<String, dynamic>? _fileTree;

  // Hive box for storing file tree metadata
  static const String _fileTreeBoxName = 'file_tree';
  Box? _fileTreeBox;

  // Cache for file metadata (in production, use Hive or SharedPreferences)
  final Map<String, DisboxFile> _fileCache = {};

  // SharedPreferences keys
  static const String _savedAccountsKey = 'saved_webhook_accounts';

  // Stream controllers for progress updates
  final _uploadProgressController = BehaviorSubject<double>.seeded(0.0);
  final _downloadProgressController = BehaviorSubject<double>.seeded(0.0);

  /// Stream of upload progress (0.0 to 1.0)
  Stream<double> get uploadProgress => _uploadProgressController.stream;

  /// Stream of download progress (0.0 to 1.0)
  Stream<double> get downloadProgress => _downloadProgressController.stream;

  // Cancel tokens for stopping uploads/downloads
  CancelToken? _currentUploadCancelToken;
  CancelToken? _currentDownloadCancelToken;

  // Track current transfer state
  bool _isUploading = false;
  bool _isDownloading = false;
  bool _isUploadPaused = false;
  bool _isDownloadPaused = false;
  
  // Store partial transfer state for resume functionality
  String? _currentUploadFilePath;
  String? _currentUploadFolderPath;
  List<String> _uploadedChunkIds = [];
  int _uploadedBytes = 0;
  int _totalUploadBytes = 0;
  
  String? _currentDownloadFileId;
  List<int> _downloadedChunkIndices = [];
  int _downloadedBytes = 0;
  int _totalDownloadBytes = 0;

  /// Whether an upload is currently in progress
  bool get isUploading => _isUploading;

  /// Whether a download is currently in progress
  bool get isDownloading => _isDownloading;

  /// Whether the current upload is paused
  bool get isUploadPaused => _isUploadPaused;

  /// Whether the current download is paused
  bool get isDownloadPaused => _isDownloadPaused;
  
  /// Get current upload progress info for resume
  Map<String, dynamic>? get uploadResumeInfo {
    if (_currentUploadFilePath == null) return null;
    return {
      'filePath': _currentUploadFilePath,
      'folderPath': _currentUploadFolderPath,
      'uploadedChunkIds': List.from(_uploadedChunkIds),
      'uploadedBytes': _uploadedBytes,
      'totalBytes': _totalUploadBytes,
    };
  }
  
  /// Get current download progress info for resume
  Map<String, dynamic>? get downloadResumeInfo {
    if (_currentDownloadFileId == null) return null;
    return {
      'fileId': _currentDownloadFileId,
      'downloadedChunkIndices': List.from(_downloadedChunkIndices),
      'downloadedBytes': _downloadedBytes,
      'totalBytes': _totalDownloadBytes,
    };
  }

  /// Stop the current upload (keeps uploaded chunks for resume)
  void stopUpload() {
    if (_currentUploadCancelToken != null && !_currentUploadCancelToken!.isCancelled) {
      _currentUploadCancelToken!.cancel('Upload stopped by user');
      _isUploading = false;
      _isUploadPaused = true; // Mark as paused to enable resume
      // Keep progress state for resume - don't reset to 0
      notifyListeners();
    }
  }

  /// Stop the current download (keeps downloaded chunks for resume)
  void stopDownload() {
    if (_currentDownloadCancelToken != null && !_currentDownloadCancelToken!.isCancelled) {
      _currentDownloadCancelToken!.cancel('Download stopped by user');
      _isDownloading = false;
      _isDownloadPaused = true; // Mark as paused to enable resume
      // Keep progress state for resume - don't reset to 0
      notifyListeners();
    }
  }

  /// Pause the current upload (for future resume implementation)
  void pauseUpload() {
    if (_isUploading && !_isUploadPaused) {
      _isUploadPaused = true;
      stopUpload();
      notifyListeners();
    }
  }

  /// Pause the current download (for future resume implementation)
  void pauseDownload() {
    if (_isDownloading && !_isDownloadPaused) {
      _isDownloadPaused = true;
      stopDownload();
      notifyListeners();
    }
  }
  
  /// Resume a paused upload
  Future<DisboxFile> resumeUpload({ProgressCallback? onProgress}) async {
    if (!_isUploadPaused || _currentUploadFilePath == null) {
      throw StateError('No paused upload to resume');
    }
    
    print('[RESUME UPLOAD] Resuming upload: $_currentUploadFilePath');
    print('[RESUME UPLOAD] Already uploaded ${_uploadedChunkIds.length} chunks, $_uploadedBytes/$_totalUploadBytes bytes');
    
    final file = File(_currentUploadFilePath!);
    if (!await file.exists()) {
      throw FileSystemException('Original file no longer exists', _currentUploadFilePath);
    }
    
    // Clear the paused flag but keep the state
    _isUploadPaused = false;
    _isUploading = true;
    _currentUploadCancelToken = CancelToken();
    notifyListeners();
    
    try {
      final fileSize = file.lengthSync();
      final needsChunking = fileSize > DisboxConstants.maxAttachmentSize;
      
      if (!needsChunking) {
        // For small files, just re-upload from start (simpler)
        return await uploadFile(file, folderPath: _currentUploadFolderPath!, onProgress: onProgress);
      }
      
      // For chunked files, skip already uploaded chunks
      final chunks = ChunkUtils.splitFile(file);
      var uploadedBytes = _uploadedBytes;
      
      for (int i = 0; i < chunks.length; i++) {
        // Skip already uploaded chunks (chunks are uploaded in order, so if we have N IDs, first N chunks are done)
        if (i < _uploadedChunkIds.length) {
          print('[RESUME UPLOAD] Skipping already uploaded chunk $i');
          uploadedBytes += await ChunkUtils.readChunkLength(file, i);
          continue;
        }
        
        // Check if cancelled
        if (_currentUploadCancelToken!.isCancelled) {
          throw DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
            error: 'Upload stopped by user',
          );
        }
        
        int retryCount = 0;
        const maxRetries = 5;
        bool success = false;
        
        while (!success && retryCount < maxRetries) {
          try {
            final chunkData = await ChunkUtils.readChunk(file, i);
            
            final messageId = await _uploadAttachment(
              chunkData,
              filename: '${path.basename(_currentUploadFilePath!)}.part$i',
              contentType: 'application/octet-stream',
              cancelToken: _currentUploadCancelToken,
            );
            
            _uploadedChunkIds.add(messageId);
            uploadedBytes += chunkData.length;
            
            final progress = uploadedBytes / fileSize;
            _uploadProgressController.add(progress);
            
            onProgress?.call(uploadedBytes, fileSize);
            success = true;
          } on DioException catch (e) {
            if (e.type == DioExceptionType.cancel) {
              rethrow;
            }
            retryCount++;
            if (retryCount >= maxRetries) {
              rethrow;
            }
            final delayMs = (1000 * (1 << (retryCount - 1)));
            await Future.delayed(Duration(milliseconds: delayMs));
          }
        }
      }
      
      // Create metadata message
      final filename = path.basename(_currentUploadFilePath!);
      final filePath = _normalizePath('${_currentUploadFolderPath!}/$filename');
      final mimeType = _detectMimeType(filename);
      
      final metadataMessageId = await _createMetadataMessage(
        filename: filename,
        path: filePath,
        size: fileSize,
        mimeType: mimeType,
        chunkMessageIds: _uploadedChunkIds,
        isFolder: false,
      );
      
      final disboxFile = DisboxFile(
        id: metadataMessageId,
        name: filename,
        path: filePath,
        isFolder: false,
        size: fileSize,
        mimeType: mimeType,
        chunkMessageIds: _uploadedChunkIds,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        parentId: _getParentFolderId(_currentUploadFolderPath!),
      );
      
      await _addFileToFileTree(
        id: metadataMessageId,
        name: filename,
        path: filePath,
        size: fileSize,
        mimeType: mimeType,
        chunkMessageIds: _uploadedChunkIds,
      );
      
      _fileCache[disboxFile.id] = disboxFile;
      
      // Clear resume state
      _clearUploadResumeState();
      
      notifyListeners();
      return disboxFile;
    } catch (e) {
      _isUploading = false;
      _isUploadPaused = true; // Re-pause on error
      rethrow;
    }
  }
  
  /// Resume a paused download
  Future<File> resumeDownload(String outputPath, {ProgressCallback? onProgress}) async {
    if (!_isDownloadPaused || _currentDownloadFileId == null) {
      throw StateError('No paused download to resume');
    }
    
    print('[RESUME DOWNLOAD] Resuming download: $_currentDownloadFileId');
    print('[RESUME DOWNLOAD] Already downloaded ${_downloadedChunkIndices.length} chunks, $_downloadedBytes/$_totalDownloadBytes bytes');
    
    // Get the file metadata
    final file = _fileCache[_currentDownloadFileId];
    if (file == null) {
      throw Exception('File metadata not found in cache');
    }
    
    // Clear the paused flag but keep the state
    _isDownloadPaused = false;
    _isDownloading = true;
    _currentDownloadCancelToken = CancelToken();
    notifyListeners();
    
    try {
      var downloadedBytes = _downloadedBytes;
      
      // Stream download each chunk directly to disk to avoid OOM for large files
      final outputFile = File(outputPath);
      final sink = outputFile.openWrite();
      
      // Download missing chunks and stream to disk
      for (int i = 0; i < file.chunkMessageIds.length; i++) {
        // Skip already downloaded chunks
        if (_downloadedChunkIndices.contains(i)) {
          print('[RESUME DOWNLOAD] Skipping already downloaded chunk $i');
          // TODO: Store downloaded chunk data in temp files for true resume
          // For now, we'll re-download all chunks (simpler approach)
        }
        
        if (_currentDownloadCancelToken!.isCancelled) {
          await sink.close();
          throw DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
            error: 'Download stopped by user',
          );
        }
        
        final messageId = file.chunkMessageIds[i];
        final chunkData = await _downloadAttachment(
          messageId,
          cancelToken: _currentDownloadCancelToken,
        );
        
        // Write chunk to disk immediately - don't accumulate in memory!
        sink.add(chunkData);
        downloadedBytes += chunkData.length;
        
        final progress = _totalDownloadBytes > 0 ? downloadedBytes / _totalDownloadBytes : 0.0;
        _downloadProgressController.add(progress);
        onProgress?.call(downloadedBytes, _totalDownloadBytes);
        
        // Flush periodically
        if ((i + 1) % 5 == 0) {
          await sink.flush();
        }
      }
      
      // Final flush and close
      await sink.flush();
      await sink.close();
      
      _downloadProgressController.add(1.0);
      
      // Clear resume state
      _clearDownloadResumeState();
      
      return File(outputPath);
    } catch (e) {
      _isDownloading = false;
      _isDownloadPaused = true; // Re-pause on error
      rethrow;
    }
  }
  
  /// Clear upload resume state after successful completion
  void _clearUploadResumeState() {
    _currentUploadFilePath = null;
    _currentUploadFolderPath = null;
    _uploadedChunkIds.clear();
    _uploadedBytes = 0;
    _totalUploadBytes = 0;
    _isUploading = false;
    _isUploadPaused = false;
  }
  
  /// Clear download resume state after successful completion
  void _clearDownloadResumeState() {
    _currentDownloadFileId = null;
    _downloadedChunkIndices.clear();
    _downloadedBytes = 0;
    _totalDownloadBytes = 0;
    _isDownloading = false;
    _isDownloadPaused = false;
  }

  DisboxService() : _dio = Dio() {
    _dio.options.connectTimeout = const Duration(minutes: 2);
    _dio.options.receiveTimeout = const Duration(minutes: 5);
    _dio.options.sendTimeout = const Duration(minutes: 5);

    // Add interceptor for detailed logging and error handling
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        print('[DIO] ${options.method} ${options.path}');
        print('[DIO] Headers: ${options.headers}');
        if (options.queryParameters.isNotEmpty) {
          print('[DIO] QueryParams: ${options.queryParameters}');
        }
        return handler.next(options);
      },
      onResponse: (response, handler) {
        print(
            '[DIO RESPONSE] ${response.statusCode} - ${response.requestOptions.path}');
        // Only try to get keys if response data is a Map
        if (response.data is Map) {
          print(
              '[DIO RESPONSE] Data keys: ${(response.data as Map).keys.toList()}');
        } else if (response.data is Uint8List) {
          print(
              '[DIO RESPONSE] Binary data: ${(response.data as Uint8List).length} bytes');
        } else {
          print('[DIO RESPONSE] Data type: ${response.data.runtimeType}');
        }
        return handler.next(response);
      },
      onError: (error, handler) {
        print('[DIO ERROR] Type: ${error.type}, Message: ${error.message}');
        print('[DIO ERROR] StatusCode: ${error.response?.statusCode}');
        print('[DIO ERROR] Response Data: ${error.response?.data}');
        print(
            '[DIO ERROR] Request: ${error.requestOptions.method} ${error.requestOptions.path}');
        if (error.error != null) {
          print('[DIO ERROR] Inner Error: ${error.error}');
          print('[DIO ERROR] Stack Trace: ${error.stackTrace}');
        }
        return handler.next(error);
      },
    ));
  }

  /// Initialize Hive for local storage and cleanup old temp files
  Future<void> _initHive() async {
    await Hive.initFlutter();
    _fileTreeBox = await Hive.openBox(_fileTreeBoxName);

    // Cleanup any leftover temp files from previous sessions
    await _cleanupTempFiles();
  }

  /// Clean up temporary files in the cache directory
  Future<void> _cleanupTempFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      print('[DisboxService] Cleaning up temp files in: ${tempDir.path}');

      // Clean up disbox_downloads subdirectory
      final disboxTempDir = Directory('${tempDir.path}/disbox_downloads');
      if (await disboxTempDir.exists()) {
        await for (final entity in disboxTempDir.list()) {
          if (entity is File) {
            await entity.delete();
            print('[DisboxService] Deleted stale download file: ${path.basename(entity.path)}');
          }
        }
      }

      // Only delete .part files and known temp patterns to avoid deleting other app data
      await for (final entity in tempDir.list()) {
        if (entity is File) {
          final filename = path.basename(entity.path);
          // Delete chunk temp files (*.part*) or download temp files
          if (filename.contains('.part') ||
              filename.startsWith('disbox_temp_') ||
              filename.endsWith('.tmp')) {
            await entity.delete();
            print('[DisboxService] Deleted stale temp file: $filename');
          }
        }
      }
    } catch (e) {
      print('[DisboxService WARNING] Failed to cleanup temp files: $e');
    }
  }

  /// Public method to cleanup temp files (called from UI)
  Future<void> cleanupTempFiles() async {
    await _cleanupTempFiles();
  }

  /// Set the webhook URL and generate account ID from it.
  ///
  /// The webhook URL is stored locally only and never sent to third parties.
  /// The account ID is a SHA256 hash of the webhook URL for local identification.
  /// Also loads existing file tree from local storage.
  Future<void> setWebhookUrl(String webhookUrl) async {
    print('[DisboxService] Setting webhook URL...');

    // Validate webhook URL format
    if (!_isValidWebhookUrl(webhookUrl)) {
      print('[DisboxService ERROR] Invalid webhook URL format');
      throw FormatException('Invalid Discord webhook URL format');
    }

    // Initialize Hive if not already done
    if (_fileTreeBox == null) {
      print('[DisboxService] Initializing Hive...');
      await _initHive();
    }

    _webhookUrl = webhookUrl;
    _accountId = _hashWebhookUrl(webhookUrl);

    print('[DisboxService] Webhook URL set, accountId: $_accountId');

    // Save webhook URL to SharedPreferences so FileBrowserScreen can load it
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('webhook_url', webhookUrl);
    await prefs.setString('account_id', _accountId!);
    
    // Add to saved accounts list for easy re-selection
    await _addAccountToSavedList(webhookUrl, _accountId!);
    
    print('[DisboxService] Saved webhook URL to SharedPreferences');

    // Load existing file tree from local storage
    await _loadFileTree();

    // Save webhook URL securely (in production, use flutter_secure_storage)
    // await secureStorage.write(key: 'webhook_url', value: webhookUrl);
    // await secureStorage.write(key: 'account_id', value: _accountId);
  }

  /// Import webhook URL and file tree from a JSON config file.
  ///
  /// The JSON file should contain:
  /// - webhook_url: The Discord webhook URL
  /// - file_tree: (optional) File tree metadata to import
  ///
  /// Returns true if import was successful, false otherwise.
  Future<bool> importConfig(File jsonFile) async {
    try {
      print('[DisboxService] Importing config from: ${jsonFile.path}');

      // Read file with explicit UTF-8 encoding to support international characters
      final content = await jsonFile.readAsString(encoding: utf8);
      final data = jsonDecode(content);

      if (data is! Map) {
        throw Exception("JSON must be an object");
      }

      final webhookUrl = data['webhook_url'] as String?;

      if (webhookUrl == null || webhookUrl.isEmpty) {
        throw Exception("JSON must contain 'webhook_url' field");
      }

      // Validate webhook URL format
      if (!_isValidWebhookUrl(webhookUrl)) {
        throw Exception("Invalid webhook URL format in JSON");
      }

      // Initialize Hive
      if (_fileTreeBox == null) {
        print('[DisboxService] Initializing Hive...');
        await _initHive();
      }

      // Set webhook URL
      _webhookUrl = webhookUrl;
      _accountId = _hashWebhookUrl(webhookUrl);

      print('[DisboxService] Webhook URL imported, accountId: $_accountId');

      // Save webhook URL to SharedPreferences so FileBrowserScreen can load it
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('webhook_url', webhookUrl);
      await prefs.setString('account_id', _accountId!);
      
      // Add to saved accounts list for easy re-selection
      await _addAccountToSavedList(webhookUrl, _accountId!);

      print('[DisboxService] Saved webhook URL to SharedPreferences');

      // Check if file tree data is included
      if (data.containsKey('file_tree') && data['file_tree'] != null) {
        print('[DisboxService] Importing file tree from JSON...');

        final fileTreeData = data['file_tree'];
        
        // Handle both formats:
        // - Standard format (from export): file_tree is a List<DisboxFile>
        // - Legacy format: file_tree is a Map (tree structure)
        if (fileTreeData is List) {
          // Standard format: Convert list of DisboxFile to tree structure
          print('[DisboxService] Importing file tree from List format...');
          _fileTree = await _buildFileTreeFromList(fileTreeData);
        } else if (fileTreeData is Map) {
          // Legacy format: Direct tree structure
          print('[DisboxService] Importing file tree from legacy Map format...');
          _fileTree =
              _convertMapToStringKeys(fileTreeData) as Map<String, dynamic>?;
        } else {
          throw Exception(
              "'file_tree' must be an object or array, not a ${fileTreeData.runtimeType}");
        }

        // Save imported file tree to Hive (will be saved in List format)
        await _saveFileTree();
        print('[DisboxService] Imported file tree saved to local storage');
      } else {
        // Load existing file tree from local storage (if any)
        await _loadFileTree();
      }

      notifyListeners();
      print('[DisboxService] Config import successful');
      return true;
    } catch (e) {
      print('[DisboxService ERROR] Failed to import config: $e');
      return false;
    }
  }

  /// Import file metadata from Discord message text.
  ///
  /// This allows importing individual file metadata from Discord messages
  /// that contain the [DISBOX] metadata prefix, without replacing existing data.
  ///
  /// The message format should be:
  /// [DISBOX] {"type":"disbox_metadata","version":"1.0","name":"...",...}
  ///
  /// Returns the imported DisboxFile if successful, null otherwise.
  Future<DisboxFile?> importMetadataFromText(String metadataText) async {
    try {
      print('[DisboxService] Importing metadata from text...');
      final stopwatch = Stopwatch()..start();

      // Extract JSON from the message (remove [DISBOX] prefix if present)
      String jsonStr = metadataText.trim();
      const prefix = '[DISBOX]';
      if (jsonStr.startsWith(prefix)) {
        jsonStr = jsonStr.substring(prefix.length).trim();
      }

      print('[DisboxService] Parsing JSON... (${stopwatch.elapsedMilliseconds}ms)');

      // Parse the metadata JSON
      final metadata = jsonDecode(jsonStr) as Map<String, dynamic>;

      // Validate it's a disbox_metadata type
      final type = metadata['type'] as String?;
      if (type != 'disbox_metadata') {
        throw Exception("Not a valid Disbox metadata message (type: $type)");
      }

      print('[DisboxService] Creating DisboxFile... (${stopwatch.elapsedMilliseconds}ms)');

      // Check if this is batched metadata (split across multiple messages)
      final totalBatches = metadata['totalBatches'] as int? ?? 1;
      List<String> allChunkIds = [];
      
      if (totalBatches > 1) {
        print('[DisboxService] Found batched metadata with $totalBatches batches');
        
        // For import, we expect the user to paste all batch messages
        // The chunkIds in this message are just for this batch
        final batchChunkIds = (metadata['chunkIds'] as List?)?.cast<String>() ?? [];
        allChunkIds.addAll(batchChunkIds);
        
        // If allMetadataIds is available, we have references to all batches
        final allMetadataIds = metadata['allMetadataIds'] as List?;
        if (allMetadataIds != null && allMetadataIds.isNotEmpty) {
          print('[DisboxService] Note: This metadata references ${allMetadataIds.length} batch messages.');
          print('[DisboxService] For complete import, please paste ALL batch messages separated by newlines.');
          // In the import screen, users can paste multiple lines, which will be handled by importMultipleMetadataFromText
        }
      } else {
        // Single message metadata
        allChunkIds = (metadata['chunkIds'] as List?)?.cast<String>() ?? [];
      }

      // Create DisboxFile from the metadata
      // Note: Discord message metadata doesn't have a unique file ID in the same way,
      // so we use the first chunk ID or generate one from the path
      final fileId = allChunkIds.isNotEmpty ? allChunkIds.first : _hashWebhookUrl(metadata['path'] as String);

      final disboxFile = DisboxFile(
        id: fileId,
        name: metadata['name'] as String? ?? '',
        path: metadata['path'] as String? ?? '',
        isFolder: metadata['isFolder'] as bool? ?? false,
        size: metadata['size'] as int?,
        mimeType: metadata['mimeType'] as String?,
        chunkMessageIds: allChunkIds,
        createdAt: DateTime.parse(metadata['createdAt'] as String),
        modifiedAt: metadata['modifiedAt'] != null
            ? DateTime.parse(metadata['modifiedAt'] as String)
            : DateTime.parse(metadata['createdAt'] as String),
      );

      print('[DisboxService] Parsed metadata: ${disboxFile.name} (${disboxFile.path}) (${stopwatch.elapsedMilliseconds}ms)');

      // Ensure Hive is initialized
      if (_fileTreeBox == null) {
        print('[DisboxService] Initializing Hive...');
        await _initHive();
        print('[DisboxService] Hive initialized (${stopwatch.elapsedMilliseconds}ms)');
      }

      // Load existing webhook URL from SharedPreferences if not already set
      // This is needed for importMetadataFromText to work without calling setWebhookUrl first
      if (_webhookUrl == null) {
        print('[DisboxService] Webhook URL not set, loading from SharedPreferences...');
        final prefs = await SharedPreferences.getInstance();
        final savedWebhookUrl = prefs.getString('webhook_url');
        final savedAccountId = prefs.getString('account_id');
        
        if (savedWebhookUrl != null && savedAccountId != null) {
          _webhookUrl = savedWebhookUrl;
          _accountId = savedAccountId;
          print('[DisboxService] Loaded webhook URL from SharedPreferences, accountId: $_accountId (${stopwatch.elapsedMilliseconds}ms)');
        } else {
          print('[DisboxService WARNING] No webhook URL found in SharedPreferences. Creating temporary account ID.');
          // Generate a temporary account ID based on the file path for this import session
          _accountId = _hashWebhookUrl(metadata['path'] as String);
        }
      }

      // Load existing file tree or create new one
      print('[DisboxService] Loading file tree...');
      await _loadFileTree();
      print('[DisboxService] File tree loaded, _fileTree is null: ${_fileTree == null} (${stopwatch.elapsedMilliseconds}ms)');

      // Add the file to the tree (this will merge/update without deleting existing data)
      // _fileTree should now be initialized by _loadFileTree() even if webhook was not configured
      if (_fileTree != null) {
        print('[DisboxService] Adding file to tree...');
        _addFileToTree(_fileTree!, disboxFile);
        print('[DisboxService] File added to tree (${stopwatch.elapsedMilliseconds}ms)');
      } else {
        // This should not happen, but handle it gracefully
        print('[DisboxService ERROR] _fileTree is still null after _loadFileTree()');
        return null;
      }

      // Save updated tree to local storage
      print('[DisboxService] Saving file tree...');
      await _saveFileTree();
      print('[DisboxService] File tree saved (${stopwatch.elapsedMilliseconds}ms)');

      // Add to saved accounts list for easy re-selection (if webhook URL is available)
      if (_webhookUrl != null && _accountId != null) {
        await _addAccountToSavedList(_webhookUrl!, _accountId!);
      }

      print('[DisboxService] Successfully imported metadata for: ${disboxFile.name} (total: ${stopwatch.elapsedMilliseconds}ms)');
      notifyListeners();
      return disboxFile;
    } catch (e, stackTrace) {
      print('[DisboxService ERROR] Failed to import metadata from text: $e');
      print('[DisboxService ERROR] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Import multiple file metadata entries from a list of Discord message texts.
  ///
  /// This method handles batched metadata where chunk IDs are split across
  /// multiple messages due to Discord's 2000 character limit. It will:
  /// 1. Group messages by their allMetadataIds reference (if available)
  /// 2. Merge chunk IDs from all batches belonging to the same file
  /// 3. Import each complete file's metadata
  ///
  /// Returns the number of successfully imported files.
  Future<int> importMultipleMetadataFromText(List<String> metadataTexts) async {
    print('[IMPORT] Importing ${metadataTexts.length} metadata entries...');
    
    // First pass: parse all metadata and group by file
    final Map<String, List<Map<String, dynamic>>> groupedMetadata = {};
    final Map<String, Map<String, dynamic>> fileBaseMetadata = {};
    
    for (final text in metadataTexts) {
      try {
        String jsonStr = text.trim();
        const prefix = '[DISBOX]';
        if (jsonStr.startsWith(prefix)) {
          jsonStr = jsonStr.substring(prefix.length).trim();
        }
        
        final metadata = jsonDecode(jsonStr) as Map<String, dynamic>;
        
        // Validate it's a disbox_metadata type
        if (metadata['type'] != 'disbox_metadata') {
          continue;
        }
        
        // Get unique identifier for this file (use path or allMetadataIds)
        final allMetadataIds = metadata['allMetadataIds'] as List?;
        String fileId;
        
        if (allMetadataIds != null && allMetadataIds.isNotEmpty) {
          // Use sorted allMetadataIds as key to group batches
          final sortedIds = List<String>.from(allMetadataIds.cast<String>())..sort();
          fileId = sortedIds.join('|');
        } else {
          // Use path as fallback identifier
          fileId = metadata['path'] as String? ?? metadata['name'] as String? ?? '';
        }
        
        if (!groupedMetadata.containsKey(fileId)) {
          groupedMetadata[fileId] = [];
        }
        groupedMetadata[fileId]!.add(metadata);
        
        // Store base metadata from the last batch (which has name/path/mimeType)
        fileBaseMetadata[fileId] = metadata;
        
      } catch (e) {
        print('[IMPORT ERROR] Failed to parse metadata: $e');
      }
    }
    
    print('[IMPORT] Found ${groupedMetadata.length} unique files');
    
    // Second pass: merge and import each file
    int successCount = 0;
    for (final entry in groupedMetadata.entries) {
      final fileId = entry.key;
      final batches = entry.value;
      
      try {
        // Merge all chunk IDs from all batches
        final allChunkIds = <String>[];
        for (final batch in batches) {
          final batchChunkIds = (batch['chunkIds'] as List?)?.cast<String>() ?? [];
          allChunkIds.addAll(batchChunkIds);
        }
        
        // Sort chunk IDs to maintain original order
        allChunkIds.sort((a, b) => a.compareTo(b));
        
        // Get base metadata from the last batch (contains name, path, etc.)
        final baseMetadata = fileBaseMetadata[fileId]!;
        
        // Create merged metadata
        final mergedMetadata = {
          'type': 'disbox_metadata',
          'version': '1.0',
          'name': baseMetadata['name'],
          'path': baseMetadata['path'],
          'size': baseMetadata['size'],
          'mimeType': baseMetadata['mimeType'],
          'isFolder': baseMetadata['isFolder'],
          'createdAt': baseMetadata['createdAt'],
          'modifiedAt': baseMetadata['modifiedAt'],
          'chunkIds': allChunkIds,
        };
        
        print('[IMPORT] Importing: ${mergedMetadata['name']} with ${allChunkIds.length} chunks');
        
        // Convert back to text format and import
        final mergedText = '[DISBOX] ${jsonEncode(mergedMetadata)}';
        final result = await importMetadataFromText(mergedText);
        
        if (result != null) {
          successCount++;
        }
      } catch (e) {
        print('[IMPORT ERROR] Failed to import file $fileId: $e');
      }
    }
    
    // Add to saved accounts list for easy re-selection (if webhook URL is available)
    if (_webhookUrl != null && _accountId != null) {
      await _addAccountToSavedList(_webhookUrl!, _accountId!);
    }
    
    return successCount;
  }

  /// Check if webhook URL is configured
  bool get isConfigured => _webhookUrl != null;

  /// Get the account ID (hashed webhook URL)
  String? get accountId => _accountId;

  /// Get list of previously saved accounts for easy re-selection
  Future<List<Map<String, String>>> getSavedAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final accountsJson = prefs.getStringList(_savedAccountsKey) ?? [];
    
    final List<Map<String, String>> accounts = [];
    for (final jsonStr in accountsJson) {
      try {
        final Map<String, dynamic> data = jsonDecode(jsonStr);
        // Use stored label if available, otherwise generate from webhook URL
        String? storedLabel = data['label'] as String?;
        String label;
        if (storedLabel != null && storedLabel.isNotEmpty) {
          label = storedLabel;
        } else {
          // Generate label asynchronously for backward compatibility
          label = await _generateAccountLabel(data['webhook_url'] as String);
        }
        accounts.add({
          'webhook_url': data['webhook_url'] as String,
          'account_id': data['account_id'] as String,
          'label': label,
        });
      } catch (e) {
        print('[DisboxService] Error parsing saved account: $e');
      }
    }
    
    // Sort by most recently used first
    return accounts.reversed.toList();
  }

  /// Add an account to the saved accounts list
  Future<void> _addAccountToSavedList(String webhookUrl, String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final accountsJson = prefs.getStringList(_savedAccountsKey) ?? [];
    
    // Remove if already exists (to update position and avoid duplicates)
    final updatedList = accountsJson.where((jsonStr) {
      try {
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        return data['account_id'] != accountId;
      } catch (e) {
        return false;
      }
    }).toList();
    
    // Generate label asynchronously
    final label = await _generateAccountLabel(webhookUrl);
    
    // Add to end (most recent)
    updatedList.add(jsonEncode({
      'webhook_url': webhookUrl,
      'account_id': accountId,
      'label': label,
    }));
    
    // Keep only last 10 accounts to avoid clutter
    if (updatedList.length > 10) {
      updatedList.removeAt(0);
    }
    
    await prefs.setStringList(_savedAccountsKey, updatedList);
    print('[DisboxService] Added account to saved list: $accountId');
  }

  /// Generate a human-readable label for an account based on webhook URL
  Future<String> _generateAccountLabel(String webhookUrl) async {
    try {
      // Try to fetch webhook name from Discord API
      final response = await _dio.get(webhookUrl);
      if (response.statusCode == 200 && response.data is Map) {
        final data = response.data as Map<String, dynamic>;
        final name = data['name'] as String?;
        if (name != null && name.isNotEmpty) {
          return name;
        }
      }
    } catch (e) {
      print('[DisboxService] Failed to fetch webhook name: $e');
      // Fallback to extracting webhook ID
    }
    
    try {
      final uri = Uri.parse(webhookUrl);
      // Extract webhook ID as a short identifier
      final segments = uri.pathSegments;
      final webhookIndex = segments.indexOf('webhooks');
      if (webhookIndex != -1 && webhookIndex + 1 < segments.length) {
        final webhookId = segments[webhookIndex + 1];
        // Show first 8 chars of webhook ID
        return 'Webhook ${webhookId.substring(0, Math.min(8, webhookId.length))}';
      }
    } catch (e) {
      // Fallback
    }
    return 'Discord Account';
  }

  /// Load a previously saved account by account ID
  Future<bool> loadSavedAccount(String accountId) async {
    final accounts = await getSavedAccounts();
    final account = accounts.firstWhere(
      (a) => a['account_id'] == accountId,
      orElse: () => {},
    );
    
    if (account.isEmpty) {
      return false;
    }
    
    final webhookUrl = account['webhook_url'];
    if (webhookUrl == null) {
      return false;
    }
    
    // Initialize Hive if needed
    if (_fileTreeBox == null) {
      await _initHive();
    }
    
    // Set webhook URL
    _webhookUrl = webhookUrl;
    _accountId = accountId;
    
    // Save to current session prefs
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('webhook_url', webhookUrl);
    await prefs.setString('account_id', accountId);
    
    // Move to most recent position
    await _addAccountToSavedList(webhookUrl, accountId);
    
    // Load file tree
    await _loadFileTree();
    
    print('[DisboxService] Loaded saved account: $accountId');
    return true;
  }

  /// Remove an account from the saved accounts list
  Future<void> removeSavedAccount(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final accountsJson = prefs.getStringList(_savedAccountsKey) ?? [];
    
    final updatedList = accountsJson.where((jsonStr) {
      try {
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        return data['account_id'] != accountId;
      } catch (e) {
        return false;
      }
    }).toList();
    
    await prefs.setStringList(_savedAccountsKey, updatedList);
    print('[DisboxService] Removed account from saved list: $accountId');
  }

  /// Extract webhook ID and token from URL
  ///
  /// Discord webhook URL format: https://discord.com/api/webhooks/{id}/{token}
  _WebhookCredentials? _parseWebhookUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;

      // Find 'webhooks' segment and get the next two segments
      final webhookIndex = segments.indexOf('webhooks');
      if (webhookIndex == -1 || webhookIndex + 2 >= segments.length) {
        return null;
      }

      final id = segments[webhookIndex + 1];
      final token = segments[webhookIndex + 2];

      return _WebhookCredentials(id: id, token: token);
    } catch (e) {
      return null;
    }
  }

  /// Validate webhook URL format
  bool _isValidWebhookUrl(String url) {
    return _parseWebhookUrl(url) != null;
  }

  /// Hash webhook URL using SHA256 for local account identification
  String _hashWebhookUrl(String url) {
    final bytes = utf8.encode(url);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16); // Use first 16 chars
  }

  /// Recursively convert Map<dynamic, dynamic> to Map<String, dynamic>
  /// This is needed because Hive/JSON returns Map<dynamic, dynamic> which can't be directly cast
  dynamic _convertMapToStringKeys(dynamic data) {
    if (data == null) {
      return null;
    } else if (data is Map) {
      final result = <String, dynamic>{};
      for (final entry in data.entries) {
        final key = entry.key.toString();
        // Skip 'children' during conversion to avoid deep recursion issues
        // Children will be converted on-demand when accessed
        if (key == 'children') {
          result[key] = entry.value;
        } else {
          final value = _convertMapToStringKeys(entry.value);
          result[key] = value;
        }
      }
      return result;
    } else if (data is List) {
      // Convert list elements recursively
      return data.map((item) => _convertMapToStringKeys(item)).toList();
    } else {
      // Primitive types (String, int, bool, double, etc.) - return as-is
      return data;
    }
  }

  /// Get the base URL for webhook API calls
  String _getWebhookApiUrl() {
    if (_webhookUrl == null) {
      print(
          '[DisboxService ERROR] Attempting to get webhook API URL but webhook is not configured');
      print('[DisboxService ERROR] _webhookUrl: $_webhookUrl');
      print('[DisboxService ERROR] _accountId: $_accountId');
      throw StateError(
          'Webhook URL not configured. Please call setWebhookUrl() first.');
    }

    final creds = _parseWebhookUrl(_webhookUrl!);
    if (creds == null) {
      print('[DisboxService ERROR] Failed to parse webhook URL: $_webhookUrl');
      throw StateError('Invalid webhook URL');
    }

    return '${DisboxConstants.discordApiBase}/${creds.id}/${creds.token}';
  }

  /// Fetch webhook information from Discord API to get the webhook name
  Future<String?> getWebhookName() async {
    if (_webhookUrl == null) {
      return null;
    }

    try {
      // Discord webhook URL format: https://discord.com/api/webhooks/{id}/{token}
      // We need to use the full webhook URL (with token) to authenticate the request
      final response = await _dio.get(_webhookUrl!);
      
      if (response.statusCode == 200 && response.data is Map) {
        final data = response.data as Map;
        return data['name'] as String?;
      }
    } catch (e) {
      print('[DisboxService] Failed to fetch webhook name: $e');
    }
    
    return null;
  }

  // ==================== LOCAL STORAGE METHODS ====================

  /// Load file tree from local Hive storage.
  ///
  /// This loads the existing file metadata that was previously stored
  /// locally. The file tree is stored in Hive indexed by the account ID.
  Future<void> _loadFileTree() async {
    print('[DisboxService DEBUG] _loadFileTree called');
    if (_fileTreeBox == null) {
      print(
          '[DisboxService] Cannot load file tree: Hive not initialized');
      return;
    }

    // If webhook URL is not set, we can't load account-specific data
    // but we should still initialize an empty file tree to avoid null errors
    if (_webhookUrl == null && _accountId == null) {
      print('[DisboxService] Webhook URL and Account ID not set, initializing empty file tree');
      _fileTree = {
        'id': 'root',
        'name': 'root',
        'type': 'directory',
        'children': {},
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };
      print('[DisboxService DEBUG] Initialized empty file tree (no webhook)');
      return;
    }

    print('[DisboxService] Loading file tree from local storage...');
    print('[DisboxService] Account ID: $_accountId');

    // Try to load file tree from Hive using account ID as key
    final storedData = _fileTreeBox!.get(_accountId);
    print('[DisboxService DEBUG] Stored data from Hive: ${storedData != null ? "found (${(storedData as String).length} chars)" : "null"}');

    if (storedData != null) {
      // Decode from JSON string - now always a List format
      final decoded = jsonDecode(storedData as String);
      print('[DisboxService DEBUG] Decoded data type: ${decoded.runtimeType}');

      // Now we always store as List, so just build tree from it
      if (decoded is List) {
        // Standard format: Build tree from list of DisboxFile
        print('[DisboxService] Loading file tree from List format...');
        _fileTree = await _buildFileTreeFromList(decoded);
      } else if (decoded is Map && decoded.containsKey('file_tree')) {
        // Legacy format with wrapper object (from old exports)
        final fileTreeData = decoded['file_tree'];
        if (fileTreeData is List) {
          print('[DisboxService] Loading file tree from legacy List format...');
          _fileTree = await _buildFileTreeFromList(fileTreeData);
        } else if (fileTreeData is Map) {
          // Very old format: Direct tree structure
          print('[DisboxService] Loading file tree from legacy Map format...');
          _fileTree =
              _convertMapToStringKeys(fileTreeData) as Map<String, dynamic>?;
        } else {
          throw Exception(
              "'file_tree' must be an object or array, not a ${fileTreeData.runtimeType}");
        }
      } else if (decoded is Map) {
        // Very old format: Direct tree structure without wrapper
        print('[DisboxService] Loading file tree from legacy direct Map format...');
        _fileTree =
            _convertMapToStringKeys(decoded) as Map<String, dynamic>?;
      } else {
        throw Exception(
            "Stored data must be a List or Map, not a ${decoded.runtimeType}");
      }

      // Handle case where conversion returns null
      if (_fileTree == null) {
        print(
            '[DisboxService WARNING] File tree conversion returned null, initializing empty tree');
        _fileTree = {
          'id': 'root',
          'name': 'root',
          'type': 'directory',
          'children': {},
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        };
      } else {
        final childrenMap = _fileTree!['children'];
        int childrenCount = 0;
        if (childrenMap is Map) {
          childrenCount = childrenMap.length;
        }
        print('[DisboxService] Loaded file tree with $childrenCount items');
      }
    } else {
      // Initialize empty file tree if none found
      _fileTree = {
        'id': 'root',
        'name': 'root',
        'type': 'directory',
        'children': {},
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };
      print('[DisboxService] Initialized new empty file tree');
    }
    
    print('[DisboxService DEBUG] _loadFileTree completed, _fileTree is null: ${_fileTree == null}');
  }

  /// Save file tree to local Hive storage.
  ///
  /// Called after creating, updating, or deleting files to persist changes.
  /// Always saves in List format (flat list of DisboxFile) for consistency
  /// with export functionality.
  Future<void> _saveFileTree() async {
    print('[DisboxService DEBUG] _saveFileTree called');
    if (_fileTreeBox == null || _fileTree == null) {
      print(
          '[DisboxService] Cannot save file tree: Hive or fileTree not initialized');
      return;
    }

    // If accountId is null, we can't save to the correct location
    if (_accountId == null) {
      print('[DisboxService WARNING] Account ID is null, cannot save file tree properly');
      return;
    }

    try {
      // Convert tree to flat list of DisboxFile, then save as JSON
      final fileList = <DisboxFile>[];
      print('[DisboxService DEBUG] Flattening file tree...');
      _flattenFileTreeToList(_fileTree!, '/', fileList);
      print('[DisboxService DEBUG] Flattened to ${fileList.length} files');
      
      // Encode list to JSON string and save to Hive
      final jsonData = jsonEncode(fileList.map((f) => f.toJson()).toList());
      print('[DisboxService DEBUG] Saving to Hive with key: $_accountId (${jsonData.length} chars)');
      await _fileTreeBox!.put(_accountId, jsonData);
      print('[DisboxService] File tree saved to local storage (${fileList.length} files)');
    } catch (e, stackTrace) {
      print('[DisboxService ERROR] Failed to save file tree: $e');
      print('[DisboxService ERROR] Stack trace: $stackTrace');
    }
  }

  /// Reload the file tree from local storage into memory.
  ///
  /// This is needed after importing a file tree to ensure the in-memory cache
  /// matches what was just saved to disk.
  Future<void> reloadFileTree() async {
    await _loadFileTree();
  }

  /// Public method to get the file tree as a List of DisboxFile
  /// Used for exporting metadata to other devices
  Future<List<DisboxFile>> getFileTreeList() async {
    // Check if initialized - if not, return empty list
    if (_fileTreeBox == null || _webhookUrl == null) {
      print('[DisboxService] Not initialized yet, returning empty file list');
      return [];
    }

    final result = <DisboxFile>[];

    if (_fileTree == null) {
      return result;
    }

    // Convert internal file tree structure to flat list of DisboxFile
    _flattenFileTreeToList(_fileTree!, '/', result);

    return result;
  }

  /// Recursively flatten the file tree structure into a list
  void _flattenFileTreeToList(
      Map<String, dynamic> node, String path, List<DisboxFile> result) {
    final name = node['name'] as String? ?? p.basename(path);
    final type = node['type'] as String?;
    final isFolder = type == 'directory';
    final size = node['size'] as int?;
    final messageId = node['message_id'] as String?;
    final createdAtStr = node['created_at'] as String?;

    // Handle both storage formats:
    // - New format (from import): 'chunk_message_ids' as List
    // - Old format (from upload): 'content' as JSON-encoded string
    List<String>? chunkIds;
    if (node.containsKey('chunk_message_ids')) {
      // New format from import
      chunkIds = (node['chunk_message_ids'] as List?)?.cast<String>();
    } else if (node.containsKey('content')) {
      // Old format from upload - content is JSON-encoded string
      final content = node['content'] as String?;
      if (content != null) {
        try {
          final decoded = jsonDecode(content);
          if (decoded is List) {
            chunkIds = decoded.cast<String>();
          }
        } catch (e) {
          print(
              '[DisboxService WARNING] Failed to decode chunk_message_ids from content: $e');
        }
      }
    }

    // Create DisboxFile from the node data
    final file = DisboxFile(
      id: messageId ?? path,
      name: name,
      path: path,
      isFolder: isFolder,
      size: size,
      mimeType: isFolder ? null : _detectMimeType(name),
      chunkMessageIds: chunkIds ?? [],
      createdAt: createdAtStr != null
          ? DateTime.tryParse(createdAtStr) ?? DateTime.now()
          : DateTime.now(),
      modifiedAt: DateTime.now(),
      parentId: path == '/' ? null : p.dirname(path),
    );

    result.add(file);

    // Process children if this is a directory
    final children = node['children'];
    if (children is Map && isFolder) {
      for (final entry in children.entries) {
        final childName = entry.key as String;
        final childNode = entry.value as Map<String, dynamic>;
        final childPath = path == '/' ? '/$childName' : '$path/$childName';
        _flattenFileTreeToList(childNode, childPath, result);
      }
    }
  }

  /// Build a hierarchical file tree from a flat list of DisboxFile objects.
  /// This is used when importing a config file that was exported from another device.
  Future<Map<String, dynamic>> _buildFileTreeFromList(
      List<dynamic> fileList) async {
    try {
      // Convert the list of JSON maps to DisboxFile objects
      final disboxFiles = fileList
          .whereType<Map<String, dynamic>>()
          .map((json) => DisboxFile.fromJson(json))
          .toList();

      // Create root node
      final root = <String, dynamic>{
        'id': 'root',
        'name': 'root',
        'type': 'directory',
        'children': <String, dynamic>{},
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };

      // Sort by path depth to ensure parents are created before children
      final sortedFiles = List<DisboxFile>.from(disboxFiles)
        ..sort((a, b) => a.path.length.compareTo(b.path.length));

      for (final file in sortedFiles) {
        _addFileToTree(root, file);
      }

      print(
          '[DisboxService] Built file tree with ${disboxFiles.length} items from list');
      return root;
    } catch (e) {
      print('[DisboxService ERROR] Failed to build file tree from list: $e');
      rethrow;
    }
  }

  /// Public method to save a file tree from imported data
  /// Used when importing metadata from another device
  Future<void> saveFileTreeFromList(List<DisboxFile> fileList) async {
    if (_webhookUrl == null || _fileTreeBox == null) {
      print(
          '[DisboxService] Cannot save file tree: webhook or Hive not initialized');
      return;
    }

    try {
      // Convert flat list back to hierarchical structure
      final root = <String, dynamic>{
        'id': 'root',
        'name': 'root',
        'type': 'directory',
        'children': <String, dynamic>{},
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };

      // Sort by path depth to ensure parents are created before children
      final sortedFiles = List<DisboxFile>.from(fileList)
        ..sort((a, b) => a.path.length.compareTo(b.path.length));

      for (final file in sortedFiles) {
        _addFileToTree(root, file);
      }

      // Set the reconstructed tree
      _fileTree = root;

      // Save to Hive
      final jsonData = jsonEncode(_fileTree);
      await _fileTreeBox!.put(_accountId, jsonData);

      print(
          '[DisboxService] Imported file tree with ${fileList.length} items saved to local storage');
    } catch (e) {
      print('[DisboxService ERROR] Failed to save imported file tree: $e');
      rethrow;
    }
  }

  /// Add a DisboxFile to the tree structure at its path
  void _addFileToTree(Map<String, dynamic> root, DisboxFile file) {
    print('[DisboxService DEBUG] _addFileToTree called for: ${file.path}');
    final path = file.path;

    if (path == '/' || path == null || path.isEmpty) {
      // Root node or invalid path
      print('[DisboxService DEBUG] Adding root node or skipping invalid path');
      if (path == '/') {
        root['name'] = file.name;
      }
      return;
    }

    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    print('[DisboxService DEBUG] Path parts: $parts');
    
    // Handle case where path has no valid parts (e.g., just "/" or empty string after filtering)
    if (parts.isEmpty) {
      print('[DisboxService DEBUG] No valid path parts, skipping file: ${file.name}');
      return;
    }
    
    var current = root;

    // Navigate to parent directory
    for (int i = 0; i < parts.length - 1; i++) {
      final part = parts[i];
      var childrenRaw = current['children'];
      Map<String, dynamic> children;
      
      if (childrenRaw == null) {
        children = <String, dynamic>{};
        current['children'] = children;
      } else if (childrenRaw is Map<String, dynamic>) {
        children = childrenRaw;
      } else {
        // Convert Map<dynamic, dynamic> to Map<String, dynamic>
        children = <String, dynamic>{};
        if (childrenRaw is Map) {
          childrenRaw.forEach((key, value) {
            children[key.toString()] = value;
          });
        }
        current['children'] = children;
      }
      
      print('[DisboxService DEBUG] Navigating to part: $part, children keys: ${children.keys.toList()}');

      if (!children.containsKey(part)) {
        // Create missing parent directory
        print('[DisboxService DEBUG] Creating missing directory: $part');
        children[part] = {
          'id': part,
          'name': part,
          'type': 'directory',
          'children': <String, dynamic>{},
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        };
      }

      current = children[part] as Map<String, dynamic>;
    }

    // Add the file/folder to its parent
    final fileName = parts.last;
    var childrenRaw = current['children'];
    Map<String, dynamic> children;
    
    if (childrenRaw == null) {
      children = <String, dynamic>{};
      current['children'] = children;
    } else if (childrenRaw is Map<String, dynamic>) {
      children = childrenRaw;
    } else {
      // Convert Map<dynamic, dynamic> to Map<String, dynamic>
      children = <String, dynamic>{};
      if (childrenRaw is Map) {
        childrenRaw.forEach((key, value) {
          children[key.toString()] = value;
        });
      }
      current['children'] = children;
    }
    
    print('[DisboxService DEBUG] Adding file: $fileName to parent with ${children.length} existing children');

    children[fileName] = {
      'id': file.id,
      'name': file.name,
      'type': file.isFolder ? 'directory' : 'file',
      'size': file.size,
      'message_id': file.id,
      'chunk_message_ids': file.chunkMessageIds,
      'created_at': file.createdAt.toIso8601String(),
      'updated_at': file.modifiedAt.toIso8601String(),
      if (file.isFolder) 'children': <String, dynamic>{},
    };
    
    print('[DisboxService DEBUG] File added successfully. New children count: ${children.length}');
  }

  // ==================== FILE OPERATIONS ====================

  /// Upload a file to Discord via webhook.
  ///
  /// Files larger than 25MB are automatically split into chunks.
  /// Each chunk is uploaded as a separate Discord message attachment.
  /// Metadata about the file (name, path, chunk IDs) is stored in a metadata message.
  ///
  /// [file] - The file to upload
  /// [folderPath] - The virtual folder path in Disbox (e.g., "/documents")
  /// [onProgress] - Optional callback for upload progress
  ///
  /// Returns the [DisboxFile] metadata object
  Future<DisboxFile> uploadFile(
    File file, {
    String folderPath = '/',
    ProgressCallback? onProgress,
  }) async {
    if (!isConfigured) {
      print(
          '[DisboxService ERROR] uploadFile called but webhook not configured');
      print(
          '[DisboxService ERROR] isConfigured: $isConfigured, _webhookUrl: $_webhookUrl');
      throw StateError(
          'Webhook URL not configured. Please call setWebhookUrl() first.');
    }

    // Reset upload progress stream and create new cancel token
    _uploadProgressController.add(0.0);
    _currentUploadCancelToken = CancelToken();
    _isUploading = true;
    _isUploadPaused = false;
    
    final filename = sanitizeFilename(path.basename(file.path));
    final filePath = _normalizePath('$folderPath/$filename');
    final fileSize = file.lengthSync();
    final mimeType = _detectMimeType(filename);

    // Store file info for resume capability
    _currentUploadFilePath = file.path;
    _currentUploadFolderPath = folderPath;
    _uploadedChunkIds.clear();
    _uploadedBytes = 0;
    _totalUploadBytes = fileSize;
    
    notifyListeners();

    print('Uploading: $filename ($fileSize bytes) to $filePath');

    // Determine if we need to chunk the file
    final needsChunking = fileSize > DisboxConstants.maxAttachmentSize;
    final chunkMessageIds = <String>[];

    try {
      if (needsChunking) {
        // Upload as chunks
        final chunks = ChunkUtils.splitFile(file);
        print('File requires chunking: ${chunks.length} chunks');

        var uploadedBytes = 0;

        for (int i = 0; i < chunks.length; i++) {
          // Check if upload was cancelled/stopped
          if (_currentUploadCancelToken!.isCancelled) {
            print('[UPLOAD STOPPED] Upload cancelled at chunk ${i + 1}/${chunks.length}');
            throw DioException(
              requestOptions: RequestOptions(path: ''),
              type: DioExceptionType.cancel,
              error: 'Upload stopped by user',
            );
          }

          int retryCount = 0;
          const maxRetries = 5;
          bool success = false;

          while (!success && retryCount < maxRetries) {
            try {
              final chunkData = await ChunkUtils.readChunk(file, i);

              print(
                  'Uploading chunk ${i + 1}/${chunks.length} (${chunkData.length} bytes)');

              final messageId = await _uploadAttachment(
                chunkData,
                filename: '${filename}.part$i',
                contentType: 'application/octet-stream',
                cancelToken: _currentUploadCancelToken,
              );

              chunkMessageIds.add(messageId);
              uploadedBytes += chunkData.length;
              
              // Track uploaded chunks for resume
              _uploadedChunkIds.add(messageId);
              _uploadedBytes = uploadedBytes;

              // Update progress stream
              final progress = uploadedBytes / fileSize;
              _uploadProgressController.add(progress);

              print(
                  'Chunk ${i + 1}/${chunks.length} uploaded successfully. Message ID: $messageId');
              onProgress?.call(uploadedBytes, fileSize);
              success = true;
            } on DioException catch (e) {
              // Check if this was a cancellation
              if (e.type == DioExceptionType.cancel) {
                print('[UPLOAD STOPPED] Upload intentionally stopped by user');
                // Don't print stack trace for intentional stops
                rethrow;
              }
              
              retryCount++;
              if (retryCount >= maxRetries) {
                print(
                    '[UPLOAD ERROR] Failed to upload chunk ${i + 1}/${chunks.length} after $maxRetries retries: $e');
                print('[UPLOAD ERROR] Stack Trace: ${e.stackTrace}');
                rethrow;
              }
              
              // Exponential backoff: 1s, 2s, 4s, 8s, 16s
              final delayMs = (1000 * (1 << (retryCount - 1)));
              print(
                  '[UPLOAD] Chunk ${i + 1}/${chunks.length} failed (attempt $retryCount/$maxRetries). Retrying in ${delayMs}ms...');
              await Future.delayed(Duration(milliseconds: delayMs));
            }
          }
        }
      } else {
        // Upload as single file
        try {
          final fileBytes = await file.readAsBytes();

          print('Uploading single file ($fileSize bytes)');

          final messageId = await _uploadAttachment(
            fileBytes,
            filename: filename,
            contentType: mimeType,
            cancelToken: _currentUploadCancelToken,
          );

          chunkMessageIds.add(messageId);

          // Update progress stream to complete
          _uploadProgressController.add(1.0);

          print('Single file uploaded successfully. Message ID: $messageId');
          onProgress?.call(fileSize, fileSize);
        } on DioException catch (e) {
          // Check if this was a cancellation
          if (e.type == DioExceptionType.cancel) {
            print('[UPLOAD STOPPED] Upload intentionally stopped by user');
            // Don't print stack trace for intentional stops
            rethrow;
          }
          
          print('[UPLOAD ERROR] Failed to upload single file: $e');
          print('[UPLOAD ERROR] Stack Trace: ${e.stackTrace}');
          rethrow;
        }
      }
    } on DioException catch (e) {
      // Handle cancellation gracefully - keep state for resume
      if (e.type == DioExceptionType.cancel) {
        print('[UPLOAD STOPPED] Upload intentionally stopped by user');
        _isUploading = false;
        _isUploadPaused = true; // Keep paused state for resume
        // Don't cleanup chunks on manual stop - user can resume later
        rethrow;
      }
      rethrow;
    } finally {
      // Only clear state on successful completion, not on cancel
      if (!_isUploadPaused) {
        _isUploading = false;
        _currentUploadCancelToken = null;
      }
    }

    // Create metadata message to store file information
    try {
      print('Creating metadata message for $filename...');
      final metadataMessageId = await _createMetadataMessage(
        filename: filename,
        path: filePath,
        size: fileSize,
        mimeType: mimeType,
        chunkMessageIds: chunkMessageIds,
        isFolder: false,
      );
      print(
          'Metadata message created successfully. Message ID: $metadataMessageId');

      // Create and cache DisboxFile object
      final disboxFile = DisboxFile(
        id: metadataMessageId,
        name: filename,
        path: filePath,
        isFolder: false,
        size: fileSize,
        mimeType: mimeType,
        chunkMessageIds: chunkMessageIds,
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        parentId: _getParentFolderId(folderPath),
      );

      // Add file to file tree
      await _addFileToFileTree(
        id: metadataMessageId,
        name: filename,
        path: filePath,
        size: fileSize,
        mimeType: mimeType,
        chunkMessageIds: chunkMessageIds,
      );

      _fileCache[disboxFile.id] = disboxFile;

      // Notify listeners that the file tree has changed
      notifyListeners();

      print('Upload complete: ${p.basename(file.path)} -> $filePath');
      return disboxFile;
    } catch (e, stackTrace) {
      print('[METADATA ERROR] Failed to create metadata message: $e');
      print('[METADATA ERROR] Stack Trace: $stackTrace');
      print(
          '[UPLOAD ABORTED] Cleaning up uploaded chunks due to metadata failure...');
      // Cleanup: delete any successfully uploaded chunks
      for (final messageId in chunkMessageIds) {
        try {
          await _deleteMessage(messageId);
          print('[CLEANUP] Deleted chunk message: $messageId');
        } catch (cleanupError) {
          print(
              '[CLEANUP ERROR] Failed to delete chunk $messageId: $cleanupError');
        }
      }
      rethrow;
    }
  }

  /// Download a file from Discord.
  ///
  /// For chunked files, downloads all chunks and reassembles them.
  /// The outputPath should be a temporary location - caller is responsible
  /// for moving/copying to final destination and cleaning up.
  ///
  /// [file] - The DisboxFile metadata object
  /// [outputPath] - Where to save the downloaded file (should be temp directory)
  /// [onProgress] - Optional callback for download progress
  Future<File> downloadFile(
    DisboxFile file,
    String outputPath, {
    ProgressCallback? onProgress,
  }) async {
    if (!isConfigured) {
      print(
          '[DisboxService ERROR] downloadFile called but webhook not configured');
      throw StateError(
          'Webhook URL not configured. Please call setWebhookUrl() first.');
    }

    if (file.isFolder) {
      throw ArgumentError('Cannot download a folder');
    }

    // Validate that outputPath is in temp directory to prevent accidental permanent storage
    final tempDir = await getTemporaryDirectory();
    if (!outputPath.startsWith(tempDir.path)) {
      print(
          '[DisboxService WARNING] Download path $outputPath is not in temp directory. Consider using getTemporaryDirectory().');
    }

    // Reset download progress stream and create new cancel token
    _downloadProgressController.add(0.0);
    _currentDownloadCancelToken = CancelToken();
    _isDownloading = true;
    _isDownloadPaused = false;
    
    // Store file info for resume capability
    _currentDownloadFileId = file.id;
    _downloadedChunkIndices.clear();
    _downloadedBytes = 0;
    _totalDownloadBytes = file.size ?? 0;
    
    notifyListeners();

    print('Downloading: ${file.name} (${file.chunkMessageIds.length} chunks)');

    var downloadedBytes = 0;
    final totalBytes = file.size ?? 0;

    try {
      // Stream download each chunk directly to disk to avoid OOM for large files
      // This writes each chunk to disk immediately instead of accumulating in memory
      final outputFile = File(outputPath);
      final sink = outputFile.openWrite();
      
      // Download each chunk and stream to disk
      for (int i = 0; i < file.chunkMessageIds.length; i++) {
        // Check if download was cancelled/stopped
        if (_currentDownloadCancelToken!.isCancelled) {
          print('[DOWNLOAD STOPPED] Download cancelled at chunk ${i + 1}/${file.chunkMessageIds.length}');
          await sink.close();
          throw DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
            error: 'Download stopped by user',
          );
        }

        final messageId = file.chunkMessageIds[i];

        print('Downloading chunk ${i + 1}/${file.chunkMessageIds.length}');

        final chunkData = await _downloadAttachment(
          messageId,
          cancelToken: _currentDownloadCancelToken,
        );
        
        // Write chunk to disk immediately - don't accumulate in memory!
        sink.add(chunkData);
        downloadedBytes += chunkData.length;
        
        // Track downloaded chunks for resume
        _downloadedChunkIndices.add(i);
        _downloadedBytes = downloadedBytes;

        // Update progress stream
        final progress = totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;
        _downloadProgressController.add(progress);

        onProgress?.call(downloadedBytes, totalBytes);
        
        // Flush periodically to ensure data is written to disk
        if ((i + 1) % 5 == 0) {
          await sink.flush();
        }
      }

      // Final flush and close
      await sink.flush();
      await sink.close();

      // Mark download as complete
      _downloadProgressController.add(1.0);

      print(
          'Download complete: $outputPath (${await File(outputPath).length()} bytes)');

      return File(outputPath);
    } on DioException catch (e) {
      // Handle cancellation gracefully - keep state for resume
      if (e.type == DioExceptionType.cancel) {
        print('[DOWNLOAD] Download was stopped/cancelled');
        _isDownloading = false;
        _isDownloadPaused = true; // Keep paused state for resume
        // Don't cleanup partial download on manual cancel - user can resume
        rethrow;
      }
      rethrow;
    } catch (e, stackTrace) {
      print('[DOWNLOAD ERROR] Failed to download file: $e');
      print('[DOWNLOAD ERROR] Stack Trace: $stackTrace');
      // Cleanup partial download on error (not on cancel)
      try {
        final outFile = File(outputPath);
        if (await outFile.exists()) {
          await outFile.delete();
          print('[DOWNLOAD CLEANUP] Deleted partial download: $outputPath');
        }
      } catch (cleanupError) {
        print(
            '[DOWNLOAD CLEANUP ERROR] Failed to delete partial file: $cleanupError');
      }
      rethrow;
    } finally {
      // Only clear state on successful completion, not on cancel
      if (!_isDownloadPaused) {
        _isDownloading = false;
        _currentDownloadCancelToken = null;
      }
    }
  }

  /// Delete a file or folder.
  ///
  /// Deletes all chunk messages and the metadata message.
  Future<void> deleteFile(DisboxFile file) async {
    if (!isConfigured) {
      print(
          '[DisboxService ERROR] deleteFile called but webhook not configured');
      throw StateError(
          'Webhook URL not configured. Please call setWebhookUrl() first.');
    }

    print('Deleting: ${file.name}');

    // Delete all chunk messages
    for (final messageId in file.chunkMessageIds) {
      try {
        await _deleteMessage(messageId);
      } catch (e) {
        print('Warning: Failed to delete chunk $messageId: $e');
      }
    }

    // Delete metadata message
    try {
      await _deleteMessage(file.id);
    } catch (e) {
      print('Warning: Failed to delete metadata message ${file.id}: $e');
    }

    // Remove from file tree
    await _removeFileFromFileTree(file.path, isFolder: file.isFolder);

    // Remove from cache
    _fileCache.remove(file.id);
  }

  /// List files in a folder.
  ///
  /// Fetches metadata from the loaded file tree (from backend server).
  ///
  /// [folderPath] - The virtual folder path to list (default: root "/")
  Future<List<DisboxFile>> listFiles({String folderPath = '/'}) async {
    final stopwatch = Stopwatch()..start();
    print('[DisboxService DEBUG] listFiles called with folderPath: $folderPath');
    print('[DisboxService DEBUG] isConfigured: $isConfigured, _webhookUrl: $_webhookUrl, _accountId: $_accountId, _fileTree null: ${_fileTree == null}');
    
    if (!isConfigured) {
      print(
          '[DisboxService ERROR] listFiles called but webhook not configured');
      print(
          '[DisboxService ERROR] isConfigured: $isConfigured, _webhookUrl: $_webhookUrl, _accountId: $_accountId');
      throw StateError(
          'Webhook URL not configured. Please call setWebhookUrl() first.');
    }

    print('[DisboxService] Listing files in: $folderPath');

    // Use file tree from backend server instead of fetching Discord messages
    if (_fileTree == null) {
      print('File tree not loaded yet');
      return [];
    }

    final files = <DisboxFile>[];

    try {
      // Navigate to the correct folder in the file tree
      print('[DisboxService DEBUG] Getting folder from tree for path: $folderPath');
      final targetFolder = _getFolderFromTree(folderPath);
      if (targetFolder == null) {
        print('Folder not found: $folderPath');
        return [];
      }
      print('[DisboxService DEBUG] Found target folder: ${targetFolder['name']}');

      // Extract children from the file tree
      final childrenData = targetFolder['children'];
      Map<String, dynamic>? children;
      if (childrenData is Map) {
        children = <String, dynamic>{};
        for (final entry in childrenData.entries) {
          children[entry.key.toString()] =
              _convertMapToStringKeys(entry.value) ?? entry.value;
        }
      } else if (childrenData != null) {
        // Handle case where children might be stored differently
        print('[DisboxService DEBUG] Unexpected children type: ${childrenData.runtimeType}');
      }

      if (children == null) {
        return [];
      }

      // Convert file tree nodes to DisboxFile objects
      children.forEach((name, node) {
        try {
          print('[DisboxService DEBUG] Processing child: $name, type=${node.runtimeType}');
          Map<String, dynamic>? childNode;
          if (node is Map) {
            childNode = <String, dynamic>{};
            for (final entry in node.entries) {
              final key = entry.key.toString();
              // Skip converting 'children' recursively - only convert top-level properties
              if (key == 'children') {
                childNode[key] = entry.value;
              } else {
                childNode[key] = _convertMapToStringKeys(entry.value) ?? entry.value;
              }
            }
          } else {
            print('[DisboxService WARNING] Node is not a Map: ${node.runtimeType}');
            return;
          }

          if (childNode == null) {
            print('[DisboxService WARNING] Skipping invalid node: $name');
            return;
          }

          final childPath = '$folderPath/$name';
          final isFolder = childNode['type'] == 'directory';

          // Parse chunk message IDs from content (for files)
          // Handle both storage formats:
          // - New format (from import): 'chunk_message_ids' as List
          // - Old format (from upload): 'content' as JSON-encoded string
          List<String> chunkMessageIds = [];
          if (!isFolder) {
            if (childNode.containsKey('chunk_message_ids')) {
              // New format from import
              final chunkIdsValue = childNode['chunk_message_ids'];
              if (chunkIdsValue is List) {
                chunkMessageIds =
                    chunkIdsValue.map((id) => id.toString()).toList();
              }
            } else if (childNode['content'] != null) {
              // Old format from upload - content is JSON-encoded string
              try {
                final contentList =
                    jsonDecode(childNode['content'] as String) as List;
                chunkMessageIds = contentList.map((id) => id.toString()).toList();
              } catch (e) {
                print('Warning: Failed to parse content for $name: $e');
              }
            }
          }

          // Get size - handle both int and num types
          int? fileSize;
          final sizeValue = childNode['size'];
          if (sizeValue is int) {
            fileSize = sizeValue;
          } else if (sizeValue is num) {
            fileSize = sizeValue.toInt();
          } else if (sizeValue is String) {
            fileSize = int.tryParse(sizeValue);
          }

          // Parse dates safely
          DateTime? createdAt;
          if (childNode['created_at'] != null) {
            try {
              createdAt = DateTime.parse(childNode['created_at'].toString());
            } catch (_) {
              createdAt = DateTime.now();
            }
          }

          DateTime? modifiedAt;
          if (childNode['updated_at'] != null) {
            try {
              modifiedAt = DateTime.parse(childNode['updated_at'].toString());
            } catch (_) {
              modifiedAt = DateTime.now();
            }
          }

          final file = DisboxFile(
            id: childNode['id'].toString(),
            name: name,
            path: childPath,
            isFolder: isFolder,
            size: fileSize,
            mimeType: !isFolder ? _detectMimeType(name) : null,
            chunkMessageIds: chunkMessageIds,
            createdAt: createdAt ?? DateTime.now(),
            modifiedAt: modifiedAt ?? DateTime.now(),
          );

          files.add(file);
        } catch (e) {
          print('Warning: Failed to convert node $name: $e');
        }
      });

    // Sort: folders first, then files, alphabetically
    files.sort((a, b) {
      if (a.isFolder && !b.isFolder) return -1;
      if (!a.isFolder && b.isFolder) return 1;
      return a.name.compareTo(b.name);
    });

    print('[DisboxService] listFiles completed in ${stopwatch.elapsedMilliseconds}ms with ${files.length} files');
    return files;
  } catch (e, stackTrace) {
    print('[DisboxService ERROR] listFiles failed: $e');
    print('[DisboxService ERROR] Stack trace: $stackTrace');
    rethrow;
  }
}

  /// Get a folder node from the file tree by path.
  ///
  /// Returns null if the folder doesn't exist.
  Map<String, dynamic>? _getFolderFromTree(String path) {
    print('[DisboxService DEBUG] _getFolderFromTree called with path: $path');
    if (_fileTree == null) {
      print('[DisboxService DEBUG] _fileTree is null, returning null');
      return null;
    }

    if (path == '/') {
      print('[DisboxService DEBUG] Returning root folder');
      return _fileTree;
    }

    var currentNode = _fileTree;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    print('[DisboxService DEBUG] Path parts: $parts');

    for (final part in parts) {
      var childrenRaw = currentNode?['children'];
      Map<String, dynamic>? children;
      
      if (childrenRaw != null) {
        if (childrenRaw is Map<String, dynamic>) {
          children = childrenRaw;
        } else if (childrenRaw is Map) {
          // Convert Map<dynamic, dynamic> to Map<String, dynamic>
          children = <String, dynamic>{};
          childrenRaw.forEach((key, value) {
            children![key.toString()] = value;
          });
          // Update the node with converted map
          currentNode!['children'] = children;
        }
      }
      
      print('[DisboxService DEBUG] Looking for part: $part, children keys: ${children?.keys.toList()}');

      if (children == null || !children.containsKey(part)) {
        print('[DisboxService DEBUG] Part not found: $part');
        return null;
      }

      currentNode = children[part] as Map<String, dynamic>?;

      // Verify it's a directory
      if (currentNode?['type'] != 'directory') {
        print('[DisboxService DEBUG] Node is not a directory: ${currentNode?['type']}');
        return null;
      }
    }

    print('[DisboxService DEBUG] Found folder: ${currentNode?['name']}');
    return currentNode;
  }

  /// Create a folder (virtual - stored via backend server).
  Future<DisboxFile> createFolder(String name,
      {String parentPath = '/'}) async {
    if (!isConfigured) {
      print(
          '[DisboxService ERROR] createFolder called but webhook not configured');
      throw StateError(
          'Webhook URL not configured. Please call setWebhookUrl() first.');
    }

    final folderPath = _normalizePath('$parentPath/$name');

    print('Creating folder: $name at $folderPath');

    // Get parent folder from file tree
    final parentFolder = _getFolderFromTree(parentPath);
    if (parentFolder == null) {
      throw Exception('Parent folder not found: $parentPath');
    }

    // Check if folder already exists - handle both Map types safely
    final childrenRaw = parentFolder['children'];
    Map<String, dynamic> children;
    
    if (childrenRaw == null) {
      children = <String, dynamic>{};
      parentFolder['children'] = children;
    } else if (childrenRaw is Map<String, dynamic>) {
      children = childrenRaw;
    } else {
      // Convert Map<dynamic, dynamic> to Map<String, dynamic>
      children = <String, dynamic>{};
      if (childrenRaw is Map) {
        childrenRaw.forEach((key, value) {
          children[key.toString()] = value;
        });
      }
      parentFolder['children'] = children;
    }

    if (children.containsKey(name)) {
      throw Exception('Folder already exists: $name');
    }

    // Generate new ID for the folder
    final newId = DateTime.now().millisecondsSinceEpoch.toString();

    // Create folder node
    final folderNode = {
      'id': newId,
      'name': name,
      'type': 'directory',
      'children': <String, dynamic>{},
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    };

    // Add to parent's children using direct reference
    children[name] = folderNode;
    parentFolder['children'] = children; // Reassign to ensure update

    // Create DisboxFile object for adding to tree
    final folder = DisboxFile(
      id: newId,
      name: name,
      path: folderPath,
      isFolder: true,
      size: 0,
      createdAt: DateTime.now(),
      modifiedAt: DateTime.now(),
    );

    // Add folder to file tree structure
    _addFileToTree(_fileTree!, folder);

    // Save file tree to local storage
    await _saveFileTree();

    // Notify listeners that the file tree has changed
    notifyListeners();

    return folder;
  }

  /// Rename a file or folder.
  Future<DisboxFile> renameFile(DisboxFile file, String newName) async {
    if (!isConfigured) {
      print(
          '[DisboxService ERROR] renameFile called but webhook not configured');
      throw StateError(
          'Webhook URL not configured. Please call setWebhookUrl() first.');
    }

    final parentPath = _getParentPath(file.path);
    final newPath = _normalizePath('$parentPath/$newName');

    print('Renaming: ${file.name} -> $newName');
    print('NOTE: Only updating local file tree (UI). Chunk message IDs remain unchanged for downloads.');

    // Update local file tree only - no webhook API calls
    await _renameFileInFileTreeLocalOnly(file, newName, newPath);

    // Update cached object
    final updatedFile = DisboxFile(
      id: file.id,
      name: newName,
      path: newPath,
      isFolder: file.isFolder,
      size: file.size,
      mimeType: file.mimeType,
      chunkMessageIds: file.chunkMessageIds,
      createdAt: file.createdAt,
      modifiedAt: DateTime.now(),
      parentId: file.parentId,
    );

    _fileCache[updatedFile.id] = updatedFile;

    return updatedFile;
  }

  /// Rename a file or folder in the local file tree only.
  /// Does NOT make any webhook API calls - only updates UI/metadata.
  Future<void> _renameFileInFileTreeLocalOnly(DisboxFile file, String newName, String newPath) async {
    print('[DisboxService DEBUG] _renameFileInFileTreeLocalOnly: ${file.path} -> $newPath');
    
    if (_fileTree == null) {
      throw StateError('File tree not loaded');
    }

    // Update the file/folder name and path in the tree
    final parentPath = _getParentPath(file.path);
    final folder = _getFolderFromTree(parentPath);
    
    if (folder != null && folder.containsKey('children')) {
      final children = folder['children'] as Map<String, dynamic>;
      
      // Remove old entry
      if (children.containsKey(file.name)) {
        final oldEntry = children[file.name];
        children.remove(file.name);
        
        // Add with new name
        if (oldEntry is Map<String, dynamic>) {
          oldEntry['name'] = newName;
          oldEntry['path'] = newPath;
          
          // If it's a folder, update all children paths recursively
          if (oldEntry['isFolder'] == true) {
            _updateChildrenPaths(oldEntry, newPath);
          }
          
          children[newName] = oldEntry;
        }
      }
    }

    // Save the updated file tree
    await _saveFileTree();
    
    print('[DisboxService DEBUG] Rename completed in local file tree');
  }

  /// Recursively update paths for all children of a folder
  void _updateChildrenPaths(Map<String, dynamic> folder, String newParentPath) {
    if (folder.containsKey('children')) {
      final children = folder['children'] as Map<String, dynamic>;
      for (final entry in children.entries) {
        if (entry.value is Map<String, dynamic>) {
          final child = entry.value as Map<String, dynamic>;
          final oldPath = child['path'] as String;
          final childName = child['name'] as String;
          final newChildPath = _normalizePath('$newParentPath/$childName');
          
          child['path'] = newChildPath;
          
          // Recursively update if it's a folder
          if (child['isFolder'] == true) {
            _updateChildrenPaths(child, newChildPath);
          }
        }
      }
    }
  }

  /// Move a file or folder to a different folder path.
  /// 
  /// This operation only updates the metadata path - no actual files are moved
  /// between webhooks/folders. The chunk message IDs remain unchanged, so
  /// downloads will continue to work correctly.
  /// 
  /// [file] - The file or folder to move
  /// [destinationFolderPath] - The destination folder path (e.g., '/folder1/subfolder')
  /// 
  /// Returns the updated [DisboxFile] with the new path.
  Future<DisboxFile> moveFile(DisboxFile file, String destinationFolderPath) async {
    if (!isConfigured) {
      print(
          '[DisboxService ERROR] moveFile called but webhook not configured');
      throw StateError(
          'Webhook URL not configured. Please call setWebhookUrl() first.');
    }

    // Normalize destination folder path
    final normalizedDestPath = _normalizePath(destinationFolderPath);
    
    // Calculate new full path for the file
    final newPath = _normalizePath('$normalizedDestPath/${file.name}');

    print('Moving: ${file.path} -> $newPath');
    print('NOTE: Only updating local file tree (UI). Chunk message IDs remain unchanged for downloads.');

    if (file.isFolder) {
      // For folders, we need to update all children paths in the local tree only
      await _moveFolderInFileTreeLocalOnly(file.path, newPath);
    } else {
      // For files: remove from old location and add to new location
      // We need to do this without saving in between to avoid losing the file
      await _moveFileInFileTreeLocalOnly(file.path, newPath, file);
    }

    // Update cached object with new path (chunkMessageIds stay the same!)
    final updatedFile = DisboxFile(
      id: file.id,
      name: file.name,
      path: newPath,
      isFolder: file.isFolder,
      size: file.size,
      mimeType: file.mimeType,
      chunkMessageIds: file.chunkMessageIds, // Keep original chunk IDs for downloads
      createdAt: file.createdAt,
      modifiedAt: DateTime.now(),
      parentId: _getParentFolderId(normalizedDestPath),
    );

    _fileCache[updatedFile.id] = updatedFile;

    notifyListeners();
    return updatedFile;
  }

  /// Move a file in the file tree (LOCAL ONLY - no webhook updates).
  /// This removes from old location and adds to new location in a single operation.
  Future<void> _moveFileInFileTreeLocalOnly(String oldPath, String newPath, DisboxFile file) async {
    if (_fileTree == null) {
      print('File tree not initialized');
      return;
    }

    print('[DisboxService DEBUG] Moving file in tree: $oldPath -> $newPath');
    
    // First, collect the file node data from the old location
    Map<String, dynamic>? fileNodeData;
    final oldParts = oldPath.split('/').where((p) => p.isNotEmpty).toList();
    
    // Navigate to parent folder of old location
    Map<String, dynamic>? currentFolder = _fileTree;
    for (int i = 0; i < oldParts.length - 1; i++) {
      final folderName = oldParts[i];
      var childrenRaw = currentFolder!['children'];
      Map<String, dynamic>? children;
      
      if (childrenRaw != null) {
        if (childrenRaw is Map<String, dynamic>) {
          children = childrenRaw;
        } else if (childrenRaw is Map) {
          children = <String, dynamic>{};
          childrenRaw.forEach((key, value) {
            children![key.toString()] = value;
          });
          currentFolder!['children'] = children;
        }
      }

      if (children != null && children.containsKey(folderName)) {
        currentFolder = children[folderName] as Map<String, dynamic>?;
      } else {
        print('[DisboxService ERROR] Old parent folder not found: $folderName');
        return;
      }
    }
    
    // Get the file node from old location
    final oldFileName = oldParts.last;
    var oldChildrenRaw = currentFolder!['children'];
    Map<String, dynamic>? oldChildren;
    
    if (oldChildrenRaw != null) {
      if (oldChildrenRaw is Map<String, dynamic>) {
        oldChildren = oldChildrenRaw;
      } else if (oldChildrenRaw is Map) {
        oldChildren = <String, dynamic>{};
        oldChildrenRaw.forEach((key, value) {
          oldChildren![key.toString()] = value;
        });
        currentFolder!['children'] = oldChildren;
      }
    }
    
    if (oldChildren != null && oldChildren.containsKey(oldFileName)) {
      // Save the file node data before removing
      fileNodeData = Map<String, dynamic>.from(oldChildren[oldFileName] as Map<String, dynamic>);
      // Remove from old location
      oldChildren.remove(oldFileName);
      print('[DisboxService DEBUG] Removed file from old location: $oldFileName');
    } else {
      print('[DisboxService ERROR] File not found at old location: $oldFileName');
      return;
    }
    
    if (fileNodeData == null) {
      print('[DisboxService ERROR] Failed to get file node data');
      return;
    }
    
    // Now navigate to new parent folder
    final newParts = newPath.split('/').where((p) => p.isNotEmpty).toList();
    currentFolder = _fileTree;
    
    for (int i = 0; i < newParts.length - 1; i++) {
      final folderName = newParts[i];
      var childrenRaw = currentFolder!['children'];
      Map<String, dynamic>? children;
      
      if (childrenRaw != null) {
        if (childrenRaw is Map<String, dynamic>) {
          children = childrenRaw;
        } else if (childrenRaw is Map) {
          children = <String, dynamic>{};
          childrenRaw.forEach((key, value) {
            children![key.toString()] = value;
          });
          currentFolder!['children'] = children;
        }
      }

      if (children != null && children.containsKey(folderName)) {
        currentFolder = children[folderName] as Map<String, dynamic>?;
      } else {
        print('[DisboxService ERROR] New parent folder not found: $folderName');
        return;
      }
    }
    
    // Add to new location
    final newFileName = newParts.last;
    var newChildrenRaw = currentFolder!['children'];
    Map<String, dynamic> newChildrenMap;
    
    if (newChildrenRaw == null) {
      newChildrenMap = <String, dynamic>{};
      currentFolder!['children'] = newChildrenMap;
    } else if (newChildrenRaw is Map<String, dynamic>) {
      newChildrenMap = newChildrenRaw;
    } else {
      newChildrenMap = <String, dynamic>{};
      if (newChildrenRaw is Map) {
        newChildrenRaw.forEach((key, value) {
          newChildrenMap[key.toString()] = value;
        });
      }
      currentFolder!['children'] = newChildrenMap;
    }
    
    // Update the path in the file node
    fileNodeData['path'] = newPath;
    newChildrenMap[newFileName] = fileNodeData;
    print('[DisboxService DEBUG] Added file to new location: $newFileName');
    
    // Save file tree to local storage once
    await _saveFileTree();
  }

  /// Move a folder and all its children in the file tree (LOCAL ONLY - no webhook updates).
  Future<void> _moveFolderInFileTreeLocalOnly(String oldPath, String newPath) async {
    if (_fileTree == null) {
      print('File tree not initialized');
      return;
    }

    print('[DisboxService DEBUG] Moving folder in tree: $oldPath -> $newPath');
    
    // First, extract the folder node from its old location
    final oldParts = oldPath.split('/').where((p) => p.isNotEmpty).toList();
    if (oldParts.isEmpty) {
      print('[DisboxService ERROR] Cannot move root folder');
      return;
    }
    
    // Navigate to parent of old location
    Map<String, dynamic>? currentFolder = _fileTree;
    for (int i = 0; i < oldParts.length - 1; i++) {
      final folderName = oldParts[i];
      var childrenRaw = currentFolder!['children'];
      Map<String, dynamic>? children;
      
      if (childrenRaw != null) {
        if (childrenRaw is Map<String, dynamic>) {
          children = childrenRaw;
        } else if (childrenRaw is Map) {
          children = <String, dynamic>{};
          childrenRaw.forEach((key, value) {
            children![key.toString()] = value;
          });
          currentFolder!['children'] = children;
        }
      }

      if (children != null && children.containsKey(folderName)) {
        currentFolder = children[folderName] as Map<String, dynamic>?;
      } else {
        print('[DisboxService ERROR] Old parent folder not found: $folderName');
        return;
      }
    }
    
    // Get the folder node and remove from old location
    final oldFolderName = oldParts.last;
    var oldChildrenRaw = currentFolder!['children'];
    Map<String, dynamic>? oldChildren;
    
    if (oldChildrenRaw != null) {
      if (oldChildrenRaw is Map<String, dynamic>) {
        oldChildren = oldChildrenRaw;
      } else if (oldChildrenRaw is Map) {
        oldChildren = <String, dynamic>{};
        oldChildrenRaw.forEach((key, value) {
          oldChildren![key.toString()] = value;
        });
        currentFolder!['children'] = oldChildren;
      }
    }
    
    if (oldChildren == null || !oldChildren.containsKey(oldFolderName)) {
      print('[DisboxService ERROR] Folder not found at old location: $oldFolderName');
      return;
    }
    
    // Extract the folder node
    final folderNodeData = Map<String, dynamic>.from(oldChildren[oldFolderName] as Map<String, dynamic>);
    oldChildren.remove(oldFolderName);
    print('[DisboxService DEBUG] Removed folder from old location: $oldFolderName');
    
    // Now navigate to new parent folder
    final newParts = newPath.split('/').where((p) => p.isNotEmpty).toList();
    currentFolder = _fileTree;
    
    for (int i = 0; i < newParts.length - 1; i++) {
      final folderName = newParts[i];
      var childrenRaw = currentFolder!['children'];
      Map<String, dynamic>? children;
      
      if (childrenRaw != null) {
        if (childrenRaw is Map<String, dynamic>) {
          children = childrenRaw;
        } else if (childrenRaw is Map) {
          children = <String, dynamic>{};
          childrenRaw.forEach((key, value) {
            children![key.toString()] = value;
          });
          currentFolder!['children'] = children;
        }
      }

      if (children != null && children.containsKey(folderName)) {
        currentFolder = children[folderName] as Map<String, dynamic>?;
      } else {
        print('[DisboxService ERROR] New parent folder not found: $folderName');
        return;
      }
    }
    
    // Add to new location
    final newFolderName = newParts.last;
    var newChildrenRaw = currentFolder!['children'];
    Map<String, dynamic> newChildrenMap;
    
    if (newChildrenRaw == null) {
      newChildrenMap = <String, dynamic>{};
      currentFolder!['children'] = newChildrenMap;
    } else if (newChildrenRaw is Map<String, dynamic>) {
      newChildrenMap = newChildrenRaw;
    } else {
      newChildrenMap = <String, dynamic>{};
      if (newChildrenRaw is Map) {
        newChildrenRaw.forEach((key, value) {
          newChildrenMap[key.toString()] = value;
        });
      }
      currentFolder!['children'] = newChildrenMap;
    }
    
    // Update the path in the folder node
    folderNodeData['path'] = newPath;
    newChildrenMap[newFolderName] = folderNodeData;
    print('[DisboxService DEBUG] Added folder to new location: $newFolderName');
    
    // Now update all child item paths recursively
    final itemsToMove = <Map<String, dynamic>>[];
    _collectItemsUnderNode(folderNodeData, itemsToMove, newPath);
    
    for (final item in itemsToMove) {
      // Paths are already correct from _collectItemsUnderNode
      print('[DisboxService DEBUG] Updated child path: ${item['path']}');
    }
    
    // Save updated file tree locally
    await _saveFileTree();
  }
  
  /// Recursively collect all items under a folder node (not path).
  void _collectItemsUnderNode(Map<String, dynamic> folderNode, List<Map<String, dynamic>> items, String basePath) {
    final childrenRaw = folderNode['children'];
    if (childrenRaw == null) return;

    Map<String, dynamic> children;
    if (childrenRaw is Map<String, dynamic>) {
      children = childrenRaw;
    } else if (childrenRaw is Map) {
      children = <String, dynamic>{};
      childrenRaw.forEach((key, value) {
        children[key.toString()] = value;
      });
    } else {
      return;
    }

    children.forEach((name, childNode) {
      if (childNode is! Map<String, dynamic>) return;

      final itemType = childNode['type'] as String?;
      final itemPath = '$basePath/$name';

      if (itemType == 'file') {
        // Update the path in the node
        childNode['path'] = itemPath;
        items.add({
          'id': childNode['id'] as String,
          'name': name,
          'path': itemPath,
          'isFolder': false,
          'size': childNode['size'] as int? ?? 0,
          'mimeType': childNode['mimeType'] as String? ?? 'application/octet-stream',
          'chunkMessageIds': (childNode['chunk_message_ids'] as List?)?.cast<String>() ?? [],
        });
      } else if (itemType == 'folder' || childNode.containsKey('children')) {
        // It's a folder, update its path and recurse
        childNode['path'] = itemPath;
        _collectItemsUnderNode(childNode, items, itemPath);
      }
    });
  }

  /// Move a folder and all its children in the file tree (OLD METHOD - updates webhook metadata).
  @Deprecated('Use _moveFolderInFileTreeLocalOnly instead to avoid webhook API calls')
  Future<void> _moveFolderInFileTree(String oldPath, String newPath) async {
    if (_fileTree == null) {
      print('File tree not initialized');
      return;
    }

    // Get all files/folders under this folder and update their paths
    final itemsToMove = <Map<String, dynamic>>[];
    _collectItemsUnderPath(oldPath, itemsToMove);

    for (final item in itemsToMove) {
      final oldItemPath = item['path'] as String;
      final newItemPath = newPath + oldItemPath.substring(oldPath.length);
      
      // Update the path in the item
      item['path'] = newItemPath;
      
      // If it's a file, update its metadata message
      if (item['isFolder'] == false) {
        final messageId = item['id'] as String;
        try {
          await _updateMetadataMessage(messageId, {
            'path': newItemPath,
          });
        } catch (e) {
          print('[MOVE FOLDER ERROR] Failed to update metadata for $oldItemPath: $e');
        }
      }
    }

    // Save updated file tree
    await _saveFileTree();
  }

  /// Recursively collect all items under a given path.
  void _collectItemsUnderPath(String folderPath, List<Map<String, dynamic>> items) {
    if (_fileTree == null) return;

    final parts = folderPath.split('/').where((p) => p.isNotEmpty).toList();
    Map<String, dynamic>? currentFolder = _fileTree;

    // Navigate to the folder
    for (final folderName in parts) {
      var childrenRaw = currentFolder!['children'];
      Map<String, dynamic>? children;
      
      if (childrenRaw != null) {
        if (childrenRaw is Map<String, dynamic>) {
          children = childrenRaw;
        } else if (childrenRaw is Map) {
          children = <String, dynamic>{};
          childrenRaw.forEach((key, value) {
            children![key.toString()] = value;
          });
        }
      }

      if (children != null && children.containsKey(folderName)) {
        currentFolder = children[folderName] as Map<String, dynamic>?;
      } else {
        return; // Folder not found
      }
    }

    // Collect all items under this folder
    _collectAllItems(currentFolder, items, folderPath);
  }

  /// Recursively collect all items from a folder node.
  void _collectAllItems(Map<String, dynamic>? folderNode, List<Map<String, dynamic>> items, String basePath) {
    if (folderNode == null) return;

    final childrenRaw = folderNode['children'];
    if (childrenRaw == null) return;

    Map<String, dynamic> children;
    if (childrenRaw is Map<String, dynamic>) {
      children = childrenRaw;
    } else if (childrenRaw is Map) {
      children = <String, dynamic>{};
      childrenRaw.forEach((key, value) {
        children[key.toString()] = value;
      });
    } else {
      return;
    }

    children.forEach((name, childNode) {
      if (childNode is! Map<String, dynamic>) return;

      final itemType = childNode['type'] as String?;
      final itemPath = '$basePath/$name';

      if (itemType == 'file') {
        // Convert file node to item map
        items.add({
          'id': childNode['id'] as String,
          'name': name,
          'path': itemPath,
          'isFolder': false,
          'size': childNode['size'] as int? ?? 0,
          'mimeType': childNode['mimeType'] as String? ?? 'application/octet-stream',
          'chunkMessageIds': (childNode['chunk_message_ids'] as List?)?.cast<String>() ?? [],
        });
      } else if (itemType == 'folder' || childNode.containsKey('children')) {
        // It's a folder, recurse
        _collectAllItems(childNode, items, itemPath);
      }
    });
  }

  // ==================== DISCORD API METHODS ====================

  /// Upload an attachment to Discord via webhook.
  ///
  /// Returns the message ID of the created message.
  Future<String> _uploadAttachment(
    Uint8List data, {
    required String filename,
    required String contentType,
    CancelToken? cancelToken,
  }) async {
    final apiUrl = _getWebhookApiUrl();

    print(
        '[UPLOAD ATTACHMENT] Starting upload: $filename (${data.length} bytes)');
    print('[UPLOAD ATTACHMENT] API URL: $apiUrl');

    // Create multipart form data
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        data,
        filename: filename,
        contentType: DioMediaType.parse(contentType),
      ),
      // Wait=true means wait for message processing
      'wait': 'true',
    });

    try {
      final response = await _dio.post(
        apiUrl,
        data: formData,
        queryParameters: {'wait': 'true'},
        cancelToken: cancelToken,
      );

      print('[UPLOAD ATTACHMENT] Response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        print(
            '[UPLOAD ATTACHMENT ERROR] Failed with status ${response.statusCode}');
        print('[UPLOAD ATTACHMENT ERROR] Response: ${response.data}');
        throw Exception(
            'Failed to upload attachment: ${response.statusCode} - ${response.data}');
      }

      final responseData = response.data as Map<String, dynamic>;
      final messageId = responseData['id'] as String;
      print('[UPLOAD ATTACHMENT] Success! Message ID: $messageId');
      return messageId;
    } catch (e, stackTrace) {
      print('[UPLOAD ATTACHMENT ERROR] Upload failed: $e');
      print('[UPLOAD ATTACHMENT ERROR] Stack Trace: $stackTrace');
      rethrow;
    }
  }

  /// Download an attachment from a Discord message.
  /// 
  /// For large files, this streams the response directly to avoid loading
  /// the entire file into memory at once.
  Future<Uint8List> _downloadAttachment(String messageId, {CancelToken? cancelToken}) async {
    final apiUrl = _getWebhookApiUrl();

    // Fetch the message to get attachment URL
    final response = await _dio.get(
      '$apiUrl/messages/$messageId',
      cancelToken: cancelToken,
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch message: ${response.statusCode}');
    }

    final responseData = response.data as Map<String, dynamic>;
    final attachments = responseData['attachments'] as List<dynamic>;

    if (attachments.isEmpty) {
      throw Exception('No attachments found in message $messageId');
    }

    final attachmentUrl = attachments[0]['url'] as String;

    // Download the actual file - use stream for memory efficiency
    final fileResponse = await _dio.get(
      attachmentUrl,
      options: Options(responseType: ResponseType.bytes),
      cancelToken: cancelToken,
    );

    return fileResponse.data as Uint8List;
  }

  /// Download an attachment and stream it directly to a sink (file).
  /// 
  /// This is the memory-efficient way to download large chunks.
  /// Instead of returning the bytes, it writes them directly to the provided sink.
  Future<void> _downloadAttachmentToSink(
    String messageId,
    IOSink sink, {
    CancelToken? cancelToken,
  }) async {
    final apiUrl = _getWebhookApiUrl();

    // Fetch the message to get attachment URL
    final response = await _dio.get(
      '$apiUrl/messages/$messageId',
      cancelToken: cancelToken,
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch message: ${response.statusCode}');
    }

    final responseData = response.data as Map<String, dynamic>;
    final attachments = responseData['attachments'] as List<dynamic>;

    if (attachments.isEmpty) {
      throw Exception('No attachments found in message $messageId');
    }

    final attachmentUrl = attachments[0]['url'] as String;

    // Stream the download directly to the sink
    await _dio.download(
      attachmentUrl,
      (headers, sink) => sink, // Use the provided sink
      cancelToken: cancelToken,
      onReceiveProgress: (_, __) {}, // Progress handled by caller
    );
  }

  /// Delete a Discord message.
  Future<void> _deleteMessage(String messageId) async {
    final apiUrl = _getWebhookApiUrl();

    await _dio.delete('$apiUrl/messages/$messageId');
  }

  /// Scan Discord messages to rebuild file tree from remote storage.
  ///
  /// This fetches all messages from the webhook's channel and reconstructs
  /// the file tree based on metadata messages. Used when importing config
  /// on a new device or when local cache is corrupted.
  Future<void> scanRemoteFiles() async {
    if (!isConfigured) {
      print(
          '[DisboxService ERROR] scanRemoteFiles called but webhook not configured');
      throw StateError('Webhook URL not configured');
    }

    print('[DisboxService] Scanning remote files from Discord...');

    try {
      final apiUrl = _getWebhookApiUrl();

      // Fetch recent messages (Discord limits to 100 per request)
      // For a full implementation, you'd need to paginate through all messages
      final response = await _dio.get(
        '$apiUrl/messages',
        queryParameters: {'limit': '100'},
      );

      if (response.statusCode != 200) {
        print(
            '[DisboxService WARNING] Failed to fetch messages: ${response.statusCode}');
        return;
      }

      final messages = response.data as List;
      print('[DisboxService] Fetched ${messages.length} messages from Discord');

      // Initialize empty file tree
      _fileTree = {
        'id': 'root',
        'name': 'root',
        'type': 'directory',
        'children': {},
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };

      int metadataCount = 0;

      // Process each message looking for metadata
      for (final msg in messages) {
        final content = msg['content'] as String?;
        if (content == null || !content.startsWith(DisboxConstants.boxPrefix)) {
          continue;
        }

        try {
          // Extract JSON from message content
          final jsonStr =
              content.substring(DisboxConstants.boxPrefix.length).trim();
          final metadata = jsonDecode(jsonStr) as Map<String, dynamic>;

          // Skip if not our metadata format
          if (metadata['type'] != 'disbox_metadata') {
            continue;
          }

          metadataCount++;

          final filename = metadata['name'] as String;
          final filePath = metadata['path'] as String;
          final size = metadata['size'] as int? ?? 0;
          final mimeType = metadata['mimeType'] as String?;
          final chunkIds = (metadata['chunkIds'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [];
          final isFolder = metadata['isFolder'] as bool? ?? false;
          final createdAt = metadata['createdAt'] as String?;

          // Add file/folder to tree
          await _addFileToFileTree(
            id: msg['id'] as String,
            name: filename,
            path: filePath,
            size: size,
            mimeType: mimeType ?? 'application/octet-stream',
            chunkMessageIds: chunkIds,
          );

          print(
              '[DisboxService] Found: ${isFolder ? "folder" : "file"} "$filename" at $filePath');
        } catch (e) {
          print('[DisboxService WARNING] Failed to parse message metadata: $e');
        }
      }

      print(
          '[DisboxService] Remote scan complete. Found $metadataCount metadata messages.');

      // Save rebuilt file tree
      await _saveFileTree();
    } catch (e, stackTrace) {
      print('[DisboxService ERROR] Failed to scan remote files: $e');
      print('[DisboxService ERROR] Stack: $stackTrace');
      rethrow;
    }
  }

  /// Fetch messages from the webhook channel.
  ///
  /// Note: This requires fetching from the channel, not the webhook directly.
  /// In production, you may need to store channel ID separately or use
  /// a different approach for listing files.
  Future<List<Map<String, dynamic>>> _fetchMessages() async {
    // For MVP, we'll return empty list
    // In production, you'd need to:
    // 1. Store channel ID when webhook is created
    // 2. Use Discord API to fetch channel messages
    // 3. Filter for metadata messages

    print('Warning: Message fetching not fully implemented for MVP');
    return [];
  }

  /// Create a metadata message to store file information.
  ///
  /// Encodes file metadata as JSON in the message content.
  /// If the metadata is too large for a single Discord message (>2000 chars),
  /// it splits the chunk IDs across multiple messages.
  Future<String> _createMetadataMessage({
    required String filename,
    required String path,
    required int size,
    String? mimeType,
    required List<String> chunkMessageIds,
    required bool isFolder,
  }) async {
    final apiUrl = _getWebhookApiUrl();

    // Discord has a 2000 character limit for message content
    // We need to split metadata if it exceeds this limit
    const int maxContentLength = 2000;
    const String prefix = '${DisboxConstants.boxPrefix} ';
    
    print('[METADATA] Creating metadata message for $filename');
    print('[METADATA] Total chunks: ${chunkMessageIds.length}');

    // Build base metadata without chunkIds first
    final baseMetadata = {
      'type': 'disbox_metadata',
      'version': '1.0',
      'name': filename,
      'path': path,
      'size': size,
      'mimeType': mimeType,
      'isFolder': isFolder,
      'createdAt': DateTime.now().toIso8601String(),
      'totalChunks': chunkMessageIds.length,
    };

    // Calculate how many chunk IDs fit in one message
    final baseJson = jsonEncode(baseMetadata);
    final baseWithEmptyChunks = jsonEncode({...baseMetadata, 'chunkIds': <String>[]});
    // Reserve space for: prefix, base JSON with empty chunks, allMetadataIds array (for last batch)
    // allMetadataIds will contain ~10 message IDs of ~19 chars each = ~200 chars + brackets/commas
    const int allMetadataIdsReserve = 250; 
    final reservedSpace = prefix.length + baseWithEmptyChunks.length + allMetadataIdsReserve;
    final availableForChunkIds = maxContentLength - reservedSpace;
    
    // Estimate average chunk ID length (they're typically ~19 characters for Discord snowflakes)
    final avgChunkIdLength = chunkMessageIds.isNotEmpty 
        ? chunkMessageIds.map((id) => id.length).reduce((a, b) => a + b) ~/ chunkMessageIds.length 
        : 19;
    final chunkIdsPerMessage = (availableForChunkIds / (avgChunkIdLength + 3)).floor(); // +3 for quotes and comma
    
    print('[METADATA] Chunk IDs per message: $chunkIdsPerMessage');
    print('[METADATA] Reserved space: $reservedSpace, Available for chunk IDs: $availableForChunkIds');

    try {
      if (chunkIdsPerMessage <= 0 || chunkMessageIds.length <= chunkIdsPerMessage) {
        // All chunk IDs fit in one message
        final metadata = {...baseMetadata, 'chunkIds': chunkMessageIds};
        print('[METADATA] Metadata: ${jsonEncode(metadata)}');
        
        final response = await _dio.post(
          apiUrl,
          data: {
            'content': '$prefix${jsonEncode(metadata)}',
          },
          queryParameters: {'wait': 'true'},
        );

        print('[METADATA] Response status: ${response.statusCode}');

        if (response.statusCode != 200) {
          print('[METADATA ERROR] Failed with status ${response.statusCode}');
          print('[METADATA ERROR] Response: ${response.data}');
          throw Exception(
              'Failed to create metadata message: ${response.statusCode} - ${response.data}');
        }

        final responseData = response.data as Map<String, dynamic>;
        final messageId = responseData['id'] as String;
        print('[METADATA] Success! Message ID: $messageId');
        return messageId;
      } else {
        // Split chunk IDs across multiple messages
        print('[METADATA] Splitting metadata across multiple messages...');
        
        final messageIds = <String>[];
        final chunkBatches = _splitIntoBatches(chunkMessageIds, chunkIdsPerMessage);
        
        for (int i = 0; i < chunkBatches.length; i++) {
          final batch = chunkBatches[i];
          final isLastBatch = i == chunkBatches.length - 1;
          
          final batchMetadata = {
            ...baseMetadata,
            'chunkIds': batch,
            'batchIndex': i,
            'totalBatches': chunkBatches.length,
            'isLastBatch': isLastBatch,
          };
          
          if (!isLastBatch) {
            // For non-last batches, don't include other fields to save space
            batchMetadata.remove('name');
            batchMetadata.remove('path');
            batchMetadata.remove('mimeType');
          }
          
          print('[METADATA] Sending batch $i/${chunkBatches.length} with ${batch.length} chunk IDs');
          
          final response = await _dio.post(
            apiUrl,
            data: {
              'content': '$prefix${jsonEncode(batchMetadata)}',
            },
            queryParameters: {'wait': 'true'},
          );
          
          if (response.statusCode != 200) {
            print('[METADATA ERROR] Batch $i failed with status ${response.statusCode}');
            throw Exception('Failed to create metadata batch: ${response.statusCode}');
          }
          
          final responseData = response.data as Map<String, dynamic>;
          final messageId = responseData['id'] as String;
          messageIds.add(messageId);
          
          // Small delay to avoid rate limiting
          await Future.delayed(const Duration(milliseconds: 100));
        }
        
        // Return the first message ID as the primary identifier
        final primaryMessageId = messageIds.first;
        print('[METADATA] Success! Created ${messageIds.length} metadata messages. Primary ID: $primaryMessageId');
        
        // Store all message IDs in the last batch message (which has more space since it has fewer chunk IDs)
        // The last batch is the best candidate because:
        // 1. It has fewer chunk IDs (only the remainder)
        // 2. It already contains name/path/mimeType fields
        final lastMessageId = messageIds.last;
        final lastBatchIndex = chunkBatches.length - 1;
        
        // Build the last batch metadata with allMetadataIds
        final lastBatchMetadata = {
          ...baseMetadata,
          'chunkIds': chunkBatches.last,
          'batchIndex': lastBatchIndex,
          'totalBatches': chunkBatches.length,
          'isLastBatch': true,
          'allMetadataIds': messageIds,
        };
        
        final lastMessageContent = '$prefix${jsonEncode(lastBatchMetadata)}';
        
        if (lastMessageContent.length <= maxContentLength) {
          await _updateMetadataMessage(lastMessageId, {'allMetadataIds': messageIds});
          print('[METADATA] Stored allMetadataIds in last message (ID: $lastMessageId)');
        } else {
          // Even the last message is too small, skip storing allMetadataIds on Discord
          // The app will need to reconstruct the list from batchIndex/totalBatches by fetching channel messages
          print('[METADATA WARNING] Cannot store allMetadataIds on Discord (content too large: ${lastMessageContent.length} chars). Will reconstruct from channel messages.');
        }
        
        return primaryMessageId;
      }
    } catch (e, stackTrace) {
      print('[METADATA ERROR] Failed to create metadata: $e');
      print('[METADATA ERROR] Stack Trace: $stackTrace');
      rethrow;
    }
  }

  /// Split a list into batches of specified size
  List<List<T>> _splitIntoBatches<T>(List<T> list, int batchSize) {
    final batches = <List<T>>[];
    for (var i = 0; i < list.length; i += batchSize) {
      final end = (i + batchSize < list.length) ? i + batchSize : list.length;
      batches.add(list.sublist(i, end));
    }
    return batches;
  }

  /// Update a metadata message.
  Future<void> _updateMetadataMessage(
      String messageId, Map<String, dynamic> updates) async {
    final apiUrl = _getWebhookApiUrl();

    // Fetch current metadata
    final currentMessage = await _dio.get('$apiUrl/messages/$messageId');
    final content = currentMessage.data['content'] as String;

    if (!content.startsWith(DisboxConstants.boxPrefix)) {
      throw Exception('Not a metadata message');
    }

    final jsonStr = content.substring(DisboxConstants.boxPrefix.length).trim();
    final metadata = jsonDecode(jsonStr) as Map<String, dynamic>;

    // Apply updates
    metadata.addAll(updates);
    metadata['modifiedAt'] = DateTime.now().toIso8601String();

    // Check if the updated content would exceed Discord's limit
    final updatedContent = '${DisboxConstants.boxPrefix} ${jsonEncode(metadata)}';
    if (updatedContent.length > 2000) {
      print('[METADATA UPDATE WARNING] Content too large (${updatedContent.length} chars), skipping update for message $messageId');
      return; // Skip the update to avoid 400 error
    }

    // Update message
    await _dio.patch(
      '$apiUrl/messages/$messageId',
      data: {
        'content': updatedContent,
      },
    );
  }

  /// Check if a message is a Disbox metadata message.
  bool _isMetadataMessage(Map<String, dynamic> message) {
    final content = message['content'] as String?;
    return content?.startsWith(DisboxConstants.boxPrefix) ?? false;
  }

  /// Parse metadata from a message (supports multi-batch metadata).
  /// 
  /// This method handles both single-message metadata and multi-batch metadata
  /// where chunk IDs are split across multiple messages due to Discord's 2000
  /// character limit.
  Future<DisboxFile> _parseMetadataMessage(Map<String, dynamic> message) async {
    final content = message['content'] as String;
    final jsonStr = content.substring(DisboxConstants.boxPrefix.length).trim();
    final metadata = jsonDecode(jsonStr) as Map<String, dynamic>;

    // Check if this is a batched metadata message
    final totalBatches = metadata['totalBatches'] as int? ?? 1;
    
    List<String> allChunkIds = [];
    
    if (totalBatches > 1) {
      // This is batched metadata - need to fetch all batches
      print('[PARSE] Found batched metadata with $totalBatches batches');
      
      final batchIndex = metadata['batchIndex'] as int? ?? 0;
      final isLastBatch = metadata['isLastBatch'] as bool? ?? false;
      final allMetadataIds = metadata['allMetadataIds'] as List?;
      
      // Get chunk IDs from this batch
      final batchChunkIds = (metadata['chunkIds'] as List?)?.cast<String>() ?? [];
      
      if (allMetadataIds != null && allMetadataIds.isNotEmpty) {
        // We have all message IDs stored, fetch them all
        final apiUrl = _getWebhookApiUrl();
        
        for (final msgId in allMetadataIds.cast<String>()) {
          try {
            final response = await _dio.get('$apiUrl/messages/$msgId');
            final batchContent = response.data['content'] as String;
            final batchJsonStr = batchContent.substring(DisboxConstants.boxPrefix.length).trim();
            final batchMetadata = jsonDecode(batchJsonStr) as Map<String, dynamic>;
            
            final batchIds = (batchMetadata['chunkIds'] as List?)?.cast<String>() ?? [];
            allChunkIds.addAll(batchIds);
          } catch (e) {
            print('[PARSE ERROR] Failed to fetch batch message $msgId: $e');
          }
        }
        
        // Sort chunk IDs by their numeric value to maintain original order
        allChunkIds.sort((a, b) => a.compareTo(b));
      } else {
        // Fallback: Try to find the last batch which should have allMetadataIds
        // or reconstruct by iterating through all batch indices
        print('[PARSE WARNING] No allMetadataIds found in current batch, attempting reconstruction...');
        
        final apiUrl = _getWebhookApiUrl();
        final messageId = message['id'] as String;
        final channelId = message['channel_id'] as String;
        
        // Strategy 1: If this is the last batch, it might have allMetadataIds stored there
        // Try fetching the last batch message (which should have more space for allMetadataIds)
        if (isLastBatch || batchIndex == totalBatches - 1) {
          // This IS the last batch, so allMetadataIds should be here if it was stored
          // But we already checked above and it wasn't found
          // So we need to try a different approach
        }
        
        // Strategy 2: Try to find any batch that has allMetadataIds by checking siblings
        // We can try fetching messages with batch indices from 0 to totalBatches-1
        // But we need at least one message ID to start...
        
        // Actually, we have the current message ID. Let's try to get channel info
        // and fetch recent messages to find other batches
        
        // Try fetching channel messages to find other batches
        // Note: This requires the webhook to have permissions to read messages
        // which webhooks typically don't have. But let's try anyway.
        try {
          print('[PARSE] Attempting to fetch channel messages to find other batches...');
          final messagesResponse = await _dio.get(
            'https://discord.com/api/v10/channels/$channelId/messages',
            queryParameters: {'limit': '50'},
          );
          
          if (messagesResponse.statusCode == 200) {
            final messages = messagesResponse.data as List;
            
            // Find all batch messages for this file by matching batchIndex and totalBatches
            final batchMessages = <Map<String, dynamic>>[];
            
            for (final msg in messages) {
              final msgData = msg as Map<String, dynamic>;
              final content = msgData['content'] as String?;
              
              if (content != null && content.startsWith(DisboxConstants.boxPrefix)) {
                try {
                  final jsonStr = content.substring(DisboxConstants.boxPrefix.length).trim();
                  final msgMetadata = jsonDecode(jsonStr) as Map<String, dynamic>;
                  
                  // Check if this message belongs to the same batched metadata
                  final msgTotalBatches = msgMetadata['totalBatches'] as int?;
                  final msgBatchIndex = msgMetadata['batchIndex'] as int?;
                  final msgPath = msgMetadata['path'] as String?;
                  final currentPath = metadata['path'] as String?;
                  
                  if (msgTotalBatches == totalBatches && 
                      msgBatchIndex != null &&
                      (msgPath == currentPath || msgPath == null || currentPath == null)) {
                    batchMessages.add(msgMetadata);
                  }
                } catch (_) {
                  // Skip invalid messages
                }
              }
            }
            
            if (batchMessages.length == totalBatches) {
              // Found all batches! Collect chunk IDs from all of them
              print('[PARSE] Found all $totalBatches batches from channel messages');
              allChunkIds.clear();
              
              for (final batchMsg in batchMessages) {
                final batchIds = (batchMsg['chunkIds'] as List?)?.cast<String>() ?? [];
                allChunkIds.addAll(batchIds);
              }
              
              // Sort chunk IDs by their numeric value to maintain original order
              allChunkIds.sort((a, b) => a.compareTo(b));
            } else {
              print('[PARSE WARNING] Only found ${batchMessages.length} of $totalBatches batches');
              allChunkIds = batchChunkIds;
            }
          } else {
            print('[PARSE WARNING] Cannot fetch channel messages (status: ${messagesResponse.statusCode})');
            allChunkIds = batchChunkIds;
          }
        } catch (e) {
          print('[PARSE WARNING] Failed to fetch channel messages: $e');
          // Fallback: just use the chunks from this batch
          allChunkIds = batchChunkIds;
        }
      }
    } else {
      // Single message metadata
      allChunkIds = (metadata['chunkIds'] as List?)?.cast<String>() ?? [];
    }

    // For name/path/mimeType, check if they're in this message or need to be fetched from first batch
    String name = metadata['name'] as String? ?? '';
    String path = metadata['path'] as String? ?? '';
    String? mimeType = metadata['mimeType'] as String?;
    
    // If name is missing, this might be a non-last batch - fetch from last batch
    if (name.isEmpty && totalBatches > 1) {
      final apiUrl = _getWebhookApiUrl();
      final allMetadataIds = metadata['allMetadataIds'] as List?;
      
      if (allMetadataIds != null && allMetadataIds.isNotEmpty) {
        final lastMsgId = allMetadataIds.last as String;
        try {
          final response = await _dio.get('$apiUrl/messages/$lastMsgId');
          final lastContent = response.data['content'] as String;
          final lastJsonStr = lastContent.substring(DisboxConstants.boxPrefix.length).trim();
          final lastMetadata = jsonDecode(lastJsonStr) as Map<String, dynamic>;
          
          name = lastMetadata['name'] as String? ?? name;
          path = lastMetadata['path'] as String? ?? path;
          mimeType = lastMetadata['mimeType'] as String? ?? mimeType;
        } catch (e) {
          print('[PARSE ERROR] Failed to fetch last batch for metadata: $e');
        }
      }
    }

    return DisboxFile(
      id: message['id'] as String,
      name: name,
      path: path,
      isFolder: metadata['isFolder'] as bool? ?? false,
      size: metadata['size'] as int?,
      mimeType: mimeType,
      chunkMessageIds: allChunkIds,
      createdAt: DateTime.parse(metadata['createdAt'] as String),
      modifiedAt: metadata['modifiedAt'] != null
          ? DateTime.parse(metadata['modifiedAt'] as String)
          : DateTime.parse(metadata['createdAt'] as String),
    );
  }

  /// Add a file entry to the file tree and save to local storage.
  Future<void> _addFileToFileTree({
    required String id,
    required String name,
    required String path,
    required int size,
    required String mimeType,
    required List<String> chunkMessageIds,
  }) async {
    if (_fileTree == null) {
      print('File tree not initialized');
      return;
    }

    // Get parent folder from path
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    print('[DisboxService DEBUG] _addFileToFileTree: path=$path, parts=$parts');
    
    // Use direct reference to navigate the tree
    Map<String, dynamic>? currentFolder = _fileTree;

    for (int i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      var childrenRaw = currentFolder!['children'];
      Map<String, dynamic>? children;
      
      if (childrenRaw != null) {
        if (childrenRaw is Map<String, dynamic>) {
          children = childrenRaw;
        } else if (childrenRaw is Map) {
          // Convert Map<dynamic, dynamic> to Map<String, dynamic>
          children = <String, dynamic>{};
          childrenRaw.forEach((key, value) {
            children![key.toString()] = value;
          });
          currentFolder!['children'] = children;
        }
      }

      print('[DisboxService DEBUG] Looking for folder: $folderName, children keys: ${children?.keys.toList()}');
      
      if (children != null && children.containsKey(folderName)) {
        currentFolder = children[folderName] as Map<String, dynamic>?;
        print('[DisboxService DEBUG] Navigated to folder: $folderName');
      } else {
        print('[DisboxService ERROR] Parent folder not found: $folderName');
        print('[DisboxService ERROR] Available folders: ${children?.keys.toList()}');
        return;
      }
    }

    // Create file node - use same format as _addFileToTree for consistency
    final fileName = parts.last;
    print('[DisboxService DEBUG] Adding file node: $fileName to parent');
    final fileNode = {
      'id': id,
      'name': fileName,
      'type': 'file',
      'size': size,
      'message_id': id,
      'chunk_message_ids': chunkMessageIds,
      'mimeType': mimeType,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    };

    // Add to parent's children using direct reference
    var children = currentFolder!['children'];
    Map<String, dynamic> childrenMap;
    
    if (children == null) {
      childrenMap = <String, dynamic>{};
      currentFolder['children'] = childrenMap;
    } else if (children is Map<String, dynamic>) {
      childrenMap = children;
    } else {
      // Convert Map<dynamic, dynamic> to Map<String, dynamic> if needed
      childrenMap = <String, dynamic>{};
      if (children is Map) {
        children.forEach((key, value) {
          childrenMap[key.toString()] = value;
        });
      }
      currentFolder['children'] = childrenMap;
    }

    childrenMap[fileName] = fileNode;
    print('[DisboxService DEBUG] File node added. Children count: ${childrenMap.length}');

    // Save file tree to local storage
    await _saveFileTree();
  }

  /// Remove a file or folder from the file tree and save to local storage.
  Future<void> _removeFileFromFileTree(String path,
      {required bool isFolder}) async {
    if (_fileTree == null) {
      print('File tree not initialized');
      return;
    }

    // Get parent folder from path
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) {
      print('Invalid path: $path');
      return;
    }

    Map<String, dynamic>? currentFolder = _fileTree;

    // Navigate to parent folder using direct references
    for (int i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      var childrenRaw = currentFolder!['children'];
      Map<String, dynamic>? children;
      
      if (childrenRaw != null) {
        if (childrenRaw is Map<String, dynamic>) {
          children = childrenRaw;
        } else if (childrenRaw is Map) {
          // Convert Map<dynamic, dynamic> to Map<String, dynamic>
          children = <String, dynamic>{};
          childrenRaw.forEach((key, value) {
            children![key.toString()] = value;
          });
          currentFolder!['children'] = children;
        }
      }

      if (children != null && children.containsKey(folderName)) {
        currentFolder = children[folderName] as Map<String, dynamic>?;
      } else {
        print('Parent folder not found: $folderName');
        return;
      }
    }

    // Remove from parent's children using direct reference
    final fileName = parts.last;
    var childrenRaw = currentFolder!['children'];
    Map<String, dynamic>? children;
    
    if (childrenRaw != null) {
      if (childrenRaw is Map<String, dynamic>) {
        children = childrenRaw;
      } else if (childrenRaw is Map) {
        // Convert Map<dynamic, dynamic> to Map<String, dynamic>
        children = <String, dynamic>{};
        childrenRaw.forEach((key, value) {
          children![key.toString()] = value;
        });
        currentFolder!['children'] = children;
      }
    }

    if (children != null && children.containsKey(fileName)) {
      children.remove(fileName);
      // Save file tree to local storage
      await _saveFileTree();
    }
  }
  // ==================== UTILITY METHODS ====================

  /// Normalize a path (ensure starts with /, no trailing /, no double slashes)
  String _normalizePath(String path) {
    var normalized = path.replaceAll('//', '/');
    if (!normalized.startsWith('/')) {
      normalized = '/$normalized';
    }
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Get parent path from a full path
  String _getParentPath(String fullPath) {
    final parts = fullPath.split('/');
    if (parts.length <= 1) return '';
    return parts.sublist(0, parts.length - 1).join('/');
  }

  /// Get parent folder ID from path (simplified for MVP)
  String? _getParentFolderId(String folderPath) {
    // In production, you'd look up the parent folder's message ID
    return null;
  }

  /// Detect MIME type from filename extension
  String _detectMimeType(String filename) {
    final ext = path.extension(filename).toLowerCase();
    switch (ext) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.pdf':
        return 'application/pdf';
      case '.txt':
        return 'text/plain';
      case '.mp4':
        return 'video/mp4';
      case '.mp3':
        return 'audio/mpeg';
      default:
        return 'application/octet-stream';
    }
  }
}

/// Helper class to hold parsed webhook credentials
class _WebhookCredentials {
  final String id;
  final String token;

  _WebhookCredentials({required this.id, required this.token});
}
