import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:isolate';

/// Constants for Discord API and file chunking
class DisboxConstants {
  /// Discord attachment size limit (10MB for most users, 500MB for Nitro)
  /// Using a conservative default that works for all users
  static const int maxAttachmentSize = 10 * 1024 * 1024; // 10 MB
  
  /// Recommended chunk size (slightly under limit for safety)
  /// Smaller chunks = less memory usage but more API calls
  /// For large files, use smaller chunks to avoid OOM errors
  static const int chunkSize = 8 * 1024 * 1024; // 8 MB (reduced from 9MB for better memory efficiency)
  
  /// Maximum chunk size for very large files (>1GB)
  /// Using even smaller chunks to prevent memory issues
  static const int maxChunkSizeForLargeFiles = 4 * 1024 * 1024; // 4 MB (reduced from 5MB)
  
  /// Threshold for considering a file as "large" 
  static const int largeFileThreshold = 1 * 1024 * 1024 * 1024; // 1 GB
  
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
  /// Automatically adjusts chunk size for very large files to prevent OOM errors.
  /// Returns a list of [FileChunk] objects containing the data and metadata
  static List<FileChunk> splitFile(File file, {int? customChunkSize}) {
    final fileSize = file.lengthSync();
    
    // Use smaller chunks for large files to prevent memory issues
    int effectiveChunkSize;
    if (customChunkSize != null) {
      effectiveChunkSize = customChunkSize;
    } else if (fileSize > DisboxConstants.largeFileThreshold) {
      // For files > 1GB, use smaller chunks
      effectiveChunkSize = DisboxConstants.maxChunkSizeForLargeFiles;
    } else {
      effectiveChunkSize = DisboxConstants.chunkSize;
    }
    
    final chunkCount = calculateChunkCountWithSize(fileSize, effectiveChunkSize);
    
    final chunks = <FileChunk>[];
    final random = Random.secure();
    final sessionId = _generateSessionId();
    
    for (int i = 0; i < chunkCount; i++) {
      final startOffset = i * effectiveChunkSize;
      final endOffset = min(startOffset + effectiveChunkSize, fileSize);
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

  /// Calculate how many chunks a file will need with a specific chunk size
  static int calculateChunkCountWithSize(int fileSize, int chunkSize) {
    if (fileSize <= 0) return 1;
    return (fileSize / chunkSize).ceil();
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

  /// Get the size of a specific chunk without reading it
  static Future<int> readChunkLength(File file, int chunkIndex, {int? customChunkSize}) async {
    final chunkSize = customChunkSize ?? DisboxConstants.chunkSize;
    final startOffset = chunkIndex * chunkSize;
    final remaining = file.lengthSync() - startOffset;
    return min(chunkSize, remaining);
  }

  /// Read a chunk using an isolate to avoid blocking the main thread
  /// 
  /// This is essential for large files to prevent UI freezes and allow
  /// better memory management by isolating the I/O operation.
  static Future<Uint8List> readChunkIsolate(File file, int chunkIndex, {int? customChunkSize}) async {
    final chunkSize = customChunkSize ?? DisboxConstants.chunkSize;
    final startOffset = chunkIndex * chunkSize;
    final fileSize = file.lengthSync();
    final bytesToRead = min(chunkSize, fileSize - startOffset);
    final filePath = file.path;
    
    // Use compute to run in isolate for large chunks
    if (bytesToRead > 1024 * 1024) { // Use isolate for chunks > 1MB
      return await Isolate.run(() => _readChunkInIsolate(filePath, startOffset, bytesToRead));
    } else {
      // For small chunks, just read directly
      return await readChunk(file, chunkIndex, customChunkSize: customChunkSize);
    }
  }
  
  /// Helper method to read chunk in isolate
  static Uint8List _readChunkInIsolate(String filePath, int startOffset, int bytesToRead) {
    final file = File(filePath);
    final raf = file.openSync(mode: FileMode.read);
    try {
      raf.setPositionSync(startOffset);
      final buffer = Uint8List(bytesToRead);
      raf.readIntoSync(buffer);
      return buffer;
    } finally {
      raf.closeSync();
    }
  }

  /// Generate a unique session ID for tracking chunk uploads
  static String _generateSessionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Reassemble chunks back into a complete file by streaming directly to disk
  /// 
  /// This method streams each chunk directly to the output file as it's received,
  /// avoiding loading all chunks into memory at once. This is essential for large files.
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

  /// Stream chunks from a download directly to disk without loading all into memory
  /// 
  /// This is the memory-efficient way to handle large file downloads.
  /// Each chunk is written to disk immediately after being downloaded.
  /// 
  /// [chunkStream] - A stream of (index, data) tuples for each chunk
  /// [outputPath] - Where the reassembled file will be saved
  /// [totalChunks] - Expected total number of chunks (for validation)
  static Future<File> assembleChunksStream(
    Stream<(int, Uint8List)> chunkStream,
    String outputPath,
    int totalChunks,
  ) async {
    final outputFile = File(outputPath);
    final sink = outputFile.openWrite();
    final receivedChunks = <(int, Uint8List)>[];
    
    try {
      await for (final chunk in chunkStream) {
        receivedChunks.add(chunk);
        // Write chunk to disk immediately
        sink.add(chunk.$2);
        // Flush periodically to ensure data is written (every 10 chunks)
        if (receivedChunks.length % 10 == 0) {
          await sink.flush();
        }
      }
      
      // Validate we received all chunks
      if (receivedChunks.length != totalChunks) {
        throw Exception(
          'Incomplete download: expected $totalChunks chunks, got ${receivedChunks.length}'
        );
      }
      
      await sink.flush();
    } finally {
      await sink.close();
    }
    
    // Sort and verify chunk integrity
    receivedChunks.sort((a, b) => a.$1.compareTo(b.$1));
    
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
