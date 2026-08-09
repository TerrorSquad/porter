import 'dart:async';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import '../models/chunk.dart';
import '../models/hydrated_transfer.dart';
import '../models/transfer.dart';
import 'chunk_parser.dart';
import 'fountain_decoder.dart';

/// K above which the pending symbol pool is spilled to disk instead of held
/// in RAM. At ~1.6 KB blocks, K=50000 is roughly a 80 MB file and a ~200 MB
/// resident pool — past that the fully-resident pool grows into GBs (measured
/// ~0.57 GB at 200k symbols for K=618429).
const int kSpillAboveK = 50000;

/// Chunk count above which received bytes are dropped from RAM once written
/// to disk. Below it the whole transfer is a few MB and keeping it resident
/// avoids paging it back at assembly time.
const int kEvictChunkBytesAboveTotal = 5000;

/// Consecutive symbols at a new (K, blockSize) before the receiver concludes
/// the sender really has switched layout — a terminal resize mid-transfer
/// makes porter recompute both. Small, because the old stream stops the
/// instant the sender redraws; >1 only guards against a stray decode of a
/// frame still on screen from the previous layout.
const int kLayoutSwitchThreshold = 3;

/// The (K, blockSize) a fountain transfer was started with. Symbols from a
/// stream with different values decode against different source blocks, so
/// they must not be mixed even though they share a chunk id.
class _FountainLayout {
  final int k;
  final int blockSize;
  const _FountainLayout(this.k, this.blockSize);
}

class Assembler {
  final Map<String, Transfer> transfers = {};

  /// Per-transfer peeling decoders for fountain ('F|...') transfers, keyed by
  /// transfer id. Created lazily on the first fountain chunk for an id.
  final Map<String, FountainDecoder> _fountainDecoders = {};

  /// Seqs restored from disk by [hydrate], waiting for the first post-resume
  /// symbol to reveal k/blockSize so a decoder can be built and seeded.
  /// Consumed (and cleared) on that first symbol.
  final Map<String, Set<int>> _pendingSeqRestores = {};

  /// Layout each fountain transfer was started with, keyed by chunk id.
  final Map<String, _FountainLayout> _fountainLayouts = {};

  /// Consecutive mismatched-layout symbols seen per chunk id, for deciding
  /// when a sender resize is real rather than a stray leftover frame.
  final Map<String, int> _layoutSwitchStreak = {};

  Function(Transfer)? onProgress;
  Function(Transfer)? onComplete;
  Function(int)? onChunkBytes;
  Function(Transfer, int, List<int>)? onChunkReceived;

  /// Fired for each newly-ingested fountain symbol seq, so the worker can
  /// persist it for resumption. Batched by the worker — one append per seq
  /// would be a syscall per scanned frame.
  Function(Transfer, int)? onFountainSeqSeen;

  /// Supplies a disk-backed spill for a large transfer's pending pool. Set by
  /// the worker (which knows the output directory); null in tests and small
  /// transfers, where the pool stays in RAM.
  SymbolSpill? Function(Transfer)? createSpill;

  /// Reads a persisted block synchronously for the decoder's peeling loop.
  /// Set by the worker (which owns the output directory); null in tests,
  /// where blocks stay in memory.
  List<int>? Function(Transfer, int)? readBlock;

  /// Fired when symbols arrive for a known chunk id but with an incompatible
  /// K — i.e. the same file re-sent at a different QR layout. The symbol is
  /// rejected; the UI should tell the user rather than let it look like a
  /// silently stalled transfer.
  Function(Transfer transfer, int existingK, int incomingK)? onLayoutConflict;

  /// Fired once the receiver accepts a sender's new layout and restarts the
  /// transfer against it. Progress under the old layout is discarded from
  /// memory (its chunk files stay on disk), so the UI should say so.
  Function(Transfer transfer, int oldK, int newK)? onLayoutSwitched;

  Assembler({this.onProgress, this.onComplete, this.onChunkBytes});

