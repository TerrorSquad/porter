import 'dart:io';
import 'dart:typed_data';

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
  /// `Uint8List`, not `List<int>`: a boxed list costs ~8 bytes per byte in the
  /// Dart VM. With tens of thousands of pending symbols that is the single
  /// largest allocation in the receiver — measured 152.9 MB vs 32.7 MB for
  /// 20000 x 893-byte buffers.
  ///
  /// Null once the buffer has been spilled to the [SymbolSpill]; [slot] then
  /// says where to read it back from. Only the buffer is spilled — the
  /// [unresolved] index set stays resident, since it's small and is what the
  /// peeling loop consults constantly.
  Uint8List? xor;

  /// Offset in the spill file, or -1 while resident.
  int slot;

  final Set<int> unresolved;

  _PendingSymbol(this.xor, this.unresolved) : slot = -1;
}

/// Backing store for pending XOR buffers that don't fit in RAM.
///
/// At K=618429 (a 1 GB file) the pending pool alone measured ~2.6 GB, which
/// OOMs a phone. Spilling keeps the resident set bounded: buffers are written
/// to one append-only file and paged back on demand. Peeling touches a given
/// symbol only when one of its blocks is recovered, so most spilled buffers
/// are read back at most a handful of times.
abstract class SymbolSpill {
  /// Appends [bytes], returning the slot to read it back with.
  int write(Uint8List bytes);

  /// Reads the buffer previously written to [slot].
  Uint8List read(int slot, int length);

  /// Overwrites the buffer at [slot] (same length).
  void overwrite(int slot, Uint8List bytes);

  void dispose();
}

/// File-backed [SymbolSpill]. Synchronous by necessity: the peeling loop is
/// hot and already runs on the worker isolate, so blocking reads there cost
/// nothing the UI can see.
class FileSymbolSpill implements SymbolSpill {
  final RandomAccessFile _file;
  int _end = 0;

  FileSymbolSpill(File file)
      : _file = file.openSync(mode: FileMode.write);

  @override
  int write(Uint8List bytes) {
    final slot = _end;
    _file.setPositionSync(slot);
    _file.writeFromSync(bytes);
    _end += bytes.length;
    return slot;
  }

  @override
  Uint8List read(int slot, int length) {
    _file.setPositionSync(slot);
    return _file.readSync(length);
  }

  @override
  void overwrite(int slot, Uint8List bytes) {
    _file.setPositionSync(slot);
    _file.writeFromSync(bytes);
  }

  @override
  void dispose() {
    try {
      _file.closeSync();
    } catch (_) {
      // Already closed / file removed — nothing to salvage.
    }
  }
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

/// How many recovered blocks stay resident when a [BlockLoader] is supplied.
/// At a few KB per block this caps the recovered-block footprint in the low
/// tens of MB regardless of K, instead of growing to K * blockSize.
const int kDefaultMaxCachedBlocks = 2048;

/// Pending XOR buffers kept in RAM when a [SymbolSpill] is supplied.
///
/// Sized so a realistic transfer never spills at all: at a ~1.6 KB block this
/// is ~240 MB, which comfortably holds the ~90 MB pool of a 115 MB transfer.
/// The spill exists for the genuinely huge case (a 1 GB file projects to
/// ~2.6 GB fully resident, which OOMs a phone), not as a routine path.
///
/// An earlier 20000 (~32 MB) was far too aggressive. Spilling is cheap while
/// symbols only arrive, but during the decode avalanche each peel cascades
/// through many pending symbols at once — with most of them evicted that
/// becomes a synchronous disk read per step, and the decoder burns CPU making
/// almost no progress. Observed at K=70965: 26745 blocks recovered, 55887
/// symbols pending, ~36000 of them spilled, 52% CPU and no writes for
/// minutes.
const int kDefaultMaxResidentSymbols = 150000;

/// Reads back a previously-recovered block's bytes, or null if unavailable.
/// Lets the decoder evict recovered blocks from RAM (they are already
/// persisted to disk by the caller) and page them back in only when peeling
/// actually needs them. See [FountainDecoder.blockLoader].
typedef BlockLoader = List<int>? Function(int index);

class FountainDecoder {
  final int k;
  final int blockSize;
  final int maxEliminationMissingCount;
  final DegreeTable _table;

  /// When set, recovered blocks are held only as long as [maxCachedBlocks]
  /// allows; evicted ones are re-read through this on demand. The caller must
  /// have durably persisted a block before it can be evicted, which is true
  /// here — Assembler writes each recovered block to disk as it arrives.
  ///
  /// Without this the decoder keeps every recovered block in memory: at
  /// K=70965 that is gigabytes, on top of the pending pool.
  final BlockLoader? blockLoader;

