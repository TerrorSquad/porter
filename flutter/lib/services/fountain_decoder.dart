import 'fountain_codec.dart';

/// A source block recovered by the decoder. [index] is 1-based.
class RecoveredBlock {
  final int index;
  final List<int> bytes;

  const RecoveredBlock(this.index, this.bytes);
}

/// One received fountain symbol still waiting to be peeled: its running XOR
/// value (with all already-recovered indices removed) plus the set of source
/// indices it still depends on.
class _PendingSymbol {
  final List<int> xor;
  final Set<int> unresolved;

  _PendingSymbol(this.xor, this.unresolved);
}

/// Peeling (belief-propagation) decoder for fountain (LT code) symbols.
///
/// Symbols may arrive in any order and any sufficient subset reconstructs all
/// [k] source blocks. The (degree, indices) mapping for each symbol is derived
/// from its `seq` via [sampleIndices], so it is never transmitted — it must be
/// regenerated identically here, which the shared [fountain_codec] guarantees.
/// Above this many unresolved blocks, Gaussian elimination's O(N^2)/O(N^3)
/// cost is no longer worth attempting; rely on peeling alone.
const int kDefaultMaxEliminationMissingCount = 500;

class FountainDecoder {
  final int k;
  final int blockSize;
  final int maxEliminationMissingCount;
  final DegreeTable _table;

  /// 1-based source index -> recovered block bytes.
  final Map<int, List<int>> _recovered = {};

  /// Seq numbers already ingested, so duplicates are cheap to ignore.
  final Set<int> _seenSeqs = {};

  /// Symbols not yet reduced to a single unresolved index.
  final List<_PendingSymbol> _pending = [];

  FountainDecoder({
    required this.k,
    required this.blockSize,
    this.maxEliminationMissingCount = kDefaultMaxEliminationMissingCount,
  }) : _table = buildDegreeTable(k);

  /// Number of source blocks recovered so far.
  int get recoveredCount => _recovered.length;

  /// Number of distinct symbols ingested so far. Unlike [recoveredCount], this
  /// climbs steadily as frames are scanned, so it's the meaningful progress
  /// signal for the UI — peeling recovers almost nothing until ~K symbols are
  /// in, then completes in a burst.
  int get symbolCount => _seenSeqs.length;

  /// Whether symbol [seq] has already been ingested (so it would be a no-op).
  bool hasSeq(int seq) => _seenSeqs.contains(seq);

  /// True once every source block has been recovered.
  bool get isComplete => _recovered.length == k;

  /// Indices (1-based) still not recovered, ascending.
  List<int> get missingIndices => [
        for (var i = 1; i <= k; i++)
          if (!_recovered.containsKey(i)) i,
      ];

  /// XOR [src] into [dst] in place (both must be [blockSize] long).
  void _xorInto(List<int> dst, List<int> src) {
    for (int b = 0; b < blockSize; b++) {
      dst[b] ^= src[b];
    }
  }

  /// Feeds one symbol into the decoder. Returns the source blocks newly
  /// recovered as a direct or cascaded result (empty if the symbol was a
  /// duplicate, fully redundant, or merely queued for later).
  List<RecoveredBlock> addSymbol(int seq, List<int> bytes) {
    if (isComplete) return const [];
    if (_seenSeqs.contains(seq)) return const [];
    _seenSeqs.add(seq);

    final sampled = sampleIndices(seq, k, _table);

    // Start from a private copy so XOR-reduction never mutates the caller's
    // buffer, and pad/trim defensively to blockSize.
    final xor = List<int>.filled(blockSize, 0);
    for (int b = 0; b < blockSize && b < bytes.length; b++) {
      xor[b] = bytes[b];
    }

    final unresolved = <int>{};
    for (final idx in sampled.indices) {
      final known = _recovered[idx];
      if (known != null) {
        _xorInto(xor, known);
      } else {
        unresolved.add(idx);
      }
    }

    final newlyRecovered = <RecoveredBlock>[];

    if (unresolved.isEmpty) {
      // Fully redundant — every block it covered is already known.
      return newlyRecovered;
    }

    if (unresolved.length == 1) {
      _recoverAndCascade(unresolved.first, xor, newlyRecovered);
    } else {
      _pending.add(_PendingSymbol(xor, unresolved));
    }

    // Peeling can stall on a "stuck core" of mutually-overlapping symbols even
    // when the data is fully determined (common at small K). When this symbol
    // didn't let peeling advance yet enough independent equations exist to
    // possibly solve the residual, fall back to Gaussian elimination over
    // GF(2). Gating on a stalled peel keeps GE off the common fast path, and
    // peeling having shrunk _pending to the small core keeps it cheap. Above
    // maxEliminationMissingCount, GE's O(N^2)/O(N^3) cost is skipped entirely
    // — peeling alone must carry large-K transfers to avoid UI-thread stalls.
    if (newlyRecovered.isEmpty &&
        !isComplete &&
        _missingCount < maxEliminationMissingCount &&
        _pending.length >= _missingCount) {
      _solveResidualByElimination(newlyRecovered);
    }

    return newlyRecovered;
  }

