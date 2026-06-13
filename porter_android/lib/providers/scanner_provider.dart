import 'package:flutter/foundation.dart';
import '../models/relay_state.dart';
import '../models/transfer.dart';
import '../services/assembler.dart';
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

  ScannerProvider()
      : assembler = Assembler(
          onProgress: (t) {},
          onComplete: (t) {},
        ) {
    assembler.onProgress = _onProgress;
    assembler.onComplete = _onComplete;
    assembler.onChunkBytes = _onChunkBytes;
  }

  Transfer? get activeTransfer => _activeTransfer;
  Map<String, Transfer> get allTransfers => assembler.transfers;

  /// QR codes processed per second, averaged over the last [_rateWindow].
  double get scansPerSecond =>
      _recentScans.length / _rateWindow.inSeconds;

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

  void ingestQR(String raw, {String? relayUrl}) {
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

  void _onComplete(Transfer t) {
    _activeTransfer = t;
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
}
