import 'dart:async';

import 'package:flutter/foundation.dart';
import '../models/relay_state.dart';
import '../models/transfer.dart';
import '../services/assembler.dart';
import '../services/chunk_storage.dart';
import '../services/relay_service.dart';

class ScannerProvider extends ChangeNotifier {
  static const _rateWindow = Duration(seconds: 3);

  final Assembler assembler;
  Transfer? _activeTransfer;
  final List<DateTime> _recentScans = [];
  final List<(DateTime, int)> _recentBytes = [];

  int totalScanned = 0;
  int duplicatesSkipped = 0;
  String? lastError;

  final Map<String, RelayState> relayStates = {};
  bool? relayLastOk;

  /// Output directory to persist chunks/metadata to for the transfer
  /// currently being ingested. Set at the start of each [ingestQR] call.
  String? _currentOutputDirectory;

  /// Called when a transfer finishes assembling successfully (not on error).
  Function(Transfer)? onTransferComplete;

  ScannerProvider()
      : assembler = Assembler(
          onProgress: (t) {},
          onComplete: (t) {},
        ) {
    assembler.onProgress = _onProgress;
    assembler.onComplete = _onComplete;
    assembler.onChunkBytes = _onChunkBytes;
    assembler.onChunkReceived = _onChunkReceived;
  }

  Transfer? get activeTransfer => _activeTransfer;
  Map<String, Transfer> get allTransfers => assembler.transfers;

  /// QR codes processed per second, averaged over the last [_rateWindow].
  double get scansPerSecond {
    final now = DateTime.now();
    _recentScans.removeWhere((t) => now.difference(t) > _rateWindow);
    return _recentScans.length / _rateWindow.inSeconds;
  }

  /// Payload bytes received per second, averaged over the last [_rateWindow].
  double get bytesPerSecond {
    final now = DateTime.now();
    _recentBytes.removeWhere((e) => now.difference(e.$1) > _rateWindow);
    final total = _recentBytes.fold<int>(0, (sum, e) => sum + e.$2);
    return total / _rateWindow.inSeconds;
  }

  void _onChunkBytes(int bytes) {
    _recentBytes.add((DateTime.now(), bytes));
  }

  void ingestQR(String raw, {String? relayUrl, String? outputDirectory}) {
    _currentOutputDirectory = outputDirectory;

    final now = DateTime.now();
    _recentScans.add(now);
    _recentScans.removeWhere((t) => now.difference(t) > _rateWindow);

    final isNew = assembler.ingest(raw);
    if (isNew) {
      totalScanned++;
      notifyListeners();
    } else {
      duplicatesSkipped++;
    }

    if (relayUrl != null && relayUrl.isNotEmpty) {
      _relay(relayUrl, raw);
    }
  }

  void _relay(String relayUrl, String raw) {
    RelayService.upload(relayUrl, raw).then((result) {
      relayLastOk = result.error == null;

      final transferId = result.transferId;
      if (transferId != null) {
        final state = relayStates.putIfAbsent(transferId, () => RelayState());
        if (result.error != null) {
          state.failed++;
          state.lastError = result.error;
        } else {
          if (result.duplicate != true) state.sent++;
          state.complete = result.complete ?? state.complete;
          state.verified = result.verified ?? state.verified;
          state.joinedPath = result.joinedPath ?? state.joinedPath;
          state.lastError = null;
        }
      }

      notifyListeners();
    });
  }

  void _onProgress(Transfer t) {
    _activeTransfer = t;
    notifyListeners();
  }

  /// Persists a newly-received chunk to the transfer's directory on disk.
  void _onChunkReceived(Transfer t, int index, List<int> bytes) {
    final outputDirectory = _currentOutputDirectory;
    unawaited(
      ChunkStorage.writeChunk(t, index, bytes, outputDirectory: outputDirectory)
          .then((_) => notifyListeners())
          .catchError((Object e) => debugPrint('Failed to save chunk $index for ${t.id}: $e')),
    );
  }

  void _onComplete(Transfer t) {
    _activeTransfer = t;
    final outputDirectory = _currentOutputDirectory;
    if (t.error == null) {
      if (t.assembled != null) {
        unawaited(
          ChunkStorage.writeAssembledFile(t, outputDirectory: outputDirectory)
              .then((_) => ChunkStorage.writeMetadata(t, outputDirectory: outputDirectory))
              .then((_) => notifyListeners())
              .catchError((Object e) => debugPrint('Failed to save transfer ${t.id}: $e')),
        );
      }
      onTransferComplete?.call(t);
    } else {
      unawaited(
        ChunkStorage.writeMetadata(t, outputDirectory: outputDirectory)
            .catchError((Object e) => debugPrint('Failed to save metadata for ${t.id}: $e')),
      );
    }
    notifyListeners();
  }

  void resetAll() {
    assembler.reset();
    _activeTransfer = null;
    totalScanned = 0;
    duplicatesSkipped = 0;
    lastError = null;
    relayStates.clear();
    relayLastOk = null;
    _recentScans.clear();
    _recentBytes.clear();
    notifyListeners();
  }

  void reset(String id) {
    assembler.reset(id);
    if (_activeTransfer?.id == id) {
      _activeTransfer = null;
    }
    relayStates.remove(id);
    notifyListeners();
  }

  /// Records where [id]'s assembled data was saved, so the UI can offer to
  /// open that location later.
  void markTransferSaved(String id, String path) {
    final transfer = allTransfers[id];
    if (transfer != null) {
      transfer.savedPath = path;
      notifyListeners();
    }
  }
}
