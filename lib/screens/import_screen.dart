import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/disbox_service.dart';
import '../models/disbox_file.dart';
import 'file_browser_screen.dart';
import 'manual_setup_screen.dart';

/// Screen for importing webhook configuration from a JSON file or Discord metadata.
/// 
/// This screen allows users to:
/// 1. Select a JSON config file containing their Discord webhook URL
/// 2. Paste Discord metadata text from uploaded files to import them
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  String? _successMessage;
  final TextEditingController _metadataController = TextEditingController();
  bool _isMetadataTab = false;

  Future<void> _pickAndImportFile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      // Pick JSON file
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        
        // Import config using DisboxService
        final service = DisboxService();
        final success = await service.importConfig(file);

        if (success && mounted) {
          // Navigate to main screen
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const FileBrowserScreen()),
          );
        } else if (mounted) {
          setState(() {
            _errorMessage = 'Failed to import config. Please check the JSON file format.';
          });
        }
      } else if (mounted) {
        setState(() {
          _errorMessage = 'No file selected';
        });
      }
    } catch (e) {
      print('[IMPORT ERROR] Exception: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Error: ${e.toString()}';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _importMetadataFromText() async {
    final text = _metadataController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _errorMessage = 'Please paste metadata text';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final service = DisboxService();
      
      // Check if multiple lines (multiple metadata entries)
      final lines = text.split('\n')
          .where((line) => line.trim().isNotEmpty && line.trim().startsWith('[DISBOX]'))
          .toList();
      
      int importedCount = 0;
      if (lines.length > 1) {
        // Multiple entries
        importedCount = await service.importMultipleMetadataFromText(lines);
        if (importedCount > 0 && mounted) {
          setState(() {
            _successMessage = 'Successfully imported $importedCount file(s)!';
            _metadataController.clear();
          });
        } else if (mounted) {
          setState(() {
            _errorMessage = 'Failed to import any files. Check the format.';
          });
        }
      } else {
        // Single entry
        final result = await service.importMetadataFromText(text);
        if (result != null && mounted) {
          setState(() {
            _successMessage = 'Successfully imported: ${result.name}';
            _metadataController.clear();
          });
        } else if (mounted) {
          setState(() {
            _errorMessage = 'Failed to import metadata. Check the format.';
          });
        }
      }
    } catch (e) {
      print('[METADATA IMPORT ERROR] Exception: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Error: ${e.toString()}';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _metadataController.dispose();
    super.dispose();
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('How to Import'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Option 1: Import from JSON file', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('1. Export your config from another device or create a JSON file with:'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '{\\n  "webhook_url": "https://discord.com/api/webhooks/..."\\n}',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Option 2: Import from Discord metadata', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('1. Go to your Discord channel where files were uploaded'),
              const SizedBox(height: 8),
              const Text('2. Copy the metadata message that looks like:'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '[DISBOX] {"type":"disbox_metadata","version":"1.0",...}',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
              const SizedBox(height: 8),
              const Text('3. Paste it into the text box on the "Metadata" tab'),
              const SizedBox(height: 8),
              const Text('4. Tap "Import Metadata"'),
              const SizedBox(height: 16),
              const Text('Note: Metadata import adds files without deleting existing data.',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Configuration'),
        leading: IconButton(
          icon: const Icon(Icons.help_outline),
          onPressed: _showHelpDialog,
          tooltip: 'First time? Get help here',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showHelpDialog,
            tooltip: 'Help',
          ),
        ],
      ),
      body: Column(
        children: [
          // Tab bar for switching between JSON file and metadata import
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _isMetadataTab = false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: !_isMetadataTab ? Theme.of(context).primaryColor : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: const Text(
                        'JSON File',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _isMetadataTab = true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _isMetadataTab ? Theme.of(context).primaryColor : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: const Text(
                        'Discord Metadata',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Content area
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: _isMetadataTab ? _buildMetadataTab() : _buildJsonFileTab(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJsonFileTab(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.description_outlined,
          size: 80,
          color: Theme.of(context).primaryColor,
        ),
        const SizedBox(height: 24),
        const Text(
          'Import from JSON File',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Select a JSON file containing your Discord webhook URL to get started.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 40),
        if (_errorMessage != null && !_isMetadataTab) ...[
          _buildErrorMessage(),
        ],
        if (_successMessage != null && !_isMetadataTab) ...[
          _buildSuccessMessage(),
        ],
        ElevatedButton.icon(
          onPressed: _isLoading ? null : _pickAndImportFile,
          icon: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.folder_open),
          label: Text(_isLoading ? 'Importing...' : 'Select JSON File'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            textStyle: const TextStyle(fontSize: 16),
          ),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ManualSetupScreen()),
            );
          },
          icon: const Icon(Icons.edit),
          label: const Text('Manual Setup (First Time Users)'),
        ),
      ],
    );
  }

  Widget _buildMetadataTab() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.message_outlined,
          size: 80,
          color: Theme.of(context).primaryColor,
        ),
        const SizedBox(height: 24),
        const Text(
          'Import from Discord Metadata',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Paste metadata text from Discord messages to import files without replacing existing data.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 24),
        if (_errorMessage != null && _isMetadataTab) ...[
          _buildErrorMessage(),
        ],
        if (_successMessage != null && _isMetadataTab) ...[
          _buildSuccessMessage(),
        ],
        TextField(
          controller: _metadataController,
          maxLines: 8,
          minLines: 4,
          decoration: const InputDecoration(
            hintText: 'Paste [DISBOX] metadata here...\n\nExample:\n[DISBOX] {"type":"disbox_metadata","version":"1.0","name":"file.mp4",...}',
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.all(12),
          ),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _isLoading ? null : _importMetadataFromText,
          icon: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_upload),
          label: Text(_isLoading ? 'Importing...' : 'Import Metadata'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            textStyle: const TextStyle(fontSize: 16),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Tip: You can paste multiple metadata lines at once',
          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
        ),
      ],
    );
  }

  Widget _buildErrorMessage() {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red[200]!),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red[700]),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red[700]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessMessage() {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.green[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green[200]!),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, color: Colors.green[700]),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _successMessage!,
              style: TextStyle(color: Colors.green[700]),
            ),
          ),
        ],
      ),
    );
  }
}
