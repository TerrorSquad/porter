import 'dart:async';

import 'package:flutter/foundation.dart';
import '../models/relay_state.dart';
import '../models/transfer.dart';
import '../services/assembler_worker.dart';
import '../services/relay_service.dart';

class ScannerProvider extends ChangeNotifier {
  static const _rateWindow = Duration(seconds: 3);

  AssemblerWorker? _worker;
  final List<String> _pendingBeforeReady = [];

  Transfer? _activeTransfer;
  final Map<String, Transfer> _transfers = {};
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

  late final Future<void> ready;

  ScannerProvider() {
    ready = _init();
  }

  Future<void> _init() async {
    final worker = await AssemblerWorker.spawn(_onWorkerEvent);
    _worker = worker;
    for (final raw in _pendingBeforeReady) {
      worker.ingestQR(raw);
    }
    _pendingBeforeReady.clear();
  }

  Transfer? get activeTransfer => _activeTransfer;
  Map<String, Transfer> get allTransfers => _transfers;

  Transfer _transferFor(String id) => _transfers.putIfAbsent(id, () => Transfer(id: id));

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

  void ingestQR(String raw, {String? relayUrl, String? outputDirectory}) {
    if (outputDirectory != _currentOutputDirectory) {
      _currentOutputDirectory = outputDirectory;
      _worker?.setOutputDirectory(outputDirectory);
    }

    final now = DateTime.now();
    _recentScans.add(now);
    _recentScans.removeWhere((t) => now.difference(t) > _rateWindow);

    final worker = _worker;
    if (worker == null) {
      _pendingBeforeReady.add(raw);
    } else {
      worker.ingestQR(raw);
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

  /// Test-only seam: applies a [WorkerEvent] as if it arrived from the
  /// worker isolate, without requiring a real isolate spawn. Widget tests use
  /// this to drive UI state deterministically — spawning/tearing down a real
  /// isolate inside the `flutter_tester` headless test shell is unreliable.
  @visibleForTesting
  void applyWorkerEvent(WorkerEvent event) => _onWorkerEvent(event);

  void _onWorkerEvent(WorkerEvent event) {
    switch (event) {
      case ScanCountedEvent(:final isNew):
        if (isNew) {
          totalScanned++;
        } else {
          duplicatesSkipped++;
        }
        notifyListeners();
      case ProgressSnapshotEvent(:final snapshot, :final fromHydration):
        // A hydrated-from-disk transfer populates allTransfers (so it shows
        // up in the transfers list) but shouldn't jump to the foreground as
        // the scan screen's headline transfer before the user scans anything
        // this session.
        _transferFor(snapshot.id).applySnapshot(snapshot);
        if (!fromHydration) _activeTransfer = _transfers[snapshot.id];
        notifyListeners();
      case ChunkBytesEvent(:final bytes):
        _recentBytes.add((DateTime.now(), bytes));
      case TransferCompletedEvent(:final snapshot, :final assembled):
        final t = _transferFor(snapshot.id)..applySnapshot(snapshot);
        t.assembled = assembled;
        _activeTransfer = t;
        if (t.error == null) {
          onTransferComplete?.call(t);
        }
        notifyListeners();
      case PersistErrorEvent(:final message):
        debugPrint(message);
    }
  }

  void resetAll() {
    _worker?.reset();
    _transfers.clear();
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
    _worker?.reset(id);
    _transfers.remove(id);
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

  /// Flushes every transfer's debounced metadata write immediately — call
  /// when the app is about to background or be killed.
  void flushAll() => _worker?.flushAll();

  /// Rebuilds any incomplete transfers found under [outputDirectory] from
  /// their previously-persisted chunks, so they appear in [allTransfers]
  /// without re-scanning. Call once at startup after [ready] resolves and the
  /// output directory is known (see [SettingsProvider.ready]).
  Future<void> hydrateFromDisk(String? outputDirectory) async {
    await ready;
    _worker?.hydrateFromDisk(outputDirectory);
  }

  @override
  void dispose() {
    unawaited(_worker?.dispose());
    super.dispose();
  }
}
