import 'dart:convert';
import 'dart:io';

import '../models/transfer.dart';
import 'file_handler.dart';

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

  /// Writes [bytes] for chunk [index] and refreshes the metadata file.
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

    await writeMetadata(transfer, outputDirectory: outputDirectory);
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
}