  /// Process a raw QR string. Returns true if new data was ingested.
  bool ingest(String raw) {
    final parsed = ChunkParser.parseQR(raw);
    if (parsed == null) return false;

    if (parsed is ChecksumChunk) {
      final transfer = getOrCreate(parsed.id, 0, 'T');
      if (transfer.checksum == parsed.checksum) return false;
      transfer.checksum = parsed.checksum;
      if (transfer.assembled != null) {
        _verifyChecksum(transfer);
      } else {
        _tryComplete(transfer);
      }
      return true;
    }

    if (parsed is FountainChunk) {
      final transfer = getOrCreate(parsed.id, parsed.k, 'B');
      if (transfer.isComplete) return false;

      // blockSize is not transmitted; every symbol payload is exactly one
      // (zero-padded) block, so the decoded length gives it directly.
      final symbol = base64.decode(parsed.payload);

      // The chunk id is a hash of the file's *content*, so re-sending the
      // same file at a different QR version (a resized terminal, a different
      // --ecc/--multi) produces the same id with a different K and block
      // size. Those streams are mutually undecodable: their symbols index
      // different source blocks entirely. Silently merging them corrupted a
      // real transfer — a directory ended up with 2883 blocks of 1617 bytes
      // and 995 of 2172, from two sessions hours apart.
      //
      // Identity is therefore (id, K, blockSize), not id alone. A mismatch
      // means a *different* transfer, so the incompatible symbol is rejected
      // rather than folded in. Recovering the older one is the user's call
      // (reset it, or move its directory aside).
      final layout = _fountainLayouts[parsed.id];
      if (layout != null &&
          (layout.k != parsed.k || layout.blockSize != symbol.length)) {
        // The sender switched layout — most often a terminal resize mid-run,
        // which makes porter recompute K and block size on the fly. Rejecting
        // forever would leave the user scanning into a void, so adopt the new
        // layout once it's clear the old stream is gone: a few stray frames
        // from the tail of the previous layout shouldn't discard progress,
        // but a sustained new stream should take over.
        //
        // Progress under the old layout stays on disk untouched; the new
        // stream starts its own decoder from zero, since no symbol from one
        // layout can contribute to the other.
        final pending = (_layoutSwitchStreak[parsed.id] ?? 0) + 1;
        _layoutSwitchStreak[parsed.id] = pending;
        if (pending < kLayoutSwitchThreshold) {
          onLayoutConflict?.call(transfer, layout.k, parsed.k);
          return false;
        }

        _fountainDecoders.remove(parsed.id);
        _pendingSeqRestores.remove(parsed.id);
        _layoutSwitchStreak.remove(parsed.id);
        transfer.reset();
        onLayoutSwitched?.call(transfer, layout.k, parsed.k);
      }
      _layoutSwitchStreak.remove(parsed.id);
      _fountainLayouts[parsed.id] = _FountainLayout(parsed.k, symbol.length);

      // First fountain chunk for this id configures the transfer. Fountain
      // payloads are always base64 binary blocks, so mode is 'B' (skips the
      // gzip path) and the assembled output is trimmed to fountainFileSize.
      transfer.encoding = 'fountain';
      transfer.mode = 'B';
      if (parsed.k > transfer.total) transfer.total = parsed.k;
      transfer.fountainFileSize = parsed.fileSize;
      var decoder = _fountainDecoders[parsed.id];
      if (decoder == null) {
        // Spill the pending pool for transfers big enough that holding it in
        // RAM is a real risk. Below the threshold the in-RAM path is used
        // unchanged — no file, no syscalls on the hot loop.
        decoder = FountainDecoder(
          k: parsed.k,
          blockSize: symbol.length,
          spill: parsed.k >= kSpillAboveK ? createSpill?.call(transfer) : null,
          // Recovered blocks are written to disk and dropped from RAM, and a
          // resumed transfer starts with all of them on disk only. This is
          // how peeling reaches them.
          blockLoader: (index) =>
              transfer.chunks[index] ?? readBlock?.call(transfer, index),
        );
        _fountainDecoders[parsed.id] = decoder;

        // First symbol after a resume: k/blockSize are known now, so seed the
        // decoder with what disk already holds. Blocks are credited from the
        // in-RAM map when present; a resumed transfer's bytes are read lazily
        // (chunkReader) and not awaited here — ingest is synchronous, and a
        // missing block just means that seq gets rescanned.
        // Credit the blocks already on disk. `transfer.chunks` is empty after
        // a hydrate (indices are marked seen, bytes read lazily), so passing
        // it alone would restart peeling from zero and the persisted blocks
        // could never contribute — they'd have to be re-derived from symbols
        // that will never arrive, and the transfer could not complete.
        // `blockLoader` pages them in on demand instead, straight from the
        // chunk files.
        final restore = _pendingSeqRestores.remove(parsed.id);
        if (restore != null || transfer.seenIndices.isNotEmpty) {
          decoder.restoreSeenSeqs(
            restore ?? const <int>{},
            transfer.chunks,
            recoveredIndices: transfer.seenIndices,
          );
        }
      }

      // A new symbol is useful even if it doesn't immediately peel a block —
      // the decoder retains it toward future recovery. Only a duplicate seq is
      // a true no-op.
      if (decoder.hasSeq(parsed.seq)) return false;

      final recovered = decoder.addSymbol(parsed.seq, symbol);
      transfer.fountainSymbols = decoder.symbolCount;
      onFountainSeqSeen?.call(transfer, parsed.seq);
      for (final block in recovered) {
        transfer.addChunk(block.index, block.bytes);
        onChunkBytes?.call(block.bytes.length);
        onChunkReceived?.call(transfer, block.index, block.bytes);
      }

      // Fire progress on every new symbol (not just on recovery): symbol count
      // is the meaningful progress signal, since blocks arrive in a late burst.
      onProgress?.call(transfer);
      if (recovered.isNotEmpty) _tryComplete(transfer);
      return true;
    }

    if (parsed is DataChunk) {
      final transfer = getOrCreate(parsed.id, parsed.total, parsed.mode);
      if (parsed.total > transfer.total) transfer.total = parsed.total;
      if (transfer.isComplete) return false;
      if (transfer.seenIndices.contains(parsed.index)) {
        // Still a no-op for state, but tells the UI which transfer is
        // actively being scanned — otherwise a resumed transfer whose next
        // few scans all happen to be already-hydrated chunks would never
        // surface as the active transfer until a genuinely new chunk lands.
        onProgress?.call(transfer);
        return false;
      }

      final payload = _decodePayload(parsed.mode, parsed.payload);
      transfer.addChunk(parsed.index, payload);
      transfer.mode = parsed.mode;
      onChunkBytes?.call(payload.length);
      onChunkReceived?.call(transfer, parsed.index, payload);

      onProgress?.call(transfer);
      _tryComplete(transfer);
      return true;
    }

    return false;
  }

