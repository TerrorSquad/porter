import 'dart:async';

import 'package:flutter/foundation.dart';
import '../models/relay_state.dart';
import '../models/transfer.dart';
import '../services/assembler_worker.dart';
import '../services/relay_service.dart';

/// Suggests whether the sender's display interval has headroom to speed up
/// or is already outpacing what the receiver can reliably catch. See
/// [ScannerProvider.speedHint].
enum SpeedHint { increase, decrease }

class ScannerProvider extends ChangeNotifier {
  static const _rateWindow = Duration(seconds: 3);

  AssemblerWorker? _worker;
  final List<String> _pendingBeforeReady = [];

  Transfer? _activeTransfer;
  final Map<String, Transfer> _transfers = {};
  final List<DateTime> _recentScans = [];
  final List<(DateTime, int)> _recentBytes = [];

  /// Arrival times of recent *new* (non-duplicate) chunks only — the basis
  /// for [estimatedSenderIntervalMs]. Duplicate scans of an already-seen
  /// chunk say nothing about how fast the sender is advancing, so they're
  /// deliberately excluded (unlike [_recentScans], which counts everything).
  final List<DateTime> _recentNewChunks = [];
  static const _senderIntervalSampleSize = 8;

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

  /// Estimated time between the sender's QR frame changes, in milliseconds —
  /// the median gap between recent *new*-chunk arrivals, distinct from
  /// [scansPerSecond] (which is the receiver's raw decode-attempt rate,
  /// duplicates included and dominated by how many times each displayed
  /// frame gets re-decoded before the sender advances). Null until enough
  /// distinct chunks have arrived to estimate from, or if the last sample is
  /// stale (sender stalled/finished/gap-filling out of order).
  ///
  /// ponytail: a plain median over the last few gaps, not a real clock-sync
  /// or outlier-robust estimator — good enough to eyeball "sender could
  /// probably go faster/slower", not precise pacing telemetry. Revisit if
  /// gap-filling/out-of-order scanning makes this noisy in practice.
  int? get estimatedSenderIntervalMs {
    if (_recentNewChunks.length < 3) return null;
    final last = _recentNewChunks.last;
    if (DateTime.now().difference(last) > const Duration(seconds: 3)) return null;

    final gaps = <int>[];
    for (var i = 1; i < _recentNewChunks.length; i++) {
      gaps.add(_recentNewChunks[i].difference(_recentNewChunks[i - 1]).inMilliseconds);
    }
    gaps.sort();
    return gaps[gaps.length ~/ 2];
  }

  /// A hint for whether the sender's display interval has room to speed up
  /// or should slow down, based on how many decode *attempts* the receiver
  /// spends per displayed frame (attempts-in-window ÷ new-chunks-in-window).
  /// Null when there isn't enough recent signal to say anything ([lastError]
  /// on `estimatedSenderIntervalMs` applies here too).
  ///
  /// ponytail: fixed thresholds picked from one real session's numbers (1080p
  /// Brio, ~67% decode success, ~2-3 attempts/frame felt comfortable) — not
  /// tuned per-device/lighting. Good enough as a nudge, not a guarantee; the
  /// user can always just watch for missing chunks instead.
  SpeedHint? get speedHint {
    final intervalMs = estimatedSenderIntervalMs;
    if (intervalMs == null) return null;

    final now = DateTime.now();
    final attemptsInWindow =
        _recentScans.where((t) => now.difference(t) <= _rateWindow).length;
    final newChunksInWindow =
        _recentNewChunks.where((t) => now.difference(t) <= _rateWindow).length;
    if (newChunksInWindow == 0) return null;

    final attemptsPerFrame = attemptsInWindow / newChunksInWindow;
    if (attemptsPerFrame >= 4) return SpeedHint.increase;
    if (attemptsPerFrame <= 1.5) return SpeedHint.decrease;
    return null;
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
          _recentNewChunks.add(DateTime.now());
          if (_recentNewChunks.length > _senderIntervalSampleSize) {
            _recentNewChunks.removeAt(0);
          }
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
    _recentNewChunks.clear();
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
    _currentOutputDirectory = outputDirectory;
    _worker?.hydrateFromDisk(outputDirectory);
  }

  @override
  void dispose() {
    unawaited(_worker?.dispose());
    super.dispose();
  }
}
