import 'dart:convert';
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
}
