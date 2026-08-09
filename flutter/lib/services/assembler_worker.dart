import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../models/progress_snapshot.dart';
import '../models/transfer.dart';
import 'assembler.dart';
import 'chunk_metadata_writer.dart';
import 'chunk_storage.dart';

// --- Messages sent TO the worker isolate ---

sealed class _WorkerRequest {}

class _IngestQR extends _WorkerRequest {
  final String raw;
  _IngestQR(this.raw);
}

class _ResetRequest extends _WorkerRequest {
  final String? id;
  _ResetRequest(this.id);
}

class _SetOutputDirectory extends _WorkerRequest {
  final String? outputDirectory;
  _SetOutputDirectory(this.outputDirectory);
}

class _FlushAll extends _WorkerRequest {}

class _HydrateFromDisk extends _WorkerRequest {
  final String? outputDirectory;
  _HydrateFromDisk(this.outputDirectory);
}

// --- Messages sent FROM the worker isolate ---

sealed class WorkerEvent {}

/// Posted after every ingested (non-duplicate) QR string, and after any
/// change worth reflecting in the UI (chunk persisted, transfer completed).
class ScanCountedEvent extends WorkerEvent {
  final bool isNew;
  ScanCountedEvent(this.isNew);
}

class ProgressSnapshotEvent extends WorkerEvent {
  final ProgressSnapshot snapshot;

  /// True when this snapshot resulted from [AssemblerWorker.hydrateFromDisk]
  /// rather than a live scan — so the receiver can avoid surfacing a
  /// resumed-but-not-yet-scanned-this-session transfer as the active one.
  final bool fromHydration;

  ProgressSnapshotEvent(this.snapshot, {this.fromHydration = false});
}

class ChunkBytesEvent extends WorkerEvent {
  final int bytes;
  ChunkBytesEvent(this.bytes);
}

class TransferCompletedEvent extends WorkerEvent {
  final ProgressSnapshot snapshot;
  final List<int>? assembled;
  TransferCompletedEvent(this.snapshot, this.assembled);
}

class PersistErrorEvent extends WorkerEvent {
  final String transferId;
  final String message;
  PersistErrorEvent(this.transferId, this.message);
}

ProgressSnapshot _snapshotOf(Transfer t) => ProgressSnapshot(
      id: t.id,
      total: t.total,
      mode: t.mode,
      encoding: t.encoding,
      fountainFileSize: t.fountainFileSize,
      fountainSymbols: t.fountainSymbols,
      seenIndices: t.seenIndices.toList(),
      receivedBytes: t.receivedBytes,
      checksum: t.checksum,
      verified: t.verified,
      error: t.error,
      isComplete: t.isComplete,
      createdAt: t.createdAt,
      completedAt: t.completedAt,
    );

