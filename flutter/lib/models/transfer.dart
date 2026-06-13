class Transfer {
  final String id;
  int total = 0;
  String mode = 'T';
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
