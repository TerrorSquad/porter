import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/services/chunk_parser.dart';
import 'package:porter_receiver/models/chunk.dart';

void main() {
  group('ChunkParser', () {
    test('parses valid data chunk', () {
      final result = ChunkParser.parseQR('0|2|T|AB|Hello');
      expect(result, isA<DataChunk>());
      final chunk = result as DataChunk;
      expect(chunk.index, 0);
      expect(chunk.total, 2);
      expect(chunk.mode, 'T');
      expect(chunk.id, 'AB');
      expect(chunk.payload, 'Hello');
    });

    test('handles payload with pipe characters', () {
      final result = ChunkParser.parseQR('0|1|T|AB|Hello|World|!');
      expect(result, isA<DataChunk>());
      final chunk = result as DataChunk;
      expect(chunk.payload, 'Hello|World|!');
    });

    test('parses fountain chunk', () {
      final result = ChunkParser.parseQR('F|7|8|122|Or|aXMgaXMgYSB0ZXN0IG9mIA==');
      expect(result, isA<FountainChunk>());
      final chunk = result as FountainChunk;
      expect(chunk.seq, 7);
      expect(chunk.k, 8);
      expect(chunk.fileSize, 122);
      expect(chunk.id, 'Or');
      expect(chunk.payload, 'aXMgaXMgYSB0ZXN0IG9mIA==');
    });

    test('does not mistake a data chunk for a fountain chunk', () {
      // Sequential chunks never start with "F|"; index field is numeric.
      final result = ChunkParser.parseQR('0|2|T|AB|Hello');
      expect(result, isA<DataChunk>());
    });

    test('parses checksum chunk', () {
      final result = ChunkParser.parseQR('CHECKSUM|T|AB|abc123def456');
      expect(result, isA<ChecksumChunk>());
      final chunk = result as ChecksumChunk;
      expect(chunk.id, 'AB');
      expect(chunk.checksum, 'abc123def456');
    });

    test('returns null for invalid format', () {
      expect(ChunkParser.parseQR('invalid'), null);
      expect(ChunkParser.parseQR(''), null);
      expect(ChunkParser.parseQR('0|1'), null);
    });

    test('trims whitespace', () {
      final result = ChunkParser.parseQR('  0|2|T|AB|Hello  ');
      expect(result, isA<DataChunk>());
    });
  });
}