  /// Cap on how many recovered blocks stay resident when [blockLoader] is
  /// set. Evicts in insertion order — peeling touches a block only while
  /// symbols referencing it are still pending, so recently-recovered blocks
  /// are the ones worth keeping.
  final int maxCachedBlocks;

  /// 1-based source index -> recovered block bytes. With [blockLoader] set,
  /// this is a bounded cache rather than the full set; [_recoveredIndices] is
  /// then the authoritative record of what has been recovered.
  final Map<int, List<int>> _recovered = {};

  /// Every index recovered so far. Tracked separately from [_recovered]
  /// because that map is evicted from when [blockLoader] is in use.
  final Set<int> _recoveredIndices = {};

  /// Seq numbers already ingested, so duplicates are cheap to ignore.
  final Set<int> _seenSeqs = {};

  /// Source index -> the pending symbols that still depend on it. Lets a
  /// peel touch only the affected symbols instead of the whole pool, which is
  /// what keeps the endgame linear rather than quadratic. Identity-based sets,
  /// so removal is O(1) and duplicate symbols stay distinct.
  final Map<int, Set<_PendingSymbol>> _dependents = {};

  /// Live entries across [_dependents] (a symbol appears once per unresolved
  /// index, so the map's sizes can't be summed cheaply).
  int _pendingCount = 0;

  /// Optional disk backing for pending XOR buffers. Without it the pool is
  /// held entirely in RAM, which is fine up to ~100k symbols and fatal beyond
  /// (measured ~2.6 GB projected at K=618429).
  final SymbolSpill? spill;

  /// How many pending buffers stay resident when [spill] is set.
  final int maxResidentSymbols;

  /// Resident pending buffers in insertion order, for eviction. Only tracked
  /// when spilling; a plain queue is enough because eviction order barely
  /// matters — any spilled buffer is one sequential read away.
  final List<_PendingSymbol> _resident = [];

  FountainDecoder({
    required this.k,
    required this.blockSize,
    this.maxEliminationMissingCount = kDefaultMaxEliminationMissingCount,
    this.blockLoader,
    this.maxCachedBlocks = kDefaultMaxCachedBlocks,
    this.spill,
    this.maxResidentSymbols = kDefaultMaxResidentSymbols,
  }) : _table = buildDegreeTable(k);

  /// Returns [p]'s XOR buffer, paging it back from [spill] if evicted.
  Uint8List _xorOf(_PendingSymbol p) {
    final resident = p.xor;
    if (resident != null) return resident;

    final bytes = spill!.read(p.slot, blockSize);
    p.xor = bytes;
    _resident.add(p);
    _evictIfNeeded();
    return bytes;
  }

  /// Spills the oldest resident buffers until back under
  /// [maxResidentSymbols]. A buffer already written to the spill is rewritten
  /// on eviction because peeling XORs into it in place while resident.
  void _evictIfNeeded() {
    final store = spill;
    if (store == null) return;

    var i = 0;
    while (_resident.length - i > maxResidentSymbols) {
      final p = _resident[i++];
      final bytes = p.xor;
      // Retired while resident, or already evicted by another path.
      if (bytes == null || p.unresolved.isEmpty) continue;
      if (p.slot < 0) {
        p.slot = store.write(bytes);
      } else {
        store.overwrite(p.slot, bytes);
      }
      p.xor = null;
    }
    if (i > 0) _resident.removeRange(0, i);
  }

  /// Number of source blocks recovered so far.
  int get recoveredCount => _recoveredIndices.length;

  /// Returns block [index]'s bytes, paging it back from [blockLoader] if it
  /// has been evicted. Null only if the block isn't recovered at all (or the
  /// loader can't produce it, in which case peeling simply defers).
  List<int>? _block(int index) {
    final cached = _recovered[index];
    if (cached != null) return cached;
    if (!_recoveredIndices.contains(index)) return null;

    final loaded = blockLoader?.call(index);
    if (loaded != null) _remember(index, loaded);
    return loaded;
  }

  /// Inserts a block into the resident cache, evicting the oldest entries
  /// once over [maxCachedBlocks]. No-op eviction when [blockLoader] is null,
  /// since nothing could page the block back in.
  void _remember(int index, List<int> bytes) {
    _recovered[index] = bytes;
    if (blockLoader == null) return;
    while (_recovered.length > maxCachedBlocks) {
      _recovered.remove(_recovered.keys.first);
    }
  }

  /// Number of distinct symbols ingested so far. Unlike [recoveredCount], this
  /// climbs steadily as frames are scanned, so it's the meaningful progress
  /// signal for the UI — peeling recovers almost nothing until ~K symbols are
  /// in, then completes in a burst.
  int get symbolCount => _seenSeqs.length;