  Transfer getOrCreate(String id, int total, String mode) {
    return transfers.putIfAbsent(
      id,
      () => Transfer(id: id),
    );
  }

  /// Rebuilds transfer state from previously-persisted chunks (see
  /// `ChunkStorage.hydrateAll`), without re-running `ingest` for each chunk.
  ///
  /// Deliberately cheap: only marks indices as seen (from `.bin` filenames
  /// already scanned by `ChunkStorage.hydrateAll`) rather than loading every
  /// chunk's bytes into memory up front — a resumed transfer can have tens
  /// of thousands of chunks, and reading them all eagerly for every
  /// resumable transfer at once is expensive enough to destabilize the
  /// isolate. `h.readChunk` is wired up as the transfer's lazy byte source,
  /// used only if/when this transfer is actually assembled.
  ///
  /// For fountain transfers the seen-seq set is restored too (persisted by
  /// `ChunkStorage.appendSeenSeqs`), so a resumed transfer skips symbols whose
  /// blocks are already on disk instead of rescanning the whole pool. The
  /// *pending* pool is deliberately not persisted — it is one blockSize buffer
  /// per unpeeled symbol, larger than the file itself, so writing it would
  /// cost more than rescanning. Consequently only seqs whose covered blocks
  /// are all recovered are safely skippable; `restoreSeenSeqs` drops the rest
  /// so their contribution isn't silently lost. Worst case is redundantly
  /// re-scanning some symbols, never a correctness loss — final SHA-256
  /// verification still gates completion.
  Future<void> hydrate(List<HydratedTransfer> hydrated) async {
    for (final h in hydrated) {
      final transfer = getOrCreate(h.id, h.total, h.mode);
      transfer.mode = h.mode;
      transfer.encoding = h.encoding;
      transfer.total = h.total;
      transfer.fountainFileSize = h.fountainFileSize;
      transfer.checksum = h.checksum;
      transfer.transferDirPath = h.transferDirPath;
      if (h.createdAt != null) transfer.createdAt = h.createdAt!;
      transfer.chunkReader = h.readChunk;
      for (final index in h.seenIndices) {
        transfer.markSeen(index);
      }

      // Fountain: rebuild a decoder seeded with the blocks already on disk so
      // resumed scanning peels against them instead of starting from zero.
      // Needs k and blockSize, which are only known once a symbol has been
      // seen — so this is deferred to the first post-resume symbol (see
      // ingest), where h.seenSeqs is replayed into the fresh decoder.
      if (h.encoding == 'fountain') {
        if (h.seenSeqs.isNotEmpty) _pendingSeqRestores[h.id] = h.seenSeqs;
        // Lock in the layout this transfer was recorded with, so symbols from
        // a re-send at a different QR version are rejected instead of being
        // merged into the chunks already on disk. blockSize comes from the
        // persisted chunk files, which are exactly one block each.
        if (h.total > 0 && h.blockSize != null) {
          _fountainLayouts[h.id] = _FountainLayout(h.total, h.blockSize!);
        }
      }

      onProgress?.call(transfer);
      if (transfer.isComplete) {
        transfer.completedAt = DateTime.now();
        await _assemble(transfer);
      }
    }
  }

