import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/scanner_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/scanning_screen.dart';

void main() {
  runApp(const PorterApp());
}

class PorterApp extends StatelessWidget {
  const PorterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ScannerProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        title: 'Porter Receiver',
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.dark(
            primary: Colors.green.shade400,
            secondary: Colors.green.shade600,
          ),
        ),
        home: const ScanningScreen(),
      ),
    );
  }
}
