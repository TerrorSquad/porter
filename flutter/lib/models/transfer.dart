class Transfer {
  final String id;
  int total = 0;
  String mode = 'T';

  /// Transfer coding scheme: 'sequential' (indexed chunks) or 'fountain' (LT
  /// codes). For fountain transfers [total] is the source-block count K,
  /// [seenIndices]/[chunks] hold *recovered* source blocks (fed in by the
  /// FountainDecoder), and [fountainFileSize] is the original byte length.
  String encoding = 'sequential';

  /// Original file size in bytes for fountain transfers; null otherwise. The
  /// last source block is zero-padded, so assembled data is trimmed to this.
  int? fountainFileSize;

  Map<int, List<int>> chunks = {}; // index -> bytes
  Set<int> seenIndices = {};
  String? checksum;
  List<int>? assembled;
  bool? verified;
  String? error;
  DateTime createdAt;
  DateTime? completedAt;

  /// Path the assembled data was last saved to, or null if not saved yet.
  String? savedPath;

  /// Directory holding this transfer's incrementally-saved chunks and
  /// metadata, once created on disk.
  String? transferDirPath;

  Transfer({
    required this.id,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  int get progress => total > 0 ? ((seenIndices.length / total) * 100).round() : 0;
  bool get isComplete => total > 0 && seenIndices.length == total;

  /// Chunk indices (1-based) that have not been seen yet, in ascending order.
  List<int> get missingIndices => [
        for (var i = 1; i <= total; i++)
          if (!seenIndices.contains(i)) i,
      ];

  /// Total bytes received so far, across all chunks (before any
  /// decompression for mode 'C').
  int get receivedBytes => chunks.values.fold(0, (sum, c) => sum + c.length);

  void addChunk(int index, List<int> data) {
    if (!seenIndices.contains(index)) {
      seenIndices.add(index);
      chunks[index] = data;
    }
  }

  void reset() {
    total = 0;
    mode = 'T';
    encoding = 'sequential';
    fountainFileSize = null;
    chunks.clear();
    seenIndices.clear();
    checksum = null;
    assembled = null;
    verified = null;
    error = null;
    completedAt = null;
    savedPath = null;
  }
}
