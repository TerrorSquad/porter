/// Rebuilt state for one transfer, scanned from disk on cold start. See
/// `ChunkStorage.hydrateAll`.
class HydratedTransfer {
  final String id;
  final String mode;
  final String encoding;
  final int total;
  final int? fountainFileSize;
  final String? checksum;
  final String transferDirPath;

  /// Indices (1-based) with an existing `chunks/chunk_NNNNNN.bin` file — the
  /// source of truth for what's been received (never metadata.json, which
  /// may lag behind by up to the debounce interval). Deliberately just the
  /// index set, not the bytes: a resumed transfer can have tens of thousands
  /// of chunks, and reading them all into memory eagerly at startup — for
  /// every resumable transfer at once — is what caused the isolate to crash
  /// in practice. Bytes are read lazily, only when actually needed (final
  /// assembly), via [readChunk].
  final Set<int> seenIndices;

  /// Reads chunk [index]'s bytes from disk on demand. Only called once per
  /// index, at assembly time.
  final Future<List<int>> Function(int index) readChunk;

  /// Fountain symbol seqs already ingested before the restart, so a resumed
  /// decoder can skip re-scanning symbols whose blocks are already on disk.
  /// Empty for sequential transfers.
  final Set<int> seenSeqs;

  /// Size of one persisted chunk, i.e. the fountain block size this transfer
  /// was recorded at. Null when unknown (no chunks yet, or sequential).
  final int? blockSize;

  /// When the transfer originally started, read back from metadata.json.
  /// Null if unknown (missing/corrupt metadata), in which case the resumed
  /// transfer keeps its own creation time.
  final DateTime? createdAt;

  const HydratedTransfer({
    required this.id,
    required this.mode,
    required this.encoding,
    required this.total,
    required this.fountainFileSize,
    required this.checksum,
    required this.transferDirPath,
    required this.seenIndices,
    required this.readChunk,
    this.seenSeqs = const {},
    this.blockSize,
    this.createdAt,
  });
}
