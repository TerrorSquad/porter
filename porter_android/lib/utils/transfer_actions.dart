import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transfer.dart';
import '../providers/settings_provider.dart';
import '../services/file_handler.dart';

/// Saves [transfer] to the configured output directory and shows a
/// confirmation or error snackbar.
Future<void> saveTransfer(BuildContext context, Transfer transfer) async {
  final outputDirectory = context.read<SettingsProvider>().outputDirectory;
  try {
    final path = await FileHandler.saveFile(transfer, outputDirectory: outputDirectory);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to $path')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }
}
