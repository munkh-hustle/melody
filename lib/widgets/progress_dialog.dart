import 'package:flutter/material.dart';

/// A dialog that shows upload/download progress with stop/resume controls.
class ProgressDialog extends StatefulWidget {
  final String title;
  final String message;
  final double? initialProgress; // null for indeterminate
  final Stream<double>? progressStream; // Stream of progress updates (0.0-1.0)
  final VoidCallback? onStop; // Callback when stop button is pressed
  final VoidCallback? onResume; // Callback when resume button is pressed
  final bool isPaused; // Whether the transfer is currently paused
  final bool allowResume; // Whether resume is available (for future implementation)

  const ProgressDialog({
    super.key,
    required this.title,
    required this.message,
    this.initialProgress,
    this.progressStream,
    this.onStop,
    this.onResume,
    this.isPaused = false,
    this.allowResume = false,
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
          const SizedBox(height: 24),
          // Stop/Resume buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (!widget.isPaused && widget.onStop != null)
                ElevatedButton.icon(
                  onPressed: () {
                    widget.onStop!();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
              if (widget.isPaused && widget.onResume != null && widget.allowResume)
                ElevatedButton.icon(
                  onPressed: () {
                    widget.onResume!();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
              if (!widget.isPaused && widget.onStop != null && !widget.allowResume)
                // Spacer to center the stop button when resume is not available
                const SizedBox(width: 100),
            ],
          ),
        ],
      ),
    );
  }
}
