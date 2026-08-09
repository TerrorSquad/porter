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

  /// Reads a hydrated chunk's bytes from disk on demand. Set only for a
  /// transfer resumed via [Assembler.hydrate], where [chunks] is
  /// intentionally left unpopulated for already-seen indices to avoid
  /// reading potentially tens of thousands of chunk files into memory
  /// eagerly at startup. Live-ingested chunks never need this — they're
  /// already in [chunks].
  Future<List<int>> Function(int index)? chunkReader;

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
      final needed = fountainSymbolsNeeded;
      if (needed <= 0) return 0.99;
      final frac = fountainSymbols / needed;
      return frac < 0.99 ? frac : 0.99;
    }
    return seenIndices.length / total;
  }

  /// Distinct symbols peeling needs before it can decode.
  ///
  /// Measured end-to-end at ~2x K from a cold start (1.33x-1.69x for
  /// K=50..20000, 1.89x at K=70965), and scaled to 2.0x so the bar
  /// under-promises rather than stalling near 100%.
  ///
  /// Scaled to the blocks still *missing*, not to all of K: on a resumed
  /// transfer much of the file is already decoded, and charging for symbols
  /// that would rebuild blocks sitting on disk badly overstates the work
  /// left. Observed on a resume with 36% of blocks already recovered — the
  /// flat 2K target implied ~13 hours remaining when most of that had
  /// already been paid for.
  int get fountainSymbolsNeeded {
    final missing = total - seenIndices.length;
    if (missing <= 0) return fountainSymbols;
    return missing * 2;
  }

  /// Symbols collected that count toward [fountainSymbolsNeeded].
  ///
  /// A resumed decoder can only credit a persisted seq when every block it
  /// covers is already recovered; the rest must be scanned again (see
  /// `FountainDecoder.restoreSeenSeqs`). Those re-scans are real work, so
  /// they are not counted as done — but the symbols collected *this session*
  /// are, which is what [fountainSymbols] tracks.
  int get fountainSymbolsCollected => fountainSymbols;

  /// Short progress caption, e.g. "12 / 40 chunks" (sequential) or
  /// "137 / 60 symbols · 3 / 40 blocks decoded" (fountain).
  ///
  /// Leads with symbols against the count actually needed: blocks stay near
  /// zero until a late avalanche, so showing blocks first made a healthy
  /// transfer look frozen.
  String get progressLabel {
    if (isFountain) {
      return '$fountainSymbols / $fountainSymbolsNeeded symbols · '
          '${seenIndices.length} / $total blocks decoded';
    }
    return '${seenIndices.length} / $total chunks';
  }

  /// Blocks still to recover. The honest measure of what is left on a
  /// resumed transfer, where symbol counts restart but blocks do not.
  int get missingBlocks => (total - seenIndices.length).clamp(0, total);

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

  /// Marks [index] as seen without loading its bytes — used by
  /// [Assembler.hydrate] to credit disk-scanned chunks cheaply. The bytes are
  /// read lazily via [chunkReader] only if/when this transfer is assembled.
  void markSeen(int index) => seenIndices.add(index);

  /// Releases [index]'s in-RAM bytes now that they are durably persisted,
  /// wiring [readVia] as the lazy source so assembly can page them back.
  ///
  /// Without this a large transfer holds the entire file in memory while it
  /// is still being received, on top of what the fountain decoder retains.
  /// [receivedBytes] is deliberately not adjusted — it counts bytes received,
  /// not bytes resident.
  void evictChunkBytes(
    int index, {
    required Future<List<int>> Function(int index) readVia,
  }) {
    // Assembly reads `chunks` directly and only falls back to `chunkReader`
    // per missing index. Evicting while it is mid-read is a race: the write
    // that triggered this is async, so a chunk can vanish between the read
    // of one index and the next.
    if (assembling) return;
    // Wire the reader up front, so a chunk evicted now is still reachable.
    chunkReader ??= readVia;
    chunks.remove(index);
  }

  /// True while `_assemble` is walking `chunks`; see [evictChunkBytes].
  bool assembling = false;

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
    // The worker owns the real start time. A main-isolate mirror is
    // constructed when the UI first hears about the transfer — at app launch
    // for hydrated ones — so without this every transfer showed the same
    // "elapsed", counted from when the UI happened to build its mirror.
    createdAt = s.createdAt;
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
