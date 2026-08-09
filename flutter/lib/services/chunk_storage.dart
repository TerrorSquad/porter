import 'dart:convert';
import 'dart:io';

import '../models/hydrated_transfer.dart';
import '../models/transfer.dart';
import 'file_handler.dart';

final _chunkFilenameRegExp = RegExp(r'^chunk_(\d+)\.bin$');

/// Incrementally persists a [Transfer] to disk as its chunks arrive, so the
/// data survives even if the transfer is never explicitly saved.
///
/// Each transfer gets its own directory (named after its id) under the
/// configured output directory:
///
/// ```
/// <outputDirectory>/<transfer.id>/
///   chunks/
///     chunk_000001.bin
///     chunk_000002.bin
///     ...
///   metadata.json
///   <transfer.id>.<ext>   (written once the transfer completes)
/// ```
class ChunkStorage {
  static String _chunkFilename(int index) =>
      'chunk_${index.toString().padLeft(6, '0')}.bin';

  /// Returns the per-transfer directory, creating it if necessary.
  static Future<Directory> transferDirectory(
    Transfer transfer, {
    String? outputDirectory,
  }) async {
    final base = await FileHandler.resolveOutputDirectory(outputDirectory);
    final dir = Directory('${base.path}/${transfer.id}');
    await dir.create(recursive: true);
    return dir;
  }

  /// Writes [bytes] for chunk [index]. Does not touch metadata.json — callers
  /// persist metadata separately (see [ChunkMetadataWriter]) so a burst of
  /// chunk arrivals doesn't re-serialize the whole metadata file per chunk.
  static Future<void> writeChunk(
    Transfer transfer,
    int index,
    List<int> bytes, {
    String? outputDirectory,
  }) async {
    final dir = await transferDirectory(transfer, outputDirectory: outputDirectory);
    transfer.transferDirPath = dir.path;

    final chunksDir = Directory('${dir.path}/chunks');
    await chunksDir.create(recursive: true);
    await File('${chunksDir.path}/${_chunkFilename(index)}').writeAsBytes(bytes);
  }

  /// Writes a JSON summary of [transfer]'s current state.
  static Future<void> writeMetadata(
    Transfer transfer, {
    String? outputDirectory,
  }) async {
    final dir = await transferDirectory(transfer, outputDirectory: outputDirectory);
    transfer.transferDirPath = dir.path;

    final seenIndices = transfer.seenIndices.toList()..sort();
    final metadata = {
      'id': transfer.id,
      'mode': transfer.mode,
      'encoding': transfer.encoding,
      'fountainFileSize': transfer.fountainFileSize,
      'total': transfer.total,
      'seenIndices': seenIndices,
      'missingIndices': transfer.missingIndices,
      'receivedBytes': transfer.receivedBytes,
      'checksum': transfer.checksum,
      'verified': transfer.verified,
      'error': transfer.error,
      'isComplete': transfer.isComplete,
      'createdAt': transfer.createdAt.toIso8601String(),
      'completedAt': transfer.completedAt?.toIso8601String(),
    };

    await File('${dir.path}/metadata.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(metadata));
  }

  /// Writes the fully-assembled data for a completed [transfer] to its
  /// directory and returns the file's path.
  static Future<String> writeAssembledFile(
    Transfer transfer, {
    String? outputDirectory,
  }) async {
    final dir = await transferDirectory(transfer, outputDirectory: outputDirectory);
    transfer.transferDirPath = dir.path;

    final ext = FileHandler.guessExtension(transfer);
    final file = File('${dir.path}/${transfer.id}$ext');
    await file.writeAsBytes(transfer.assembled!);
    return file.path;
  }

  /// Scans [outputDirectory] for incomplete transfer directories (those with
  /// a `chunks/` folder but no final output file) and rebuilds each one's
  /// *index set* from disk, so a killed/restarted app can resume without
  /// rescanning already-received chunks. Deliberately cheap: only reads
  /// filenames, not chunk bytes (see [HydratedTransfer.readChunk]) — a
  /// resumed transfer can have tens of thousands of chunks, and reading them
  /// all into memory eagerly for every resumable transfer at once is
  /// expensive enough to destabilize the isolate.
  ///
  /// Trusts only `chunk_NNNNNN.bin` filenames as the source of truth for
  /// what's been received — never metadata.json's seenIndices, which may lag
  /// behind by up to the debounce interval (see ChunkMetadataWriter).
  /// metadata.json is read only for fields not derivable from the .bin files
  /// themselves (mode, encoding, total, checksum); a missing or corrupt
  /// metadata.json still yields a valid hydration with those fields defaulted.
  static Future<List<HydratedTransfer>> hydrateAll({String? outputDirectory}) async {
    final base = await FileHandler.resolveOutputDirectory(outputDirectory);
    if (!await base.exists()) return [];

    final result = <HydratedTransfer>[];
    await for (final entry in base.list()) {
      if (entry is! Directory) continue;
      final hydrated = await _hydrateOne(entry);
      if (hydrated != null) result.add(hydrated);
    }
    return result;
  }

  static Future<HydratedTransfer?> _hydrateOne(Directory transferDir) async {
    final chunksDir = Directory('${transferDir.path}/chunks');
    if (!await chunksDir.exists()) return null;

    final id = transferDir.uri.pathSegments.where((s) => s.isNotEmpty).last;

    // A completed transfer already has its final <id>.<ext> output file
    // written (see writeAssembledFile) — nothing to resume, so skip it
    // rather than needlessly reading every chunk back into memory.
    final hasFinalOutput = await transferDir
        .list()
        .any((e) => e is File && e.uri.pathSegments.last.startsWith('$id.'));
    if (hasFinalOutput) return null;

    // Only the index set is read here — not the bytes. A resumed transfer
    // can have tens of thousands of chunk files; reading them all into
    // memory eagerly, for every resumable transfer at once, is expensive
    // enough to destabilize the isolate. Bytes are read lazily via
    // readChunk, only for a transfer that's actually assembled.
    final seenIndices = <int>{};
    await for (final entry in chunksDir.list()) {
      if (entry is! File) continue;
      final match = _chunkFilenameRegExp.firstMatch(entry.uri.pathSegments.last);
      if (match == null) continue;
      seenIndices.add(int.parse(match.group(1)!));
    }
    if (seenIndices.isEmpty) return null;

    String mode = 'T';
    String encoding = 'sequential';
    int total = 0;
    int? fountainFileSize;
    String? checksum;
    final metaFile = File('${transferDir.path}/metadata.json');
    if (await metaFile.exists()) {
      try {
        final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        mode = json['mode'] as String? ?? mode;
        encoding = json['encoding'] as String? ?? encoding;
        total = json['total'] as int? ?? total;
        fountainFileSize = json['fountainFileSize'] as int?;
        checksum = json['checksum'] as String?;
      } catch (_) {
        // Corrupt/partial metadata.json (e.g. killed mid-write) — proceed
        // with .bin-derived state only; total/mode/checksum are re-learned
        // once the sender re-sends header/checksum chunks.
      }
    }

    return HydratedTransfer(
      id: id,
      mode: mode,
      encoding: encoding,
      total: total,
      fountainFileSize: fountainFileSize,
      checksum: checksum,
      transferDirPath: transferDir.path,
      seenIndices: seenIndices,
      readChunk: (index) => File('${chunksDir.path}/${_chunkFilename(index)}').readAsBytes(),
    );
  }
}
