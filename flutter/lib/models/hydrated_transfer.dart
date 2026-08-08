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

  /// Recovered chunk bytes, keyed by 1-based index — read directly from
  /// `chunks/chunk_NNNNNN.bin`, the source of truth (never metadata.json,
  /// which may lag behind by up to the debounce interval).
  final Map<int, List<int>> chunks;

  const HydratedTransfer({
    required this.id,
    required this.mode,
    required this.encoding,
    required this.total,
    required this.fountainFileSize,
    required this.checksum,
    required this.transferDirPath,
    required this.chunks,
  });
}
