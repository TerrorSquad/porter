import 'dart:async';

import '../models/transfer.dart';
import 'chunk_storage.dart';

/// Debounces metadata.json writes for one transfer: coalesces bursts of
/// chunk arrivals into at most one write per [interval], plus an immediate
/// [flush] on completion/error/pause so the on-disk copy is never stale by
/// more than [interval] except across a hard kill.
class ChunkMetadataWriter {
  static const defaultInterval = Duration(seconds: 5);

  final Transfer transfer;
  final String? outputDirectory;
  final Duration interval;

  Timer? _timer;
  bool _dirty = false;

  ChunkMetadataWriter(
    this.transfer, {
    this.outputDirectory,
    this.interval = defaultInterval,
  });

  /// Marks metadata as needing a write and schedules one if none is already
  /// pending. Does not write synchronously.
  void markDirty() {
    _dirty = true;
    _timer ??= Timer(interval, _onTimer);
  }

  /// Writes immediately, cancelling any pending debounce timer.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    _dirty = false;
    await ChunkStorage.writeMetadata(transfer, outputDirectory: outputDirectory);
  }

  void _onTimer() {
    _timer = null;
    if (!_dirty) return;
    _dirty = false;
    unawaited(ChunkStorage.writeMetadata(transfer, outputDirectory: outputDirectory));
  }

  /// Cancels any pending timer without writing. Call when a transfer is
  /// reset/discarded so its writer doesn't fire afterward.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
