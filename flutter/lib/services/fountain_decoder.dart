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
class FountainDecoder {
  final int k;
  final int blockSize;
  final DegreeTable _table;

  /// 1-based source index -> recovered block bytes.
  final Map<int, List<int>> _recovered = {};

  /// Seq numbers already ingested, so duplicates are cheap to ignore.
  final Set<int> _seenSeqs = {};

  /// Symbols not yet reduced to a single unresolved index.
  final List<_PendingSymbol> _pending = [];

  FountainDecoder({required this.k, required this.blockSize})
      : _table = buildDegreeTable(k);

  /// Number of source blocks recovered so far.
  int get recoveredCount => _recovered.length;

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

    return newlyRecovered;
  }

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
