import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_browser_screen.dart';

/// Setup screen for entering Discord webhook URL.
/// 
/// This is the first screen shown when the app is launched for the first time
/// or when no webhook URL is configured.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _webhookController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _webhookController.dispose();
    super.dispose();
  }

  /// Validate and save the webhook URL
  Future<void> _saveWebhookUrl() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final url = _webhookController.text.trim();
      
      // Basic validation
      if (!url.startsWith('https://discord.com/api/webhooks/')) {
        throw FormatException(
          'Invalid Discord webhook URL. It should start with '
          'https://discord.com/api/webhooks/',
        );
      }

      // Extract webhook ID and token to validate format
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      final webhookIndex = segments.indexOf('webhooks');
      
      if (webhookIndex == -1 || webhookIndex + 2 >= segments.length) {
        throw FormatException('Could not extract webhook ID and token from URL');
      }

      // Save to SharedPreferences (in production, use flutter_secure_storage)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('webhook_url', url);
      
      // Generate account ID (hash of webhook URL)
      // This would normally be done in the service layer
      final accountId = url.hashCode.toString();
      await prefs.setString('account_id', accountId);

      if (mounted) {
        // Navigate to main app
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const FileBrowserScreen()),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Show help dialog about creating a webhook
  void _showHelp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('How to Create a Webhook'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('1. Open Discord and go to your server'),
              const SizedBox(height: 8),
              const Text('2. Select a text channel where files will be stored'),
              const SizedBox(height: 8),
              const Text('3. Tap the gear icon (Edit Channel)'),
              const SizedBox(height: 8),
              const Text('4. Go to "Integrations" → "Webhooks"'),
              const SizedBox(height: 8),
              const Text('5. Tap "New Webhook"'),
              const SizedBox(height: 8),
              const Text('6. Give it a name (e.g., "Disbox Storage")'),
              const SizedBox(height: 8),
              const Text('7. Tap "Copy Webhook URL"'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.warning_amber, color: Colors.amber[700], size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Important Security Note:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.amber[900],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your webhook URL is like a password. Never share it with anyone! '
                      'This app stores it locally on your device only.',
                      style: TextStyle(color: Colors.amber[900]),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it!'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Setup Disbox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: _showHelp,
            tooltip: 'Help',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              
              // App logo/icon
              Icon(
                Icons.cloud_upload_outlined,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
              
              const SizedBox(height: 24),
              
              // Title
              Text(
                'Welcome to Disbox',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 8),
              
              // Subtitle
              Text(
                'Free cloud storage powered by Discord',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 48),
              
              // Description
              Text(
                'Enter your Discord webhook URL to get started. '
                'This creates a private storage space in your Discord channel.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 32),
              
              // Webhook URL input form
              Form(
                key: _formKey,
                child: TextFormField(
                  controller: _webhookController,
                  decoration: InputDecoration(
                    labelText: 'Discord Webhook URL',
                    hintText: 'https://discord.com/api/webhooks/...',
                    prefixIcon: const Icon(Icons.link),
                    border: const OutlineInputBorder(),
                    errorText: _errorMessage,
                  ),
                  keyboardType: TextInputType.url,
                  autofillHints: const [AutofillHints.url],
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter your webhook URL';
                    }
                    if (!value.trim().startsWith('https://discord.com/api/webhooks/')) {
                      return 'Invalid Discord webhook URL format';
                    }
                    return null;
                  },
                  onFieldSubmitted: (_) => _saveWebhookUrl(),
                ),
              ),
              
              const Spacer(),
              
              // Continue button
              ElevatedButton(
                onPressed: _isLoading ? null : _saveWebhookUrl,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text(
                        'Continue',
                        style: TextStyle(fontSize: 16),
                      ),
              ),
              
              const SizedBox(height: 16),
              
              // Privacy note
              Text(
                'Your webhook URL is stored locally and never sent to third parties.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
