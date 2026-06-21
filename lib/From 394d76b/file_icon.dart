import 'package:flutter/material.dart';

import '../models/disbox_file.dart';

/// A widget that displays an appropriate icon for a file or folder.
class FileIcon extends StatelessWidget {
  final DisboxFile file;
  final double size;

  const FileIcon({
    super.key,
    required this.file,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    try {
      return _buildIcon(context);
    } catch (e, stackTrace) {
      print('[FileIcon ERROR] Build failed for ${file.name}: $e');
      print('[FileIcon ERROR] Stack: $stackTrace');
      return Icon(Icons.error_outline, size: size, color: Colors.red);
    }
  }

  Widget _buildIcon(BuildContext context) {
    if (file.isFolder) {
      return Icon(Icons.folder, size: size, color: Colors.amber[700]);
    } else {
      return _getFileIcon(file.name, file.mimeType);
    }
  }

  Widget _getFileIcon(String filename, String? mimeType) {
    final ext = _getExtension(filename).toLowerCase();
    
    // Determine icon based on file type
    IconData iconData;
    Color iconColor;

    if (_isImage(ext, mimeType)) {
      iconData = Icons.image;
      iconColor = Colors.purple;
    } else if (_isVideo(ext, mimeType)) {
      iconData = Icons.video_file;
      iconColor = Colors.red;
    } else if (_isAudio(ext, mimeType)) {
      iconData = Icons.audio_file;
      iconColor = Colors.orange;
    } else if (_isDocument(ext, mimeType)) {
      iconData = Icons.description;
      iconColor = Colors.blue;
    } else if (_isArchive(ext, mimeType)) {
      iconData = Icons.folder_zip;
      iconColor = Colors.brown;
    } else if (_isCode(ext)) {
      iconData = Icons.code;
      iconColor = Colors.teal;
    } else {
      iconData = Icons.insert_drive_file;
      iconColor = Colors.grey;
    }

    return Icon(iconData, size: size, color: iconColor);
  }

  String _getExtension(String filename) {
    final parts = filename.split('.');
    return parts.length > 1 ? '.${parts.last}' : '';
  }

  bool _isImage(String ext, String? mimeType) {
    final imageExts = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg'];
    return imageExts.contains(ext) || (mimeType?.startsWith('image/') ?? false);
  }

  bool _isVideo(String ext, String? mimeType) {
    final videoExts = ['.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm'];
    return videoExts.contains(ext) || (mimeType?.startsWith('video/') ?? false);
  }

  bool _isAudio(String ext, String? mimeType) {
    final audioExts = ['.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a'];
    return audioExts.contains(ext) || (mimeType?.startsWith('audio/') ?? false);
  }

  bool _isDocument(String ext, String? mimeType) {
    final docExts = ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.md'];
    return docExts.contains(ext) || 
           (mimeType?.contains('pdf') ?? false) ||
           (mimeType?.contains('word') ?? false) ||
           (mimeType?.contains('excel') ?? false);
  }

  bool _isArchive(String ext, String? mimeType) {
    final archiveExts = ['.zip', '.rar', '.7z', '.tar', '.gz', '.bz2'];
    return archiveExts.contains(ext) || 
           (mimeType?.contains('zip') ?? false) ||
           (mimeType?.contains('compressed') ?? false);
  }

  bool _isCode(String ext) {
    final codeExts = ['.dart', '.js', '.ts', '.py', '.java', '.cpp', '.c', '.cs', 
                      '.html', '.css', '.json', '.xml', '.yaml', '.yml', '.sh'];
    return codeExts.contains(ext);
  }
}
