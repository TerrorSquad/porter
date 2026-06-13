import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/transfer.dart';
import '../providers/scanner_provider.dart';
import '../providers/settings_provider.dart';
import '../services/file_handler.dart';

class ResultScreen extends StatefulWidget {
  final Transfer transfer;

  const ResultScreen({Key? key, required this.transfer}) : super(key: key);

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  bool _saving = false;

  void _handleSave() async {
    setState(() => _saving = true);
    try {
      final outputDirectory = context.read<SettingsProvider>().outputDirectory;
      final path = await FileHandler.saveFile(
        widget.transfer,
        outputDirectory: outputDirectory,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to $path')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _handleScanAgain() {
    context.read<ScannerProvider>().resetAll();
    Navigator.of(context).pop();
  }

  String _getPreview() {
    final assembled = widget.transfer.assembled;
    if (assembled == null) return '(No data)';

    if (widget.transfer.mode == 'T') {
      final text = utf8.decode(assembled);
      return text.length > 600 ? text.substring(0, 600) + '\n…' : text;
    }

    return '(Binary data: ${assembled.length} bytes)';
  }

  @override
  Widget build(BuildContext context) {
    final assembled = widget.transfer.assembled;
    final sizeKB = (assembled?.length ?? 0) / 1024;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfer Complete'),
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Received Data', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade900,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          _getPreview(),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Size: ${sizeKB.toStringAsFixed(2)} KB',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text(
                      'Mode: ${widget.transfer.mode}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    if (widget.transfer.verified == true)
                      Text(
                        '✓ SHA-256 verified',
                        style: TextStyle(color: Colors.green.shade400),
                      ),
                    if (widget.transfer.error != null)
                      Text(
                        '✗ ${widget.transfer.error}',
                        style: TextStyle(color: Colors.red.shade400),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _saving ? null : _handleSave,
              icon: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download),
              label: Text(_saving ? 'Saving...' : 'Save File'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                backgroundColor: Colors.green.shade700,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _handleScanAgain,
              icon: const Icon(Icons.refresh),
              label: const Text('Scan Again'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
