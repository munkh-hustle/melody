import 'package:flutter/material.dart';

/// A dialog that shows upload/download progress.
class ProgressDialog extends StatefulWidget {
  final String title;
  final String message;
  final double? initialProgress; // null for indeterminate
  final Stream<double>? progressStream; // Stream of progress updates (0.0-1.0)

  const ProgressDialog({
    super.key,
    required this.title,
    required this.message,
    this.initialProgress,
    this.progressStream,
  });

  @override
  State<ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<ProgressDialog> {
  double? _currentProgress;

  @override
  void initState() {
    super.initState();
    _currentProgress = widget.initialProgress;
    
    // Listen to progress stream if provided
    if (widget.progressStream != null) {
      widget.progressStream!.listen((progress) {
        if (mounted) {
          setState(() {
            _currentProgress = progress;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.message),
          const SizedBox(height: 16),
          _currentProgress != null
              ? Column(
                  children: [
                    LinearProgressIndicator(value: _currentProgress),
                    const SizedBox(height: 8),
                    Text('${(_currentProgress! * 100).toInt()}%'),
                  ],
                )
              : const CircularProgressIndicator(),
        ],
      ),
    );
  }
}
