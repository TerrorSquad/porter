import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/transfer.dart';
import '../providers/scanner_provider.dart';
import '../providers/settings_provider.dart';
import '../services/file_handler.dart';
import '../utils/format.dart';
import '../utils/transfer_actions.dart';
import 'chunk_grid.dart';

class TransferCard extends StatefulWidget {
  final Transfer transfer;

  const TransferCard({super.key, required this.transfer});

  @override
  State<TransferCard> createState() => _TransferCardState();
}

class _TransferCardState extends State<TransferCard> {
  bool _saving = false;
  bool _showMissing = false;

  Future<void> _handleSave() async {
    setState(() => _saving = true);
    await saveTransfer(context, widget.transfer);
    if (mounted) setState(() => _saving = false);
  }

  void _handleOpen() {
    final path = widget.transfer.savedPath;
    if (path != null) {
      launchUrl(Uri.file(File(path).parent.path));
    }
  }

  void _handleOpenFolder() {
    final path = widget.transfer.transferDirPath;
    if (path != null) {
      launchUrl(Uri.file(path));
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

  Widget _buildRelayRow(BuildContext context, Transfer transfer) {
    final settings = context.watch<SettingsProvider>();
    if (settings.relayUrl.isEmpty) return const SizedBox.shrink();

    final provider = context.watch<ScannerProvider>();
    final state = provider.relayStates[transfer.id];

    String text;
    Color color;
    if (state == null) {
      text = '○ Relay: waiting for first chunk…';
      color = Colors.grey;
    } else if (state.lastError != null) {
      text = '✕ Relay: error — ${state.lastError}';
      color = Colors.red.shade400;
    } else if (state.joinedPath != null) {
      text = '✓ Relay: joined → ${state.joinedPath}';
      color = Colors.green.shade400;
    } else if (state.complete) {
      text = '✓ Relay: complete';
      color = Colors.green.shade400;
    } else {
      text = '⇡ Relay: ${state.sent} chunk${state.sent != 1 ? 's' : ''} saved';
      color = Colors.blue.shade300;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(text, style: TextStyle(color: color, fontSize: 12)),
    );
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
                if (transfer.encoding == 'fountain') ...[
                  const SizedBox(width: 8),
                  _badge('Fountain', Colors.purple.shade200),
                ],
                const SizedBox(width: 8),
                statusBadge,
                const SizedBox(width: 8),
                checksumBadge,
                const Spacer(),
                if (transfer.transferDirPath != null)
                  IconButton(
                    icon: const Icon(Icons.folder_open),
                    tooltip: 'Open download folder',
                    onPressed: _handleOpenFolder,
                  ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Remove',
                  onPressed: _handleRemove,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (transfer.total > 0) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Stack(
                  children: [
                    // Symbol collection behind, blocks in front — same
                    // two-layer reading as the scanning screen.
                    LinearProgressIndicator(
                      value: transfer.collectionProgress,
                      minHeight: 6,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation(
                        Colors.lightBlueAccent.shade200.withValues(alpha: 0.28),
                      ),
                    ),
                    LinearProgressIndicator(
                      value: transfer.displayProgress,
                      minHeight: 6,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation(
                        transfer.isComplete
                            ? Colors.greenAccent.shade400
                            : Colors.lightBlueAccent.shade200,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    transfer.progressLabel,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  if (!transfer.isComplete) ...[
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () => setState(() => _showMissing = !_showMissing),
                      child: Text(
                        _showMissing ? 'Hide missing ▲' : 'Show missing ▼',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: Colors.blue.shade300),
                      ),
                    ),
                  ],
                ],
              ),
              if (_showMissing && !transfer.isComplete) ...[
                const SizedBox(height: 4),
                ChunkGrid(total: transfer.total, seenIndices: transfer.seenIndices),
                const SizedBox(height: 4),
                Text(
                  transfer.encoding == 'fountain'
                      ? '${transfer.missingIndices.length} block'
                          '${transfer.missingIndices.length == 1 ? '' : 's'} '
                          'not yet recovered — keep scanning, any frames will do'
                      : 'Missing: ${formatChunkRanges(transfer.missingIndices)}',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Colors.white54),
                ),
              ],
            ] else
              Text(
                'Waiting for data chunks…',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            const SizedBox(height: 4),
            Text(
              transfer.assembled != null
                  ? 'Size: ${formatBytes(transfer.assembled!.length)} · '
                      'completed in ${formatDuration(transfer.completedAt!.difference(transfer.createdAt))}'
                  : 'Received: ${formatBytes(transfer.receivedBytes)} · '
                      '${formatDuration(DateTime.now().difference(transfer.createdAt))} elapsed',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Colors.white54),
            ),
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
            if (transfer.savedPath != null) ...[
              const SizedBox(height: 4),
              Text(
                'Saved to ${transfer.savedPath}',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: Colors.white54),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (transfer.savedPath != null) ...[
                  OutlinedButton.icon(
                    onPressed: _handleOpen,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open'),
                  ),
                  const SizedBox(width: 8),
                ],
                ElevatedButton.icon(
                  onPressed: transfer.isComplete && !_saving ? _handleSave : null,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(_saving ? 'Saving…' : (transfer.savedPath != null ? 'Save again' : 'Save')),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
