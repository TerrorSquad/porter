import 'progress_snapshot.dart';

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

  /// Distinct fountain symbols collected so far (fountain transfers only).
  /// This is the progress signal worth showing: recovered blocks stay near
  /// zero until ~K symbols are in, then complete in a burst.
  int fountainSymbols = 0;

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

  bool get isFountain => encoding == 'fountain';

  /// Progress fraction (0..1) for display. Sequential mode tracks recovered
  /// chunks; fountain mode tracks distinct symbols collected toward K, since
  /// recovered blocks stay ~0 until a late avalanche and would otherwise make
  /// a healthy transfer look frozen. Capped just below 1 until actually
  /// complete so the bar doesn't sit at 100% during the final decode.
  double get displayProgress {
    if (isComplete) return 1.0;
    if (total <= 0) return 0.0;
    if (isFountain) {
      final frac = fountainSymbols / total;
      return frac < 0.99 ? frac : 0.99;
    }
    return seenIndices.length / total;
  }

  /// Short progress caption, e.g. "12 / 40 chunks" (sequential) or
  /// "137 symbols · 3 / 40 blocks" (fountain).
  String get progressLabel {
    if (isFountain) {
      return '$fountainSymbols symbols · ${seenIndices.length} / $total blocks';
    }
    return '${seenIndices.length} / $total chunks';
  }

  /// Chunk indices (1-based) that have not been seen yet, in ascending order.
  List<int> get missingIndices => [
        for (var i = 1; i <= total; i++)
          if (!seenIndices.contains(i)) i,
      ];

  /// Total bytes received so far, across all chunks (before any
  /// decompression for mode 'C'). Kept in sync by [addChunk]/[applySnapshot]
  /// rather than derived on read, since a main-isolate mirror [Transfer]
  /// (see [applySnapshot]) never holds the actual chunk bytes.
  int receivedBytes = 0;

  void addChunk(int index, List<int> data) {
    if (!seenIndices.contains(index)) {
      seenIndices.add(index);
      chunks[index] = data;
      receivedBytes += data.length;
    }
  }

  /// Updates every display-relevant field from a [ProgressSnapshot] posted
  /// by the worker isolate. Never touches [chunks]/[assembled] — this
  /// transfer instance is a lightweight main-isolate mirror; the real bytes
  /// stay inside the worker isolate's own [Transfer] until completion.
  void applySnapshot(ProgressSnapshot s) {
    total = s.total;
    mode = s.mode;
    encoding = s.encoding;
    fountainFileSize = s.fountainFileSize;
    fountainSymbols = s.fountainSymbols;
    seenIndices = s.seenIndices.toSet();
    receivedBytes = s.receivedBytes;
    checksum = s.checksum;
    verified = s.verified;
    error = s.error;
    completedAt = s.completedAt;
  }

  void reset() {
    total = 0;
    mode = 'T';
    encoding = 'sequential';
    fountainFileSize = null;
    fountainSymbols = 0;
    chunks.clear();
    seenIndices.clear();
    receivedBytes = 0;
    checksum = null;
    assembled = null;
    verified = null;
    error = null;
    completedAt = null;
    savedPath = null;
  }
}
