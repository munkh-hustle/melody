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
  List<Map<String, String>> _savedAccounts = [];
  
  @override
  void initState() {
    super.initState();
    _loadSavedAccounts();
  }
  
  Future<void> _loadSavedAccounts() async {
    final service = DisboxService();
    final accounts = await service.getSavedAccounts();
    if (mounted) {
      setState(() {
        _savedAccounts = accounts;
      });
    }
  }
  
  Future<void> _loadAccount(String accountId) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });
    
    try {
      final service = DisboxService();
      final success = await service.loadSavedAccount(accountId);
      
      if (success && mounted) {
        // Navigate to main screen
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const FileBrowserScreen()),
        );
      } else if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load saved account.';
        });
      }
    } catch (e) {
      print('[LOAD ACCOUNT ERROR] Exception: $e');
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
  
  Future<void> _removeAccount(String accountId, String label) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Account'),
        content: Text('Are you sure you want to remove "$label" from the saved accounts list? This will not delete any data from Discord.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    
    if (confirmed == true && mounted) {
      final service = DisboxService();
      await service.removeSavedAccount(accountId);
      await _loadSavedAccounts();
    }
  }

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
          // Reload saved accounts in case of partial success
          await _loadSavedAccounts();
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
          // Reload saved accounts to show newly added webhook
          await _loadSavedAccounts();
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
          // Reload saved accounts to show newly added webhook
          await _loadSavedAccounts();
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
              const Text('2. Copy the metadata message(s) that look like:'),
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
              const Text('3. Paste into the text box on the "Metadata" tab'),
              const SizedBox(height: 8),
              const Text('4. Tap "Import Metadata"'),
              const SizedBox(height: 16),
              const Text('💡 Tip for Large Files:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('For large files (>200 chunks), metadata may be split across multiple messages.', 
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 4),
              const Text('• Copy ALL batch messages for each file', 
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 4),
              const Text('• Paste them all at once (each on a new line)', 
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 4),
              const Text('• The app will automatically merge them', 
                style: TextStyle(fontSize: 12),
              ),
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
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Back',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          children: [
            // Header section (fixed)
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
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
                ],
              ),
            ),
            // Saved accounts or buttons section (scrollable if needed)
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    // Saved accounts section
                    if (_savedAccounts.isNotEmpty) ...[
                      const Divider(),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Row(
                          children: [
                            Icon(Icons.history, size: 20, color: Colors.grey[600]),
                            const SizedBox(width: 8),
                            Text(
                              'Previously Loaded Accounts',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[700],
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 200,
                        child: ListView.builder(
                          itemCount: _savedAccounts.length,
                          itemBuilder: (context, index) {
                            final account = _savedAccounts[index];
                            final label = account['label'] ?? 'Unknown';
                            final accountId = account['account_id']!;
                            
                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                                  child: Icon(Icons.cloud, color: Theme.of(context).primaryColor),
                                ),
                                title: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
                                subtitle: Text('Tap to load this account', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.grey),
                                  onPressed: () => _removeAccount(accountId, label),
                                  tooltip: 'Remove from list',
                                ),
                                onTap: () => _loadAccount(accountId),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
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
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        );
      },
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
            hintText: 'Paste [DISBOX] metadata here...\n\nExample:\n[DISBOX] {"type":"disbox_metadata","version":"1.0","name":"file.mp4",...}\n\n💡 For large files: paste ALL batch messages (each on a new line)',
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
