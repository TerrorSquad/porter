import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/services/fountain_codec.dart';
import 'package:porter_receiver/services/fountain_decoder.dart';

/// Locally re-encodes [content] into a fountain symbol pool the same way
/// nodejs's FountainChunker does, so decoder tests don't depend on hand-picked
/// vectors. (Cross-language correctness is covered separately by the fixture
/// test below.)
List<MapEntry<int, List<int>>> _encode(List<int> content, int blockSize, int n) {
  final k = (content.length / blockSize).ceil();
  final blocks = <List<int>>[];
  for (int i = 0; i < k; i++) {
    final block = List<int>.filled(blockSize, 0);
    final start = i * blockSize;
    for (int b = 0; b < blockSize && start + b < content.length; b++) {
      block[b] = content[start + b];
    }
    blocks.add(block);
  }

  final table = buildDegreeTable(k);
  final symbols = <MapEntry<int, List<int>>>[];
  for (int seq = 0; seq < n; seq++) {
    final symbol = List<int>.filled(blockSize, 0);
    for (final idx in sampleIndices(seq, k, table).indices) {
      final block = blocks[idx - 1];
      for (int b = 0; b < blockSize; b++) {
        symbol[b] ^= block[b];
      }
    }
    symbols.add(MapEntry(seq, symbol));
  }
  return symbols;
}

