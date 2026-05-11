import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Constants for Discord API and file chunking
class DisboxConstants {
  /// Discord attachment size limit (10MB for most users)
  static const int maxAttachmentSize = 10 * 1024 * 1024; // 10 MB
  
  /// Recommended chunk size (slightly under limit for safety)
  static const int chunkSize = 9 * 1024 * 1024; // 9 MB
  
  /// Discord API base URL
  static const String discordApiBase = 'https://discord.com/api/webhooks';
  
  /// Box name prefix for metadata messages
  static const String boxPrefix = '[DISBOX]';
}

/// Utility class for splitting files into chunks
class ChunkUtils {
  /// Calculate how many chunks a file will need
  static int calculateChunkCount(int fileSize) {
    if (fileSize <= 0) return 1;
    return (fileSize / DisboxConstants.chunkSize).ceil();
  }

  /// Split a file into chunks that fit Discord's attachment limit
  /// 
  /// Returns a list of [FileChunk] objects containing the data and metadata
  static List<FileChunk> splitFile(File file, {int? customChunkSize}) {
    final chunkSize = customChunkSize ?? DisboxConstants.chunkSize;
    final fileSize = file.lengthSync();
    final chunkCount = calculateChunkCount(fileSize);
    
    final chunks = <FileChunk>[];
    final random = Random.secure();
    final sessionId = _generateSessionId();
    
    for (int i = 0; i < chunkCount; i++) {
      final startOffset = i * chunkSize;
      final endOffset = min(startOffset + chunkSize, fileSize);
      final actualChunkSize = endOffset - startOffset;
      
      chunks.add(FileChunk(
        sessionId: sessionId,
        chunkIndex: i,
        totalChunks: chunkCount,
        offset: startOffset,
        size: actualChunkSize,
        originalFileSize: fileSize,
      ));
    }
    
    return chunks;
  }

  /// Read a specific chunk from a file
  /// 
  /// [chunkIndex] is 0-based index of which chunk to read
  /// Returns the bytes for that chunk
  static Future<Uint8List> readChunk(File file, int chunkIndex, {int? customChunkSize}) async {
    final chunkSize = customChunkSize ?? DisboxConstants.chunkSize;
    final startOffset = chunkIndex * chunkSize;
    
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(startOffset);
      
      // Read up to chunkSize bytes
      final remaining = file.lengthSync() - startOffset;
      final bytesToRead = min(chunkSize, remaining);
      
      final buffer = Uint8List(bytesToRead);
      await raf.readInto(buffer);
      
      return buffer;
    } finally {
      await raf.close();
    }
  }

  /// Generate a unique session ID for tracking chunk uploads
  static String _generateSessionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Reassemble chunks back into a complete file
  /// 
  /// [chunks] should be ordered by chunkIndex
  /// [outputPath] is where the reassembled file will be saved
  static Future<File> assembleChunks(
    List<(int, Uint8List)> chunks,
    String outputPath,
  ) async {
    // Sort chunks by index
    chunks.sort((a, b) => a.$1.compareTo(b.$1));
    
    final outputFile = File(outputPath);
    final sink = outputFile.openWrite();
    
    try {
      for (final chunk in chunks) {
        sink.add(chunk.$2);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    
    return outputFile;
  }

  /// Validate chunk integrity using simple size check
  /// For production, consider adding checksums (MD5/SHA256)
  static bool validateChunk(Uint8List chunk, int expectedSize) {
    return chunk.length == expectedSize;
  }
}

/// Represents a single chunk of a file to be uploaded
class FileChunk {
  final String sessionId; // Groups chunks from same upload session
  final int chunkIndex; // 0-based index
  final int totalChunks; // Total number of chunks
  final int offset; // Byte offset in original file
  final int size; // Size of this chunk in bytes
  final int originalFileSize; // Size of complete file

  FileChunk({
    required this.sessionId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.offset,
    required this.size,
    required this.originalFileSize,
  });

  @override
  String toString() {
    return 'FileChunk(index: $chunkIndex/$totalChunks, offset: $offset, size: $size)';
  }
}

/// Extension to help with byte formatting
extension IntExtension on int {
  /// Format bytes as human-readable string
  String get formattedBytes {
    if (this < 1024) return '$this B';
    if (this < 1024 * 1024) return '${(this / 1024).toStringAsFixed(1)} KB';
    if (this < 1024 * 1024 * 1024) {
      return '${(this / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(this / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
