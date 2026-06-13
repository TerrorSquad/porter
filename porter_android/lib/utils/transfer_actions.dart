import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/transfer.dart';
import '../providers/settings_provider.dart';
import '../services/file_handler.dart';

/// Saves [transfer] to the configured output directory and shows a
/// confirmation (with an action to reveal the file) or error snackbar.
Future<void> saveTransfer(BuildContext context, Transfer transfer) async {
  final outputDirectory = context.read<SettingsProvider>().outputDirectory;
  try {
    final path = await FileHandler.saveFile(transfer, outputDirectory: outputDirectory);
    if (context.mounted) {
      final messenger = ScaffoldMessenger.of(context);
      // Clear any earlier "transfer complete" snackbar so this confirmation
      // (and its Open action) is visible immediately, not queued behind it.
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Saved to $path'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => launchUrl(Uri.file(File(path).parent.path)),
          ),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }
}
