import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/services/fountain_codec.dart';

void main() {
  group('FountainCodec PRNG', () {
    // These golden vectors must match nodejs/src/lib/fountain.test.ts exactly
    // -- encoder (TS) and decoder (Dart) derive (degree, indices) independently
    // from the same `seq`, so the PRNG sequences must be bit-for-bit identical.

    test('makeRng(0) produces the expected sequence', () {
      final rng = makeRng(0);
      final values = List.generate(5, (_) => rng());
      expect(values, [1359758873, 3761132862, 2075758394, 25405621, 3862129951]);
    });

    test('makeRng(1) produces the expected sequence', () {
      final rng = makeRng(1);
      final values = List.generate(5, (_) => rng());
      expect(values, [1359504952, 3827716927, 3866437631, 332804602, 1758100174]);
    });
  });

  group('buildDegreeTable', () {
    test('k=1 and k=2 force degree 1', () {
      final t1 = buildDegreeTable(1);
      expect(t1.cumWeights, [0, 1]);
      expect(t1.total, 1);

      final t2 = buildDegreeTable(2);
      expect(t2.cumWeights, [0, 1]);
      expect(t2.total, 1);
    });

    test('k=10 matches the golden table', () {
      final table = buildDegreeTable(10);
      expect(table.cumWeights, [0, 4, 10, 14, 15, 16, 17, 18, 19, 20, 21]);
      expect(table.total, 21);
    });

    test('k=100 matches the golden table', () {
      final table = buildDegreeTable(100);
      expect(table.total, 214);
      expect(table.cumWeights[1], 11);
      expect(table.cumWeights[2], 66);
      expect(table.cumWeights[3], 85);
      expect(table.cumWeights[10], 124);
      expect(table.cumWeights[100], 214);
    });
  });

  group('sampleIndices', () {
    test('k=10 matches the golden (degree, indices) pairs', () {
      expect(sampleIndices(0, 10).degree, 3);
      expect(sampleIndices(0, 10).indices, [2, 3, 5]);

      expect(sampleIndices(1, 10).degree, 1);
      expect(sampleIndices(1, 10).indices, [8]);

      expect(sampleIndices(2, 10).degree, 2);
      expect(sampleIndices(2, 10).indices, [1, 7]);

      expect(sampleIndices(3, 10).degree, 9);
      expect(sampleIndices(3, 10).indices, [1, 2, 3, 4, 5, 6, 7, 9, 10]);

      expect(sampleIndices(4, 10).degree, 2);
      expect(sampleIndices(4, 10).indices, [1, 3]);
    });

    test('k=1 always returns degree 1, index [1]', () {
      for (var seq = 0; seq < 3; seq++) {
        final s = sampleIndices(seq, 1);
        expect(s.degree, 1);
        expect(s.indices, [1]);
      }
    });
  });
}
