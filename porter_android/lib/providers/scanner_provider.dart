import 'package:flutter/foundation.dart';
import '../models/transfer.dart';
import '../services/assembler.dart';

class ScannerProvider extends ChangeNotifier {
  final Assembler assembler;
  Transfer? _activeTransfer;

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

  void ingestQR(String raw) {
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
