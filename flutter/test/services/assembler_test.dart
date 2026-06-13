import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/models/transfer.dart';
import 'package:porter_receiver/services/assembler.dart';

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
