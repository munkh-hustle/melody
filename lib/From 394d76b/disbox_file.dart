import 'dart:io';
import 'dart:typed_data';

/// Represents a file or folder in the Disbox cloud storage.
/// 
/// This model stores metadata about files/folders that is synced with Discord messages.
class DisboxFile {
  final String id; // Unique identifier (message ID for files, custom ID for folders)
  final String name;
  final String path; // Full path like "/folder1/folder2/file.txt"
  final bool isFolder;
  final int? size; // Size in bytes (null for folders)
  final String? mimeType;
  final List<String> chunkMessageIds; // For files: list of Discord message IDs containing chunks
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String? parentId; // Parent folder ID (null for root)

  DisboxFile({
    required this.id,
    required this.name,
    required this.path,
    required this.isFolder,
    this.size,
    this.mimeType,
    this.chunkMessageIds = const [],
    required this.createdAt,
    required this.modifiedAt,
    this.parentId,
  });

  /// Create from JSON (for storing in Hive/SharedPreferences)
  factory DisboxFile.fromJson(Map<String, dynamic> json) {
    // Handle both field naming conventions:
    // - camelCase (from toJson): 'chunkMessageIds'
    // - snake_case (from exported JSON): 'chunk_message_ids'
    List<String> chunkIds = [];
    if (json.containsKey('chunkMessageIds')) {
      chunkIds = (json['chunkMessageIds'] as List?)?.cast<String>() ?? [];
    } else if (json.containsKey('chunk_message_ids')) {
      chunkIds = (json['chunk_message_ids'] as List?)?.cast<String>() ?? [];
    }
    
    return DisboxFile(
      id: json['id'] as String,
      name: json['name'] as String,
      path: json['path'] as String,
      isFolder: json['isFolder'] as bool,
      size: json['size'] as int?,
      mimeType: json['mimeType'] as String?,
      chunkMessageIds: chunkIds,
      createdAt: DateTime.parse(json['createdAt'] as String),
      modifiedAt: DateTime.parse(json['modifiedAt'] as String),
      parentId: json['parentId'] as String?,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'path': path,
      'isFolder': isFolder,
      'size': size,
      'mimeType': mimeType,
      'chunkMessageIds': chunkMessageIds,
      'createdAt': createdAt.toIso8601String(),
      'modifiedAt': modifiedAt.toIso8601String(),
      'parentId': parentId,
    };
  }

  /// Get file extension
  String get extension {
    if (isFolder) return '';
    final parts = name.split('.');
    return parts.length > 1 ? '.${parts.last}' : '';
  }

  /// Format file size for display
  String get formattedSize {
    if (isFolder) return '--';
    if (size == null) return 'Unknown';
    
    if (size! < 1024) return '$size B';
    if (size! < 1024 * 1024) return '${(size! / 1024).toStringAsFixed(1)} KB';
    if (size! < 1024 * 1024 * 1024) {
      return '${(size! / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size! / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  String toString() => 'DisboxFile($name, ${isFolder ? "folder" : "$size bytes"})';
}
