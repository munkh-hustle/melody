import 'package:flutter/material.dart';
import '../services/disbox_service.dart';
import 'file_browser_screen.dart';

class ManualSetupScreen extends StatefulWidget {
  const ManualSetupScreen({super.key});

  @override
  State<ManualSetupScreen> createState() => _ManualSetupScreenState();
}

class _ManualSetupScreenState extends State<ManualSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _webhookController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _webhookController.dispose();
    super.dispose();
  }

  Future<void> _saveConfig() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final webhookUrl = _webhookController.text.trim();
      final service = DisboxService();
      
      // Save webhook URL directly
      await service.setWebhookUrl(webhookUrl);
      
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const FileBrowserScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        _showErrorDialog('Failed to save config: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
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
        title: const Text('Manual Setup'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              const Icon(
                Icons.edit,
                size: 64,
                color: Colors.blue,
              ),
              const SizedBox(height: 24),
              const Text(
                'Enter Webhook URL',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Paste your Discord Webhook URL below to configure Disbox.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 32),
              TextFormField(
                controller: _webhookController,
                decoration: const InputDecoration(
                  labelText: 'Webhook URL',
                  hintText: 'https://discord.com/api/webhooks/...',
                  prefixIcon: Icon(Icons.link),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a webhook URL';
                  }
                  if (!value.trim().startsWith('https://discord.com/api/webhooks/')) {
                    return 'Invalid Discord webhook URL';
                  }
                  return null;
                },
                maxLines: 3,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _saveConfig,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save Configuration'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