  /// Whether symbol [seq] has already been ingested (so it would be a no-op).
  bool hasSeq(int seq) => _seenSeqs.contains(seq);

  /// The seqs ingested so far, for persisting across a restart.
  ///
  /// Only the seq *set* is worth saving: the pending symbols themselves are
  /// far larger than the file being transferred (one blockSize buffer each,
  /// times tens of thousands), so persisting them would cost more I/O than
  /// rescanning. Restoring the set instead lets a resumed transfer skip
  /// symbols whose blocks are already on disk. See [restoreSeenSeqs].
  Iterable<int> get seenSeqs => _seenSeqs;

  /// Re-marks [seqs] as already ingested after a restart, and credits the
  /// blocks in [recovered] (read back from disk) so peeling can use them.
  ///
  /// Pending state is deliberately not restored — it isn't persisted. A
  /// resumed transfer therefore re-peels from the recovered blocks it has,
  /// and any symbol whose contribution was only captured in a lost pending
  /// buffer must be rescanned. Marking those seqs seen would lose them
  /// permanently, so only seqs that produced a *recovered* block are safely
  /// skippable; the rest are dropped from the set here.
  /// [recoveredIndices] credits blocks that exist on disk but whose bytes
  /// aren't in [recovered] — after a hydrate that's all of them, since the
  /// bytes are read lazily. They're marked recovered so peeling treats them
  /// as known, and [blockLoader] pages the bytes in when actually needed.
  void restoreSeenSeqs(
    Iterable<int> seqs,
    Map<int, List<int>> recovered, {
    Iterable<int> recoveredIndices = const [],
  }) {
    for (final entry in recovered.entries) {
      _recoveredIndices.add(entry.key);
      _remember(entry.key, entry.value);
    }
    _recoveredIndices.addAll(recoveredIndices);
    // A seq is only safe to skip if every block it covers is already
    // recovered — otherwise its unresolved contribution lived solely in the
    // dropped pending pool and the symbol must be seen again.
    for (final seq in seqs) {
      final sampled = sampleIndices(seq, k, _table);
      if (sampled.indices.every(_recoveredIndices.contains)) {
        _seenSeqs.add(seq);
      }
    }
  }

  /// True once every source block has been recovered.
  bool get isComplete => _recoveredIndices.length == k;

  /// Indices (1-based) still not recovered, ascending.
  List<int> get missingIndices => [
        for (var i = 1; i <= k; i++)
          if (!_recoveredIndices.contains(i)) i,
      ];