  void reset([String? id]) {
    if (id != null) {
      transfers.remove(id);
      _fountainDecoders.remove(id);
      _pendingSeqRestores.remove(id);
      _fountainLayouts.remove(id);
      _layoutSwitchStreak.remove(id);
    } else {
      transfers.clear();
      _fountainDecoders.clear();
      _pendingSeqRestores.clear();
      _fountainLayouts.clear();
      _layoutSwitchStreak.clear();
    }
  }

  void _tryComplete(Transfer t) {
    if (!t.isComplete) return;

    // Fountain's wire format always sends a trailing CHECKSUM frame
    // (fountain.ts always appends one, unconditionally — unlike sequential
    // mode, where it's optional per --verify). The final data-carrying
    // symbol can complete every block before that checksum frame has been
    // ingested, since ordering between "last block recovered" and "checksum
    // received" isn't guaranteed. Firing onComplete here would send a
    // premature TransferCompletedEvent with verified still null, and then a
    // second, verified one once the checksum lands — a real double-fire
    // bug (onTransferComplete can trigger auto-save, so this risked saving
    // twice). Wait for the checksum instead: the ChecksumChunk branch in
    // ingest() calls _tryComplete again once it arrives, which is a no-op
    // here until then and completes normally once it does.
    if (t.encoding == 'fountain' && t.checksum == null) return;

    t.completedAt = DateTime.now();
    // The live-ingest path always has every chunk's bytes already in
    // memory (see ingest()), so this never actually awaits — fire-and
    // -forget keeps _tryComplete/ingest synchronous for existing callers.
    unawaited(_assemble(t));
  }

  Future<void> _assemble(Transfer t) async {
    // Blocks concurrent eviction: this walk awaits per chunk, so a pending
    // disk write completing mid-loop could otherwise drop a chunk we already
    // passed. See Transfer.evictChunkBytes.
    t.assembling = true;
    try {
      final parts = <List<int>>[];
      for (int i = 1; i <= t.total; i++) {
        final chunk = t.chunks[i] ?? await t.chunkReader?.call(i);
        if (chunk == null) throw Exception('Missing chunk $i');
        parts.add(chunk);
      }

      List<int> assembled = [];
      for (final part in parts) {
        assembled.addAll(part);
      }

      if (t.mode == 'C') {
        // Gzip decompression
        assembled = GZipDecoder().decodeBytes(assembled);
      }

      if (t.encoding == 'fountain' && t.fountainFileSize != null) {
        // The final source block is zero-padded; trim back to the real size.
        assembled = assembled.sublist(0, t.fountainFileSize!);
      }

      t.assembled = assembled;
      _verifyChecksum(t);
    } catch (e) {
      t.error = 'Assembly failed: $e';
      onComplete?.call(t);
    } finally {
      t.assembling = false;
    }
  }

  void _verifyChecksum(Transfer t) {
    if (t.assembled == null || t.checksum == null) {
      onComplete?.call(t);
      return;
    }

    try {
      final actual = sha256.convert(t.assembled!).toString();
      t.verified = actual.toLowerCase() == t.checksum!.toLowerCase();
      if (!t.verified!) {
        t.error = 'SHA-256 mismatch: expected ${t.checksum}, got $actual';
      }
    } catch (e) {
      t.error = 'Checksum verification failed: $e';
    }

    onComplete?.call(t);
  }

  List<int> _decodePayload(String mode, String payload) {
    if (mode == 'T') {
      return utf8.encode(payload);
    }
    // B and C: base64-encoded
    return base64.decode(payload);
  }
}
