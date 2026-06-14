import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/models/transfer.dart';
import 'package:porter_receiver/services/assembler.dart';
import 'package:porter_receiver/services/fountain_codec.dart';

/// Encodes [content] into `F|...` wire strings the way nodejs FountainChunker
/// does, for driving Assembler.ingest in fountain-mode tests.
List<String> _encodeFountain(List<int> content, int blockSize, int n, String id) {
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
  final out = <String>[];
  for (int seq = 0; seq < n; seq++) {
    final symbol = List<int>.filled(blockSize, 0);
    for (final idx in sampleIndices(seq, k, table).indices) {
      for (int b = 0; b < blockSize; b++) {
        symbol[b] ^= blocks[idx - 1][b];
      }
    }
    out.add('F|$seq|$k|${content.length}|$id|${base64.encode(symbol)}');
  }
  return out;
}

void main() {
  group('Assembler', () {
    test('assembles sequential text chunks and reports completion', () {
      Transfer? completed;
      final assembler = Assembler(onComplete: (t) => completed = t);

      expect(assembler.ingest('1|2|T|AB|Hello'), true);
      expect(assembler.transfers['AB']!.isComplete, false);

      expect(assembler.ingest('2|2|T|AB|World'), true);

      final t = assembler.transfers['AB']!;
      expect(t.isComplete, true);
      expect(t.assembled, utf8.encode('HelloWorld'));
      expect(completed?.id, 'AB');
    });

    test('onProgress fires for each new data chunk', () {
      final progressed = <int>[];
      final assembler = Assembler(onProgress: (t) => progressed.add(t.seenIndices.length));

      assembler.ingest('1|2|T|AB|Hello');
      assembler.ingest('2|2|T|AB|World');

      expect(progressed, [1, 2]);
    });

    test('verifies a matching checksum chunk after completion', () {
      final assembler = Assembler();
      assembler.ingest('1|2|T|AB|Hello');
      assembler.ingest('2|2|T|AB|World');

      final expectedSha = sha256.convert(utf8.encode('HelloWorld')).toString();
      assembler.ingest('CHECKSUM|T|AB|$expectedSha');

      final t = assembler.transfers['AB']!;
      expect(t.verified, true);
      expect(t.error, null);
    });

    test('flags a mismatched checksum and records an error', () {
      final assembler = Assembler();
      assembler.ingest('1|2|T|AB|Hello');
      assembler.ingest('2|2|T|AB|World');

      assembler.ingest(
        'CHECKSUM|T|AB|0000000000000000000000000000000000000000000000000000000000000000',
      );

      final t = assembler.transfers['AB']!;
      expect(t.verified, false);
      expect(t.error, contains('SHA-256 mismatch'));
    });

    test('ignores duplicate chunk indices', () {
      final assembler = Assembler();
      expect(assembler.ingest('1|2|T|AB|Hello'), true);
      expect(assembler.ingest('1|2|T|AB|Hello'), false);

      final t = assembler.transfers['AB']!;
      expect(t.seenIndices, {1});
      expect(t.chunks.length, 1);
    });

    test('decompresses gzip-mode payloads', () {
      final original = utf8.encode('Hello, gzip world! ' * 5);
      final compressed = GZipEncoder().encode(original)!;
      final payload = base64.encode(compressed);

      final assembler = Assembler();
      assembler.ingest('1|1|C|XY|$payload');

      final t = assembler.transfers['XY']!;
      expect(t.isComplete, true);
      expect(t.assembled, original);
    });

    test('reports chunk bytes and raw chunk data as they arrive', () {
      final byteCounts = <int>[];
      final received = <int, List<int>>{};

      final assembler = Assembler(onChunkBytes: (n) => byteCounts.add(n));
      assembler.onChunkReceived = (t, index, bytes) => received[index] = bytes;

      assembler.ingest('1|2|T|AB|Hello');
      assembler.ingest('2|2|T|AB|World');

      expect(byteCounts, [5, 5]);
      expect(received[1], utf8.encode('Hello'));
      expect(received[2], utf8.encode('World'));
    });

    test('assembles a fountain transfer and trims padding to the original size', () {
      final content = utf8.encode('Fountain assembly through the Assembler! ' * 4);
      const blockSize = 16;
      final k = (content.length / blockSize).ceil();
      final n = (k * 3).clamp(k + 20, 1 << 30);
      final chunks = _encodeFountain(content, blockSize, n, 'FN');
      final sha = sha256.convert(content).toString();

      Transfer? completed;
      final assembler = Assembler(onComplete: (t) => completed = t);
      for (final c in chunks) {
        assembler.ingest(c);
      }
      assembler.ingest('CHECKSUM|T|FN|$sha');

      final t = assembler.transfers['FN']!;
      expect(t.encoding, 'fountain');
      expect(t.mode, 'B');
      expect(t.total, k);
      expect(t.fountainFileSize, content.length);
      expect(t.isComplete, true);
      expect(t.assembled, content); // trimmed back from blockSize*k padding
      expect(t.verified, true);
      expect(completed?.id, 'FN');
    });

    test('fountain transfer recovers from a shuffled, lossy symbol stream', () {
      final content = utf8.encode('order-independent fountain recovery ' * 5);
      const blockSize = 16;
      final k = (content.length / blockSize).ceil();
      final n = (k * 3).clamp(k + 20, 1 << 30);
      final chunks = _encodeFountain(content, blockSize, n, 'LS');

      // Drop every 4th symbol, reverse the rest.
      final delivered = <String>[];
      for (int i = 0; i < chunks.length; i++) {
        if (i % 4 != 0) delivered.add(chunks[i]);
      }

      final assembler = Assembler();
      for (final c in delivered.reversed) {
        assembler.ingest(c);
      }

      final t = assembler.transfers['LS']!;
      expect(t.isComplete, true);
      expect(t.assembled, content);
    });

    test('ignores duplicate fountain seqs', () {
      final content = utf8.encode('dedupe fountain ' * 3);
      const blockSize = 16;
      final k = (content.length / blockSize).ceil();
      final n = (k * 3).clamp(k + 20, 1 << 30);
      final chunks = _encodeFountain(content, blockSize, n, 'DP');

      final assembler = Assembler();
      expect(assembler.ingest(chunks[0]), true);
      // Re-ingesting the same seq yields no new data.
      expect(assembler.ingest(chunks[0]), false);
    });

    test('fountain progress tracks distinct symbols and fires per new symbol', () {
      final content = utf8.encode('symbol progress counting ' * 8);
      const blockSize = 16;
      final k = (content.length / blockSize).ceil();
      final n = (k * 3).clamp(k + 20, 1 << 30);
      final chunks = _encodeFountain(content, blockSize, n, 'SP');

      var progressCalls = 0;
      final assembler = Assembler(onProgress: (_) => progressCalls++);

      // Feed the first few symbols; recovery may still be ~0, but symbol count
      // and progress callbacks must advance regardless.
      for (var i = 0; i < 5; i++) {
        assembler.ingest(chunks[i]);
      }

      final t = assembler.transfers['SP']!;
      expect(t.fountainSymbols, 5);
      expect(progressCalls, 5);
      // displayProgress reflects symbols/K, not the (still tiny) recovered count.
      expect(t.displayProgress, closeTo(5 / k, 1e-9));
    });

    test('decodes the nodejs cross-language fixture through ingest', () {
      final raw = File('test/fixtures/fountain_sample.json').readAsStringSync();
      final fixture = jsonDecode(raw) as Map<String, dynamic>;
      final expectedBytes = base64.decode(fixture['inputBase64'] as String);
      final chunkLines = (fixture['chunks'] as List).cast<String>();

      Transfer? completed;
      final assembler = Assembler(onComplete: (t) => completed = t);
      for (final line in chunkLines) {
        assembler.ingest(line);
      }

      final t = completed!;
      expect(t.encoding, 'fountain');
      expect(t.isComplete, true);
      expect(t.assembled, expectedBytes);
      expect(t.verified, true);
      expect(t.error, null);
    });

    test('reset(id) removes a single transfer, reset() clears all', () {
      final assembler = Assembler();
      assembler.ingest('1|2|T|AB|Hello');
      assembler.ingest('1|1|T|CD|Solo');

      assembler.reset('AB');
      expect(assembler.transfers.containsKey('AB'), false);
      expect(assembler.transfers.containsKey('CD'), true);

      assembler.reset();
      expect(assembler.transfers, isEmpty);
    });
  });
}
