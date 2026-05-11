import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/disbox_file.dart';
import '../widgets/file_icon.dart';

/// A list tile widget for displaying a file or folder in the file browser.
class FileListTile extends StatelessWidget {
  final DisboxFile file;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const FileListTile({
    super.key,
    required this.file,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    try {
      return _buildTile(context);
    } catch (e, stackTrace) {
      print('[FileListTile ERROR] Build failed for ${file.name}: $e');
      print('[FileListTile ERROR] Stack: $stackTrace');
      return ListTile(
        leading: const Icon(Icons.error_outline, color: Colors.red),
        title: Text('Error loading: ${file.name}'),
        subtitle: Text('$e'),
      );
    }
  }

  Widget _buildTile(BuildContext context) {
    final result = ListTile(
      leading: FileIcon(file: file, size: 40),
      title: Text(
        file.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          Text(file.formattedSize),
          if (!file.isFolder) ...[
            const SizedBox(width: 8),
            Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(
                color: Colors.grey,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            if (file.chunkMessageIds.length > 1)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.layers, size: 12, color: Colors.blue[300]),
                  SizedBox(width: 4),
                  Text(
                    '${file.chunkMessageIds.length} parts',
                    style: TextStyle(fontSize: 12, color: Colors.blue[300]),
                  ),
                ],
              ),
          ],
        ],
      ),
      trailing: Text(
        _formatDate(file.modifiedAt),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
    
    return result;
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return DateFormat('HH:mm').format(date);
    } else if (difference.inDays < 7) {
      return DateFormat('EEEE').format(date); // Day of week
    } else {
      return DateFormat('MM/dd/yy').format(date);
    }
  }
}
