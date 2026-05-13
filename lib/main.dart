import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/import_screen.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize notification service
  final notificationService = NotificationService();
  try {
    await notificationService.initialize();
    debugPrint('[Main] Notification service initialized');
  } catch (e, stackTrace) {
    debugPrint('[Main ERROR] Failed to initialize notification service: $e');
    debugPrint('[Main ERROR] Stack trace: $stackTrace');
  }
  
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: notificationService),
      ],
      child: const DisboxApp(),
    ),
  );
}

/// Main Disbox application widget.
class DisboxApp extends StatelessWidget {
  const DisboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Disbox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
      themeMode: ThemeMode.system, // Follow system theme
      home: const ImportScreen(),
    );
  }
}