  /// Count of source blocks not yet recovered.
  int get _missingCount => k - _recovered.length;

  /// Records source block [index] = [bytes], then repeatedly scans the pending
  /// pool, peeling [index] (and any further singletons it exposes) out of every
  /// symbol that referenced it, recovering more blocks in cascade.
  void _recoverAndCascade(
    int index,
    List<int> bytes,
    List<RecoveredBlock> out,
  ) {
    final queue = <MapEntry<int, List<int>>>[MapEntry(index, bytes)];

    while (queue.isNotEmpty) {
      final entry = queue.removeLast();
      final idx = entry.key;
      if (_recovered.containsKey(idx)) continue;

      final blockBytes = entry.value;
      _recovered[idx] = blockBytes;
      out.add(RecoveredBlock(idx, blockBytes));

      for (int i = _pending.length - 1; i >= 0; i--) {
        final p = _pending[i];
        if (!p.unresolved.remove(idx)) continue;
        _xorInto(p.xor, blockBytes);

        if (p.unresolved.isEmpty) {
          _pending.removeAt(i);
        } else if (p.unresolved.length == 1) {
          _pending.removeAt(i);
          queue.add(MapEntry(p.unresolved.first, p.xor));
        }
      }
    }
  }

  /// Returns the symmetric difference of two index sets (GF(2) addition of
  /// coefficient vectors).
  Set<int> _xorSets(Set<int> a, Set<int> b) {
    final r = Set<int>.from(a);
    for (final x in b) {
      if (!r.remove(x)) r.add(x);
    }
    return r;
  }

  /// Attempts to solve the residual system of [_pending] equations (each a set
  /// of unknown indices = an XOR payload) via Gaussian elimination over GF(2).
  /// On full rank it recovers every remaining block, clears [_pending], and
  /// appends the recovered blocks to [out]; otherwise it leaves state untouched
  /// and waits for more symbols.
  void _solveResidualByElimination(List<RecoveredBlock> out) {
    final unknowns = _missingCount;

    // Forward elimination into row-echelon form, keyed by each row's smallest
    // (pivot) coefficient. Work on copies so a non-full-rank attempt is a no-op.
    final pivots = <int, _PendingSymbol>{};
    for (final p in _pending) {
      var coeffs = Set<int>.from(p.unresolved);
      var bytes = List<int>.from(p.xor);

      while (coeffs.isNotEmpty) {
        final pivot = coeffs.reduce((a, b) => a < b ? a : b);
        final existing = pivots[pivot];
        if (existing == null) {
          pivots[pivot] = _PendingSymbol(bytes, coeffs);
          break;
        }
        coeffs = _xorSets(coeffs, existing.unresolved);
        _xorInto(bytes, existing.xor);
      }
    }

    if (pivots.length < unknowns) return; // not yet uniquely solvable

    // Back-substitution: solve pivots from the largest index down, so each
    // row's higher-index coefficients are already known when we reach it.
    final pivotIndicesDesc = pivots.keys.toList()..sort((a, b) => b - a);
    final solution = <int, List<int>>{};
    for (final pivot in pivotIndicesDesc) {
      final row = pivots[pivot]!;
      final bytes = List<int>.from(row.xor);
      for (final c in row.unresolved) {
        if (c == pivot) continue;
        final solved = solution[c];
        if (solved != null) _xorInto(bytes, solved);
      }
      solution[pivot] = bytes;
    }

    _pending.clear();
    for (final entry in solution.entries) {
      if (_recovered.containsKey(entry.key)) continue;
      _recovered[entry.key] = entry.value;
      out.add(RecoveredBlock(entry.key, entry.value));
    }
  }

  /// Concatenates the recovered blocks 1..k in order. Throws if incomplete.
  /// Callers trim the result to the original file size themselves.
  List<int> assemble() {
    if (!isComplete) {
      throw StateError('Cannot assemble: $recoveredCount of $k blocks recovered');
    }
    final out = <int>[];
    for (int i = 1; i <= k; i++) {
      out.addAll(_recovered[i]!);
    }
    return out;
  }
}