/// Entry point run inside the worker isolate. Owns the real [Assembler] (with
/// full chunk bytes) and all disk I/O for received chunks/metadata, so only
/// lightweight [WorkerEvent]s ever cross back to the main isolate.
void _workerMain((RootIsolateToken, SendPort) args) {
  final (rootIsolateToken, mainSendPort) = args;
  // Required before this isolate can use any Flutter platform channel (e.g.
  // path_provider's getDownloadsDirectory, or Flutter's own binary
  // messenger machinery) — a spawned isolate has no messenger of its own
  // until it registers with the root isolate's.
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  String? outputDirectory;
  final metadataWriters = <String, ChunkMetadataWriter>{};
  bool hydrating = false;

  ChunkMetadataWriter writerFor(Transfer t) => metadataWriters.putIfAbsent(
        t.id,
        () => ChunkMetadataWriter(t, outputDirectory: outputDirectory),
      );

  late final Assembler assembler;
  assembler = Assembler(
    onProgress: (t) {
      mainSendPort.send(ProgressSnapshotEvent(_snapshotOf(t), fromHydration: hydrating));
    },
    onComplete: (t) {
      if (t.error == null && t.assembled != null) {
        ChunkStorage.writeAssembledFile(t, outputDirectory: outputDirectory)
            .then((_) => writerFor(t).flush())
            .catchError((Object e) {
          mainSendPort.send(PersistErrorEvent(t.id, 'Failed to save transfer ${t.id}: $e'));
        });
      } else {
        writerFor(t).flush().catchError((Object e) {
          mainSendPort.send(PersistErrorEvent(t.id, 'Failed to save metadata for ${t.id}: $e'));
        });
      }
      mainSendPort.send(TransferCompletedEvent(_snapshotOf(t), t.assembled));
    },
    onChunkBytes: (bytes) {
      mainSendPort.send(ChunkBytesEvent(bytes));
    },
  );
  assembler.onChunkReceived = (t, index, bytes) {
    ChunkStorage.writeChunk(t, index, bytes, outputDirectory: outputDirectory).then((_) {
      writerFor(t).markDirty();
    }).catchError((Object e) {
      mainSendPort.send(PersistErrorEvent(t.id, 'Failed to save chunk $index for ${t.id}: $e'));
    });
  };

  receivePort.listen((message) {
    if (message is _IngestQR) {
      final isNew = assembler.ingest(message.raw);
      mainSendPort.send(ScanCountedEvent(isNew));
    } else if (message is _ResetRequest) {
      assembler.reset(message.id);
      if (message.id != null) {
        metadataWriters.remove(message.id)?.dispose();
      } else {
        for (final w in metadataWriters.values) {
          w.dispose();
        }
        metadataWriters.clear();
      }
    } else if (message is _SetOutputDirectory) {
      outputDirectory = message.outputDirectory;
    } else if (message is _FlushAll) {
      for (final w in metadataWriters.values) {
        unawaited(w.flush());
      }
    } else if (message is _HydrateFromDisk) {
      // Also adopt this as the working outputDirectory: a transfer that
      // turns out to already be complete gets assembled/written during
      // hydrate() below, and that write must use this directory directly
      // rather than falling through to path_provider's getDownloadsDirectory
      // (a platform-channel call) — doing a platform-channel round trip
      // synchronously interleaved with a large hydration scan is what
      // crashed the isolate in practice.
      outputDirectory = message.outputDirectory;

      // Assembler.hydrate fires onProgress per transfer, which already posts
      // a ProgressSnapshotEvent — no separate event type needed here. The
      // `hydrating` flag lets the main isolate tell hydration-sourced
      // snapshots apart from live-scan ones.
      ChunkStorage.hydrateAll(outputDirectory: message.outputDirectory).then((hydrated) async {
        hydrating = true;
        await assembler.hydrate(hydrated);
        hydrating = false;
      }).catchError((Object e) {
        hydrating = false;
        mainSendPort.send(PersistErrorEvent('', 'Failed to hydrate from disk: $e'));
      });
    }
  });
}

/// Main-isolate handle to the long-lived worker isolate that runs
/// [Assembler]/[FountainDecoder] and all per-chunk disk I/O off the UI
/// thread. Spawned once (via [spawn]) and kept alive for the app's lifetime.
class AssemblerWorker {
  final Isolate _isolate;
  final SendPort _sendPort;
  final StreamSubscription<dynamic> _subscription;

  AssemblerWorker._(this._isolate, this._sendPort, this._subscription);

  static Future<AssemblerWorker> spawn(void Function(WorkerEvent) onEvent) async {
    final rootIsolateToken = RootIsolateToken.instance;
    if (rootIsolateToken == null) {
      throw StateError('AssemblerWorker.spawn must be called with Flutter bindings initialized');
    }

    final initPort = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, (rootIsolateToken, initPort.sendPort));

    final sendPortCompleter = Completer<SendPort>();
    final subscription = initPort.listen((message) {
      if (message is SendPort && !sendPortCompleter.isCompleted) {
        sendPortCompleter.complete(message);
      } else if (message is WorkerEvent) {
        onEvent(message);
      }
    });

    final sendPort = await sendPortCompleter.future;
    return AssemblerWorker._(isolate, sendPort, subscription);
  }

  void ingestQR(String raw) => _sendPort.send(_IngestQR(raw));

  void reset([String? id]) => _sendPort.send(_ResetRequest(id));

  void setOutputDirectory(String? outputDirectory) =>
      _sendPort.send(_SetOutputDirectory(outputDirectory));

  /// Forces every transfer's debounced metadata writer to flush immediately
  /// — call when the app is about to background or be killed.
  void flushAll() => _sendPort.send(_FlushAll());

  /// Scans [outputDirectory] for incomplete transfers persisted by a prior
  /// run and rebuilds their state, so scanning can resume without
  /// re-receiving already-saved chunks. Results arrive asynchronously as
  /// [ProgressSnapshotEvent]s through the [spawn] event callback.
  void hydrateFromDisk(String? outputDirectory) =>
      _sendPort.send(_HydrateFromDisk(outputDirectory));

  Future<void> dispose() async {
    await _subscription.cancel();
    _isolate.kill(priority: Isolate.immediate);
  }
}