  /// XOR [src] into [dst] in place (both must be [blockSize] long).
  void _xorInto(Uint8List dst, List<int> src) {
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
    final xor = Uint8List(blockSize);
    for (int b = 0; b < blockSize && b < bytes.length; b++) {
      xor[b] = bytes[b];
    }

    final unresolved = <int>{};
    for (final idx in sampled.indices) {
      final known = _block(idx);
      if (known != null) {
        _xorInto(xor, known);
      } else if (_recoveredIndices.contains(idx)) {
        // Recovered but unreadable: treating it as unresolved would let
        // peeling "re-recover" it from a XOR that never had it removed,
        // silently corrupting the block. Drop the symbol instead — it is
        // pure redundancy, and the pool has 3x more.
        _seenSeqs.remove(seq);
        return const [];
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
      final symbol = _PendingSymbol(xor, unresolved);
      for (final idx in unresolved) {
        (_dependents[idx] ??= Set.identity()).add(symbol);
      }
      _pendingCount++;
      if (spill != null) {
        _resident.add(symbol);
        _evictIfNeeded();
      }
    }

    // Peeling can stall on a "stuck core" of mutually-overlapping symbols even
    // when the data is fully determined (common at small K). When this symbol
    // didn't let peeling advance yet enough independent equations exist to
    // possibly solve the residual, fall back to Gaussian elimination over
    // GF(2). Gating on a stalled peel keeps GE off the common fast path, and
    // peeling having shrunk the pool to the small core keeps it cheap. Above
    // maxEliminationMissingCount, GE's O(N^2)/O(N^3) cost is skipped entirely
    // — peeling alone must carry large-K transfers to avoid UI-thread stalls.
    if (newlyRecovered.isEmpty &&
        !isComplete &&
        _missingCount < maxEliminationMissingCount &&
        _pendingCount >= _missingCount) {
      _solveResidualByElimination(newlyRecovered);
    }

    return newlyRecovered;
  }

  /// Count of source blocks not yet recovered.
  int get _missingCount => k - _recoveredIndices.length;

  /// Records source block [index] = [bytes], then peels it (and any further
  /// singletons it exposes) out of every symbol that referenced it,
  /// recovering more blocks in cascade.
  ///
  /// Uses [_dependents] to reach only the symbols that actually reference the
  /// block. Scanning all of [_pending] per peel instead made the endgame
  /// quadratic: at K=70965 the decode burst slowed to 330 then 64 symbols/s,
  /// with single cascades blocking the isolate for 15-78 seconds (which reads
  /// as a frozen UI, since the camera keeps running independently).
  void _recoverAndCascade(
    int index,
    List<int> bytes,
    List<RecoveredBlock> out,
  ) {
    final queue = <MapEntry<int, List<int>>>[MapEntry(index, bytes)];

    while (queue.isNotEmpty) {
      final entry = queue.removeLast();
      final idx = entry.key;
      if (_recoveredIndices.contains(idx)) continue;

      final blockBytes = entry.value;
      _recoveredIndices.add(idx);
      _remember(idx, blockBytes);
      out.add(RecoveredBlock(idx, blockBytes));

      final dependents = _dependents.remove(idx);
      if (dependents == null) continue;

      for (final p in dependents) {
        // Already retired via another index in this same cascade.
        if (p.unresolved.isEmpty) continue;
        if (!p.unresolved.remove(idx)) continue;
        final buffer = _xorOf(p);
        _xorInto(buffer, blockBytes);

        if (p.unresolved.isEmpty) {
          _retire(p);
        } else if (p.unresolved.length == 1) {
          final last = p.unresolved.first;
          _retire(p);
          queue.add(MapEntry(last, buffer));
        }
      }
    }
  }

  /// Every still-unresolved symbol, deduplicated (a symbol is indexed under
  /// each of its unresolved indices, so it appears in several sets).
  Iterable<_PendingSymbol> _livePending() {
    final seen = Set<_PendingSymbol>.identity();
    for (final bucket in _dependents.values) {
      for (final p in bucket) {
        if (p.unresolved.isNotEmpty) seen.add(p);
      }
    }
    return seen;
  }

  /// Removes [p] from the pending pool and from every dependents list that
  /// still points at it. Marking it empty first lets the cascade skip it
  /// without a membership test.
  void _retire(_PendingSymbol p) {
    for (final idx in p.unresolved) {
      _dependents[idx]?.remove(p);
    }
    p.unresolved.clear();
    _pendingCount--;
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

  /// Attempts to solve the residual system of pending equations (each a set
  /// of unknown indices = an XOR payload) via Gaussian elimination over GF(2).
  /// On full rank it recovers every remaining block, clears the pool, and
  /// appends the recovered blocks to [out]; otherwise it leaves state untouched
  /// and waits for more symbols.
  void _solveResidualByElimination(List<RecoveredBlock> out) {
    final unknowns = _missingCount;

    // Forward elimination into row-echelon form, keyed by each row's smallest
    // (pivot) coefficient. Work on copies so a non-full-rank attempt is a no-op.
    final pivots = <int, _PendingSymbol>{};
    for (final p in _livePending()) {
      var coeffs = Set<int>.from(p.unresolved);
      var bytes = Uint8List.fromList(_xorOf(p));

      while (coeffs.isNotEmpty) {
        final pivot = coeffs.reduce((a, b) => a < b ? a : b);
        final existing = pivots[pivot];
        if (existing == null) {
          pivots[pivot] = _PendingSymbol(bytes, coeffs);
          break;
        }
        coeffs = _xorSets(coeffs, existing.unresolved);
        _xorInto(bytes, existing.xor!);
      }
    }

    if (pivots.length < unknowns) return; // not yet uniquely solvable

    // Back-substitution: solve pivots from the largest index down, so each
    // row's higher-index coefficients are already known when we reach it.
    final pivotIndicesDesc = pivots.keys.toList()..sort((a, b) => b - a);
    final solution = <int, List<int>>{};
    for (final pivot in pivotIndicesDesc) {
      final row = pivots[pivot]!;
      final bytes = Uint8List.fromList(row.xor!);
      for (final c in row.unresolved) {
        if (c == pivot) continue;
        final solved = solution[c];
        if (solved != null) _xorInto(bytes, solved);
      }
      solution[pivot] = bytes;
    }

    _dependents.clear();
    _pendingCount = 0;
    for (final entry in solution.entries) {
      if (_recoveredIndices.contains(entry.key)) continue;
      _recoveredIndices.add(entry.key);
      _remember(entry.key, entry.value);
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
      final block = _block(i);
      if (block == null) {
        throw StateError('Cannot assemble: block $i is recovered but unreadable');
      }
      out.addAll(block);
    }
    return out;
  }
}