void main() {
  group('FountainDecoder', () {
    test('recovers all blocks from a full in-order pool', () {
      final content = utf8.encode('The quick brown fox jumps over the lazy dog. ' * 8);
      const blockSize = 16;
      final k = (content.length / blockSize).ceil();
      final n = (k * 3).clamp(k + 20, 1 << 30);
      final symbols = _encode(content, blockSize, n);

      final decoder = FountainDecoder(k: k, blockSize: blockSize);
      for (final s in symbols) {
        decoder.addSymbol(s.key, s.value);
        if (decoder.isComplete) break;
      }

      expect(decoder.isComplete, true);
      final assembled = decoder.assemble().sublist(0, content.length);
      expect(assembled, content);
    });

    test('recovers all blocks when symbols arrive shuffled and with gaps', () {
      final content = utf8.encode('Fountain decoding should be order-independent! ' * 6);
      const blockSize = 16;
      final k = (content.length / blockSize).ceil();
      final n = (k * 3).clamp(k + 20, 1 << 30);
      final symbols = _encode(content, blockSize, n);

      // Drop every 5th symbol and reverse the rest to simulate lossy, unordered
      // scanning.
      final delivered = <MapEntry<int, List<int>>>[];
      for (int i = 0; i < symbols.length; i++) {
        if (i % 5 != 0) delivered.add(symbols[i]);
      }
      final shuffled = delivered.reversed.toList();

      final decoder = FountainDecoder(k: k, blockSize: blockSize);
      for (final s in shuffled) {
        decoder.addSymbol(s.key, s.value);
      }

      expect(decoder.isComplete, true);
      final assembled = decoder.assemble().sublist(0, content.length);
      expect(assembled, content);
    });

    test('newly-recovered blocks are reported as symbols are peeled', () {
      final content = utf8.encode('cascade test payload bytes here ' * 4);
      const blockSize = 16;
      final k = (content.length / blockSize).ceil();
      final n = (k * 3).clamp(k + 20, 1 << 30);
      final symbols = _encode(content, blockSize, n);

      final decoder = FountainDecoder(k: k, blockSize: blockSize);
      final reportedIndices = <int>{};
      for (final s in symbols) {
        for (final block in decoder.addSymbol(s.key, s.value)) {
          // Each index is reported exactly once.
          expect(reportedIndices.add(block.index), true);
        }
        if (decoder.isComplete) break;
      }

      expect(reportedIndices, {for (var i = 1; i <= k; i++) i});
    });

    test('ignores duplicate seqs and extra symbols after completion', () {
      final content = utf8.encode('dedupe me ' * 4);
      const blockSize = 16;
      final k = (content.length / blockSize).ceil();
      final n = (k * 3).clamp(k + 20, 1 << 30);
      final symbols = _encode(content, blockSize, n);

      final decoder = FountainDecoder(k: k, blockSize: blockSize);
      for (final s in symbols) {
        decoder.addSymbol(s.key, s.value);
      }
      expect(decoder.isComplete, true);

      // Re-feeding everything recovers nothing new.
      for (final s in symbols) {
        expect(decoder.addSymbol(s.key, s.value), isEmpty);
      }
    });

    test('completes via Gaussian-elimination fallback when peeling stalls (k=11)', () {
      // k=11 at N=3K is a known case where pure peeling stalls on a stuck core
      // even with the full, in-order pool; the GE fallback must finish it.
      final content = List<int>.generate(164, (i) => (i * 37 + 11) & 0xff);
      const blockSize = 16;
      final k = (content.length / blockSize).ceil();
      expect(k, 11);
      final n = (k * 3).clamp(k + 20, 1 << 30);
      final symbols = _encode(content, blockSize, n);

      final decoder = FountainDecoder(k: k, blockSize: blockSize);
      for (final s in symbols) {
        decoder.addSymbol(s.key, s.value);
      }

      expect(decoder.isComplete, true);
      expect(decoder.assemble().sublist(0, content.length), content);
    });

    test('skips Gaussian elimination above maxEliminationMissingCount, staying stalled', () {
      // A minimal-redundancy prefix (k=12, only 15 of the usual ~3K symbols)
      // that pure peeling cannot resolve on its own — the default decoder
      // needs GE to finish it (proven by the control assertion below). With
      // the elimination cap lowered under the stall's missing-block count,
      // GE must never fire, so the decoder stays incomplete.
      final content = List<int>.generate(180, (i) => (i * 37 + 25) & 0xff);
      const blockSize = 16;
      final k = (content.length / blockSize).ceil();
      expect(k, 12);
      final symbols = _encode(content, blockSize, k * 3).sublist(0, 15);

      final withGE = FountainDecoder(k: k, blockSize: blockSize);
      for (final s in symbols) {
        withGE.addSymbol(s.key, s.value);
      }
      expect(withGE.isComplete, true); // control: GE is genuinely load-bearing here

      final capped = FountainDecoder(k: k, blockSize: blockSize, maxEliminationMissingCount: 2);
      for (final s in symbols) {
        capped.addSymbol(s.key, s.value);
      }
      expect(capped.isComplete, false);
    });

    test('k=1 recovers from a single degree-1 symbol', () {
      final content = utf8.encode('tiny');
      const blockSize = 16;
      final symbols = _encode(content, blockSize, 21);

      final decoder = FountainDecoder(k: 1, blockSize: blockSize);
      decoder.addSymbol(symbols.first.key, symbols.first.value);

      expect(decoder.isComplete, true);
      expect(decoder.assemble().sublist(0, content.length), content);
    });
  });

  group('FountainDecoder cross-language fixture', () {
    test('decodes a nodejs-encoded stream to the exact original bytes', () {
      // Generated by nodejs FountainChunker (see fountain.test.ts). Proves the
      // Dart PRNG/degree table/peeling decoder agree with the TS encoder.
      final raw = File('test/fixtures/fountain_sample.json').readAsStringSync();
      final fixture = jsonDecode(raw) as Map<String, dynamic>;

      final k = fixture['k'] as int;
      final blockSize = fixture['blockSize'] as int;
      final fileSize = fixture['fileSize'] as int;
      final expectedBytes = base64.decode(fixture['inputBase64'] as String);
      final expectedSha = fixture['sha256'] as String;
      final chunks = (fixture['chunks'] as List).cast<String>();

      final decoder = FountainDecoder(k: k, blockSize: blockSize);
      String? checksum;
      for (final line in chunks) {
        if (line.startsWith('CHECKSUM|')) {
          checksum = line.split('|')[3];
          continue;
        }
        final parts = line.split('|');
        final seq = int.parse(parts[1]);
        final payload = base64.decode(parts.sublist(5).join('|'));
        decoder.addSymbol(seq, payload);
      }

      expect(decoder.isComplete, true);
      final assembled = decoder.assemble().sublist(0, fileSize);
      expect(assembled, expectedBytes);

      final actualSha = sha256.convert(assembled).toString();
      expect(actualSha, expectedSha);
      expect(actualSha, checksum);
    });
  });

  group('large-K behaviour', () {
    /// The receiver holds one blockSize buffer per pending symbol. Boxed
    /// `List<int>` costs ~8 bytes per byte in the Dart VM, so at tens of
    /// thousands of pending symbols that pool was the receiver's dominant
    /// allocation (measured 158 MB vs 56 MB at K=20000). Pending buffers must
    /// stay typed; this guards the decode path that produces them.
    test('decodes exactly at a K large enough to stress the pending pool', () {
      const k = 3000;
      const blockSize = 61;
      final table = buildDegreeTable(k);
      final source = List.generate(k, (i) {
        final b = Uint8List(blockSize);
        for (var x = 0; x < blockSize; x++) {
          b[x] = (i * 31 + x * 7) & 0xff;
        }
        return b;
      });

      final decoder = FountainDecoder(k: k, blockSize: blockSize);
      var seq = 0;
      while (!decoder.isComplete && seq < k * 5) {
        final sampled = sampleIndices(seq, k, table);
        final symbol = Uint8List(blockSize);
        for (final i in sampled.indices) {
          final block = source[i - 1];
          for (var x = 0; x < blockSize; x++) {
            symbol[x] ^= block[x];
          }
        }
        decoder.addSymbol(seq, symbol);
        seq++;
      }

      expect(decoder.isComplete, true,
          reason: 'peeling stalled after $seq symbols for K=$k');
      expect(decoder.assemble(), [for (final b in source) ...b]);
    });
  });

  group('resumption', () {
    /// A restart loses the pending pool but keeps recovered blocks on disk.
    /// Replaying the persisted seq set must (a) skip symbols that are pure
    /// duplicates of recovered data, and (b) NOT skip symbols whose only
    /// contribution was to the lost pending pool — marking those seen would
    /// drop them permanently and could stall the decode.
    test('restoreSeenSeqs skips only fully-recovered seqs, and still decodes',
        () {
      const k = 200;
      const blockSize = 32;
      final table = buildDegreeTable(k);
      final source = List.generate(k, (i) {
        final b = Uint8List(blockSize);
        for (var x = 0; x < blockSize; x++) {
          b[x] = (i * 17 + x * 3) & 0xff;
        }
        return b;
      });
      Uint8List symbolFor(int seq) {
        final out = Uint8List(blockSize);
        for (final i in sampleIndices(seq, k, table).indices) {
          final b = source[i - 1];
          for (var x = 0; x < blockSize; x++) {
            out[x] ^= b[x];
          }
        }
        return out;
      }

      // Session 1: partial progress, then "crash".
      final first = FountainDecoder(k: k, blockSize: blockSize);
      var seq = 0;
      while (seq < 120) {
        first.addSymbol(seq, symbolFor(seq));
        seq++;
      }
      expect(first.isComplete, false, reason: 'need a partial state to resume');
      final persistedSeqs = first.seenSeqs.toList();
      final onDisk = {
        for (var i = 1; i <= k; i++)
          if (!first.missingIndices.contains(i)) i: source[i - 1],
      };
      expect(onDisk, isNotEmpty, reason: 'need recovered blocks to resume from');

      // Session 2: fresh decoder seeded from what survived.
      final resumed = FountainDecoder(k: k, blockSize: blockSize)
        ..restoreSeenSeqs(persistedSeqs, onDisk);
      expect(resumed.recoveredCount, onDisk.length);
      expect(resumed.symbolCount, lessThan(persistedSeqs.length),
          reason: 'seqs covering unrecovered blocks must be rescannable');

      // Continuing the scan must still reach a byte-exact result.
      while (!resumed.isComplete && seq < k * 6) {
        resumed.addSymbol(seq, symbolFor(seq));
        seq++;
      }
      expect(resumed.isComplete, true, reason: 'resumed decode stalled');
      expect(resumed.assemble(), [for (final b in source) ...b]);
    });
  });

  group('endgame performance', () {
    /// The decode burst used to be quadratic: every peel rescanned the whole
    /// pending pool, so at K=70965 throughput collapsed from ~190k symbols/s
    /// to 64/s, with single cascades blocking the isolate for 15-78 seconds.
    /// A reverse index (block -> dependent symbols) makes each peel touch only
    /// the affected symbols. Guards the complexity, not a wall-clock target:
    /// the bound is generous enough not to flake on slow CI.
    test('completes a large-K decode without a quadratic blowup', () {
      const k = 30000;
      const blockSize = 16;
      final table = buildDegreeTable(k);
      final source = List.generate(k, (i) {
        final b = Uint8List(blockSize);
        for (var x = 0; x < blockSize; x++) {
          b[x] = (i + x) & 0xff;
        }
        return b;
      });

      final decoder = FountainDecoder(k: k, blockSize: blockSize);
      final sw = Stopwatch()..start();
      var seq = 0;
      while (!decoder.isComplete && seq < k * 4) {
        final symbol = Uint8List(blockSize);
        for (final i in sampleIndices(seq, k, table).indices) {
          final block = source[i - 1];
          for (var x = 0; x < blockSize; x++) {
            symbol[x] ^= block[x];
          }
        }
        decoder.addSymbol(seq, symbol);
        seq++;
      }
      sw.stop();

      expect(decoder.isComplete, true, reason: 'decode stalled at seq $seq');
      expect(decoder.assemble(), [for (final b in source) ...b]);
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)),
          reason: 'K=$k took ${sw.elapsedMilliseconds}ms — endgame looks '
              'quadratic again');
    });
  });

  group('spilling to disk', () {
    /// The pending pool is the receiver's dominant allocation and grows with
    /// K: projected ~2.6 GB for a 1 GB file, which OOMs a phone. Spilling
    /// bounds it. Correctness must be identical to the in-RAM path, so this
    /// runs with a tiny resident cap to force constant eviction and page-in.
    test('decodes byte-exactly with almost everything evicted', () async {
      const k = 400;
      const blockSize = 24;
      final dir = await Directory.systemTemp.createTemp('porter_spill');
      addTearDown(() => dir.delete(recursive: true));

      final table = buildDegreeTable(k);
      final source = List.generate(k, (i) {
        final b = Uint8List(blockSize);
        for (var x = 0; x < blockSize; x++) {
          b[x] = (i * 13 + x * 5) & 0xff;
        }
        return b;
      });

      final spill = FileSymbolSpill(File('${dir.path}/pending.bin'));
      addTearDown(spill.dispose);

      final decoder = FountainDecoder(
        k: k,
        blockSize: blockSize,
        spill: spill,
        maxResidentSymbols: 8, // force near-total eviction
      );

      var seq = 0;
      while (!decoder.isComplete && seq < k * 6) {
        final symbol = Uint8List(blockSize);
        for (final i in sampleIndices(seq, k, table).indices) {
          final block = source[i - 1];
          for (var x = 0; x < blockSize; x++) {
            symbol[x] ^= block[x];
          }
        }
        decoder.addSymbol(seq, symbol);
        seq++;
      }

      expect(decoder.isComplete, true, reason: 'spilled decode stalled');
      expect(decoder.assemble(), [for (final b in source) ...b]);
    });

    test('matches the in-RAM decoder exactly, symbol for symbol', () async {
      const k = 300;
      const blockSize = 16;
      final dir = await Directory.systemTemp.createTemp('porter_spill_cmp');
      addTearDown(() => dir.delete(recursive: true));

      final table = buildDegreeTable(k);
      final source = List.generate(k, (i) {
        final b = Uint8List(blockSize);
        for (var x = 0; x < blockSize; x++) {
          b[x] = (i ^ x) & 0xff;
        }
        return b;
      });
      Uint8List symbolFor(int seq) {
        final out = Uint8List(blockSize);
        for (final i in sampleIndices(seq, k, table).indices) {
          final block = source[i - 1];
          for (var x = 0; x < blockSize; x++) {
            out[x] ^= block[x];
          }
        }
        return out;
      }

      final spill = FileSymbolSpill(File('${dir.path}/pending.bin'));
      addTearDown(spill.dispose);
      final spilled = FountainDecoder(
        k: k,
        blockSize: blockSize,
        spill: spill,
        maxResidentSymbols: 4,
      );
      final inRam = FountainDecoder(k: k, blockSize: blockSize);

      for (var seq = 0; seq < k * 3; seq++) {
        final symbol = symbolFor(seq);
        final a = spilled.addSymbol(seq, Uint8List.fromList(symbol));
        final b = inRam.addSymbol(seq, Uint8List.fromList(symbol));
        expect(a.map((r) => r.index).toSet(), b.map((r) => r.index).toSet(),
            reason: 'divergence at seq $seq');
        if (inRam.isComplete) break;
      }

      expect(spilled.isComplete, inRam.isComplete);
      expect(spilled.assemble(), inRam.assemble());
    });
  });

  group('resuming against blocks that live only on disk', () {
    /// After a hydrate, `transfer.chunks` is empty — indices are marked seen
    /// and bytes are read lazily. Seeding the decoder from that empty map
    /// left it with zero recovered blocks, so the blocks already on disk
    /// could never contribute and the transfer could not finish. Indices must
    /// be credited directly, with blockLoader paging the bytes in.
    test('credits disk-only indices and completes', () {
      const k = 200;
      const blockSize = 24;
      final table = buildDegreeTable(k);
      final source = List.generate(k, (i) {
        final b = Uint8List(blockSize);
        for (var x = 0; x < blockSize; x++) {
          b[x] = (i * 7 + x) & 0xff;
        }
        return b;
      });
      Uint8List symbolFor(int seq) {
        final out = Uint8List(blockSize);
        for (final i in sampleIndices(seq, k, table).indices) {
          final b = source[i - 1];
          for (var x = 0; x < blockSize; x++) {
            out[x] ^= b[x];
          }
        }
        return out;
      }

      // Pretend the first 120 blocks were recovered in an earlier session and
      // exist only on disk.
      final onDisk = {for (var i = 1; i <= 120; i++) i: source[i - 1]};
      var loads = 0;

      final resumed = FountainDecoder(
        k: k,
        blockSize: blockSize,
        blockLoader: (index) {
          loads++;
          return onDisk[index];
        },
      )..restoreSeenSeqs(
          const <int>[],
          const {}, // nothing in RAM, exactly like a fresh hydrate
          recoveredIndices: onDisk.keys,
        );

      expect(resumed.recoveredCount, 120,
          reason: 'disk-only blocks must count as recovered');

      var seq = 0;
      while (!resumed.isComplete && seq < k * 6) {
        resumed.addSymbol(seq, symbolFor(seq));
        seq++;
      }

      expect(resumed.isComplete, true, reason: 'resumed decode stalled');
      expect(loads, greaterThan(0), reason: 'blockLoader should be used');
      expect(resumed.assemble(), [for (final b in source) ...b]);
    });
  });
}
