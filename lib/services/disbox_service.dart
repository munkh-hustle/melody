import 'dart:convert';
import 'dart:io';
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

  // Stream controllers for progress updates
  final _uploadProgressController = BehaviorSubject<double>.seeded(0.0);
  final _downloadProgressController = BehaviorSubject<double>.seeded(0.0);

  /// Stream of upload progress (0.0 to 1.0)
  Stream<double> get uploadProgress => _uploadProgressController.stream;

  /// Stream of download progress (0.0 to 1.0)
  Stream<double> get downloadProgress => _downloadProgressController.stream;

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

      final content = await jsonFile.readAsString();
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

      // Create DisboxFile from the metadata
      // Note: Discord message metadata doesn't have a unique file ID in the same way,
      // so we use the first chunk ID or generate one from the path
      final chunkIds = (metadata['chunkIds'] as List?)?.cast<String>() ?? [];
      final fileId = chunkIds.isNotEmpty ? chunkIds.first : _hashWebhookUrl(metadata['path'] as String);

      final disboxFile = DisboxFile(
        id: fileId,
        name: metadata['name'] as String,
        path: metadata['path'] as String,
        isFolder: metadata['isFolder'] as bool? ?? false,
        size: metadata['size'] as int?,
        mimeType: metadata['mimeType'] as String?,
        chunkMessageIds: chunkIds,
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
  /// Returns the number of successfully imported files.
  Future<int> importMultipleMetadataFromText(List<String> metadataTexts) async {
    int successCount = 0;
    for (final text in metadataTexts) {
      final result = await importMetadataFromText(text);
      if (result != null) {
        successCount++;
      }
    }
    return successCount;
  }

  /// Check if webhook URL is configured
  bool get isConfigured => _webhookUrl != null;

  /// Get the account ID (hashed webhook URL)
  String? get accountId => _accountId;

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

    if (path == '/') {
      // Root node
      print('[DisboxService DEBUG] Adding root node');
      root['name'] = file.name;
      return;
    }

    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    print('[DisboxService DEBUG] Path parts: $parts');
    var current = root;

    // Navigate to parent directory
    for (int i = 0; i < parts.length - 1; i++) {
      final part = parts[i];
      final children = current['children'] as Map<String, dynamic>;
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
    final children = current['children'] as Map<String, dynamic>;
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

    // Reset upload progress stream
    _uploadProgressController.add(0.0);

    final filename = path.basename(file.path);
    final filePath = _normalizePath('$folderPath/$filename');
    final fileSize = file.lengthSync();
    final mimeType = _detectMimeType(filename);

    print('Uploading: $filename ($fileSize bytes) to $filePath');

    // Determine if we need to chunk the file
    final needsChunking = fileSize > DisboxConstants.maxAttachmentSize;
    final chunkMessageIds = <String>[];

    if (needsChunking) {
      // Upload as chunks
      final chunks = ChunkUtils.splitFile(file);
      print('File requires chunking: ${chunks.length} chunks');

      var uploadedBytes = 0;

      for (int i = 0; i < chunks.length; i++) {
        try {
          final chunkData = await ChunkUtils.readChunk(file, i);

          print(
              'Uploading chunk ${i + 1}/${chunks.length} (${chunkData.length} bytes)');

          final messageId = await _uploadAttachment(
            chunkData,
            filename: '${filename}.part$i',
            contentType: 'application/octet-stream',
          );

          chunkMessageIds.add(messageId);
          uploadedBytes += chunkData.length;

          // Update progress stream
          final progress = uploadedBytes / fileSize;
          _uploadProgressController.add(progress);

          print(
              'Chunk ${i + 1}/${chunks.length} uploaded successfully. Message ID: $messageId');
          onProgress?.call(uploadedBytes, fileSize);
        } catch (e, stackTrace) {
          print(
              '[UPLOAD ERROR] Failed to upload chunk ${i + 1}/${chunks.length}: $e');
          print('[UPLOAD ERROR] Stack Trace: $stackTrace');
          rethrow;
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
        );

        chunkMessageIds.add(messageId);

        // Update progress stream to complete
        _uploadProgressController.add(1.0);

        print('Single file uploaded successfully. Message ID: $messageId');
        onProgress?.call(fileSize, fileSize);
      } catch (e, stackTrace) {
        print('[UPLOAD ERROR] Failed to upload single file: $e');
        print('[UPLOAD ERROR] Stack Trace: $stackTrace');
        rethrow;
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

    // Reset download progress stream
    _downloadProgressController.add(0.0);

    print('Downloading: ${file.name} (${file.chunkMessageIds.length} chunks)');

    final chunks = <(int, Uint8List)>[];
    var downloadedBytes = 0;
    final totalBytes = file.size ?? 0;

    try {
      // Download each chunk
      for (int i = 0; i < file.chunkMessageIds.length; i++) {
        final messageId = file.chunkMessageIds[i];

        print('Downloading chunk ${i + 1}/${file.chunkMessageIds.length}');

        final chunkData = await _downloadAttachment(messageId);
        chunks.add((i, chunkData));
        downloadedBytes += chunkData.length;

        // Update progress stream
        final progress = totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;
        _downloadProgressController.add(progress);

        onProgress?.call(downloadedBytes, totalBytes);
      }

      // Reassemble chunks
      await ChunkUtils.assembleChunks(chunks, outputPath);

      // Mark download as complete
      _downloadProgressController.add(1.0);

      print(
          'Download complete: $outputPath (${await File(outputPath).length()} bytes)');

      return File(outputPath);
    } catch (e, stackTrace) {
      print('[DOWNLOAD ERROR] Failed to download file: $e');
      print('[DOWNLOAD ERROR] Stack Trace: $stackTrace');
      // Cleanup partial download on error
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
      final childrenData = currentNode?['children'];
      Map<String, dynamic>? children;
      if (childrenData is Map) {
        children = <String, dynamic>{};
        for (final entry in childrenData.entries) {
          children[entry.key.toString()] = entry.value;
        }
      } else if (childrenData != null) {
        print('[DisboxService DEBUG] Unexpected children type: ${childrenData.runtimeType}');
      }
      print('[DisboxService DEBUG] Looking for part: $part, children keys: ${children?.keys.toList()}');

      if (children == null || !children.containsKey(part)) {
        print('[DisboxService DEBUG] Part not found: $part');
        return null;
      }

      Map<String, dynamic>? nextNode;
      final nodeData = children[part];
      if (nodeData is Map) {
        nextNode = <String, dynamic>{};
        for (final entry in nodeData.entries) {
          nextNode[entry.key.toString()] = entry.value;
        }
      } else if (nodeData != null) {
        print('[DisboxService DEBUG] Unexpected node data type: ${nodeData.runtimeType}');
      }

      currentNode = nextNode;

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

    // Check if folder already exists
    final childrenData = parentFolder['children'];
    Map<String, dynamic>? children;
    if (childrenData is Map) {
      children = <String, dynamic>{};
      for (final entry in childrenData.entries) {
        children[entry.key.toString()] = entry.value;
      }
    }

    if (children != null && children.containsKey(name)) {
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

    // Add to parent's children
    if (children == null) {
      parentFolder['children'] = {name: folderNode};
    } else {
      children[name] = folderNode;
    }

    // Save file tree to local storage
    await _saveFileTree();

    final folder = DisboxFile(
      id: newId,
      name: name,
      path: folderPath,
      isFolder: true,
      size: 0,
      createdAt: DateTime.now(),
      modifiedAt: DateTime.now(),
    );

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

    // Update metadata message
    await _updateMetadataMessage(file.id, {
      'name': newName,
      'path': newPath,
    });

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

  // ==================== DISCORD API METHODS ====================

  /// Upload an attachment to Discord via webhook.
  ///
  /// Returns the message ID of the created message.
  Future<String> _uploadAttachment(
    Uint8List data, {
    required String filename,
    required String contentType,
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
  Future<Uint8List> _downloadAttachment(String messageId) async {
    final apiUrl = _getWebhookApiUrl();

    // Fetch the message to get attachment URL
    final response = await _dio.get(
      '$apiUrl/messages/$messageId',
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

    // Download the actual file
    final fileResponse = await _dio.get(
      attachmentUrl,
      options: Options(responseType: ResponseType.bytes),
    );

    return fileResponse.data as Uint8List;
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
  /// Create a metadata message to store file information.
  ///
  /// Encodes file metadata as JSON in the message content.
  Future<String> _createMetadataMessage({
    required String filename,
    required String path,
    required int size,
    String? mimeType,
    required List<String> chunkMessageIds,
    required bool isFolder,
  }) async {
    final apiUrl = _getWebhookApiUrl();

    final metadata = {
      'type': 'disbox_metadata',
      'version': '1.0',
      'name': filename,
      'path': path,
      'size': size,
      'mimeType': mimeType,
      'chunkIds': chunkMessageIds,
      'isFolder': isFolder,
      'createdAt': DateTime.now().toIso8601String(),
    };

    print('[METADATA] Creating metadata message for $filename');
    print('[METADATA] Metadata: ${jsonEncode(metadata)}');

    try {
      final response = await _dio.post(
        apiUrl,
        data: {
          'content': '${DisboxConstants.boxPrefix} ${jsonEncode(metadata)}',
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
    } catch (e, stackTrace) {
      print('[METADATA ERROR] Failed to create metadata: $e');
      print('[METADATA ERROR] Stack Trace: $stackTrace');
      rethrow;
    }
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

    // Update message
    await _dio.patch(
      '$apiUrl/messages/$messageId',
      data: {
        'content': '${DisboxConstants.boxPrefix} ${jsonEncode(metadata)}',
      },
    );
  }

  /// Check if a message is a Disbox metadata message.
  bool _isMetadataMessage(Map<String, dynamic> message) {
    final content = message['content'] as String?;
    return content?.startsWith(DisboxConstants.boxPrefix) ?? false;
  }

  /// Parse metadata from a message.
  DisboxFile _parseMetadataMessage(Map<String, dynamic> message) {
    final content = message['content'] as String;
    final jsonStr = content.substring(DisboxConstants.boxPrefix.length).trim();
    final metadata = jsonDecode(jsonStr) as Map<String, dynamic>;

    return DisboxFile(
      id: message['id'] as String,
      name: metadata['name'] as String,
      path: metadata['path'] as String,
      isFolder: metadata['isFolder'] as bool,
      size: metadata['size'] as int?,
      mimeType: metadata['mimeType'] as String?,
      chunkMessageIds: (metadata['chunkIds'] as List?)?.cast<String>() ?? [],
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
    Map<String, dynamic>? currentFolder = _fileTree;

    for (int i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      final childrenData = currentFolder!['children'];
      Map<String, dynamic>? children;
      if (childrenData is Map) {
        children = <String, dynamic>{};
        for (final entry in childrenData.entries) {
          children[entry.key.toString()] = entry.value;
        }
      }

      if (children != null && children.containsKey(folderName)) {
        Map<String, dynamic>? nextFolder;
        final folderData = children[folderName];
        if (folderData is Map) {
          nextFolder = <String, dynamic>{};
          for (final entry in folderData.entries) {
            nextFolder[entry.key.toString()] = entry.value;
          }
        }
        currentFolder = nextFolder;
      } else {
        print('Parent folder not found: $folderName');
        return;
      }
    }

    // Create file node
    final fileName = parts.last;
    final fileNode = {
      'id': id,
      'name': fileName,
      'type': 'file',
      'size': size,
      'mime_type': mimeType,
      'content': jsonEncode(chunkMessageIds),
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    };

    // Add to parent's children
    final childrenData = currentFolder!['children'];
    Map<String, dynamic> children;
    if (childrenData is Map) {
      children = <String, dynamic>{};
      for (final entry in childrenData.entries) {
        children[entry.key.toString()] = entry.value;
      }
    } else {
      children = <String, dynamic>{};
    }

    children[fileName] = fileNode;
    currentFolder['children'] = children;

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

    // Navigate to parent folder
    for (int i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      final childrenData = currentFolder!['children'];
      Map<String, dynamic>? children;
      if (childrenData is Map) {
        children = <String, dynamic>{};
        for (final entry in childrenData.entries) {
          children[entry.key.toString()] = entry.value;
        }
      }

      if (children != null && children.containsKey(folderName)) {
        Map<String, dynamic>? nextFolder;
        final folderData = children[folderName];
        if (folderData is Map) {
          nextFolder = <String, dynamic>{};
          for (final entry in folderData.entries) {
            nextFolder[entry.key.toString()] = entry.value;
          }
        }
        currentFolder = nextFolder;
      } else {
        print('Parent folder not found: $folderName');
        return;
      }
    }

    // Remove from parent's children
    final fileName = parts.last;
    final childrenData = currentFolder!['children'];
    Map<String, dynamic>? children;
    if (childrenData is Map) {
      children = <String, dynamic>{};
      for (final entry in childrenData.entries) {
        children[entry.key.toString()] = entry.value;
      }
    }

    if (children != null && children.containsKey(fileName)) {
      children.remove(fileName);
      currentFolder['children'] = children;

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
