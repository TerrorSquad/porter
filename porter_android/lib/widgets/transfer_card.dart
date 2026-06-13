import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transfer.dart';
import '../providers/scanner_provider.dart';
import '../providers/settings_provider.dart';
import '../services/file_handler.dart';
import '../utils/format.dart';

class TransferCard extends StatefulWidget {
  final Transfer transfer;

  const TransferCard({super.key, required this.transfer});

  @override
  State<TransferCard> createState() => _TransferCardState();
}

class _TransferCardState extends State<TransferCard> {
  bool _saving = false;

  Future<void> _handleSave() async {
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

  void _handleRemove() {
    context.read<ScannerProvider>().reset(widget.transfer.id);
  }

  String _modeLabel(String mode) {
    switch (mode) {
      case 'T':
        return 'Text';
      case 'B':
        return 'Binary';
      case 'C':
        return 'Compressed';
      default:
        return mode;
    }
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget? _buildPreview(Transfer transfer) {
    final assembled = transfer.assembled;
    if (assembled == null) return null;

    if (transfer.mode == 'T') {
      final text = utf8.decode(assembled, allowMalformed: true);
      final shown = text.length > 600 ? '${text.substring(0, 600)}\n…' : text;
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          shown,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      );
    }

    final ext = FileHandler.guessExtension(transfer);
    if (ext == '.png' || ext == '.jpg') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(
          Uint8List.fromList(assembled),
          height: 160,
          fit: BoxFit.contain,
        ),
      );
    }

    return null;
  }

  // Filled in once HTTP relay (porter serve) support is wired up.
  Widget _buildRelayRow(BuildContext context, Transfer transfer) {
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final transfer = widget.transfer;

    final Widget statusBadge;
    if (transfer.error != null) {
      statusBadge = _badge('Error', Colors.red.shade400);
    } else if (transfer.isComplete) {
      statusBadge = _badge('Complete', Colors.green.shade400);
    } else {
      statusBadge = _badge('Scanning…', Colors.orange.shade300);
    }

    final Widget checksumBadge;
    if (transfer.verified == true) {
      checksumBadge = _badge('✓ Verified', Colors.green.shade400);
    } else if (transfer.verified == false) {
      checksumBadge = _badge('✗ Failed', Colors.red.shade400);
    } else {
      checksumBadge = _badge('— Unverified', Colors.grey);
    }

    final preview = _buildPreview(transfer);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  transfer.id.length > 8 ? transfer.id.substring(0, 8) : transfer.id,
                  style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                _badge(_modeLabel(transfer.mode), Colors.blueGrey.shade200),
                const SizedBox(width: 8),
                statusBadge,
                const SizedBox(width: 8),
                checksumBadge,
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Remove',
                  onPressed: _handleRemove,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (transfer.total > 0) ...[
              LinearProgressIndicator(value: transfer.progress / 100),
              const SizedBox(height: 4),
              Text(
                '${transfer.seenIndices.length} / ${transfer.total} chunks',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ] else
              Text(
                'Waiting for data chunks…',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            if (transfer.assembled != null) ...[
              const SizedBox(height: 8),
              Text(
                'Size: ${formatBytes(transfer.assembled!.length)}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
            if (preview != null) ...[
              const SizedBox(height: 8),
              preview,
            ],
            if (transfer.error != null) ...[
              const SizedBox(height: 8),
              Text(
                transfer.error!,
                style: TextStyle(color: Colors.red.shade400),
              ),
            ],
            _buildRelayRow(context, transfer),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: transfer.isComplete && !_saving ? _handleSave : null,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: Text(_saving ? 'Saving…' : 'Save'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
