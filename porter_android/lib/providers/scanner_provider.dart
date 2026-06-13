import 'package:flutter/foundation.dart';
import '../models/transfer.dart';
import '../services/assembler.dart';

class ScannerProvider extends ChangeNotifier {
  static const _rateWindow = Duration(seconds: 3);

  final Assembler assembler;
  Transfer? _activeTransfer;
  final List<DateTime> _recentScans = [];

  int totalScanned = 0;
  int duplicatesSkipped = 0;
  String? lastError;

  ScannerProvider()
      : assembler = Assembler(
          onProgress: (t) {},
          onComplete: (t) {},
        ) {
    assembler.onProgress = _onProgress;
    assembler.onComplete = _onComplete;
  }

  Transfer? get activeTransfer => _activeTransfer;
  Map<String, Transfer> get allTransfers => assembler.transfers;

  /// QR codes processed per second, averaged over the last [_rateWindow].
  double get scansPerSecond =>
      _recentScans.length / _rateWindow.inSeconds;

  void ingestQR(String raw) {
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
    notifyListeners();
  }

  void reset(String id) {
    assembler.reset(id);
    if (_activeTransfer?.id == id) {
      _activeTransfer = null;
    }
    notifyListeners();
  }
}
