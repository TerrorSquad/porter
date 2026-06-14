import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/models/transfer.dart';

void main() {
  group('Transfer', () {
    test('initializes with default values', () {
      final t = Transfer(id: 'AB');
      expect(t.id, 'AB');
      expect(t.total, 0);
      expect(t.mode, 'T');
      expect(t.isComplete, false);
      expect(t.progress, 0);
    });

    test('tracks chunk additions', () {
      final t = Transfer(id: 'AB');
      t.total = 3;
      t.addChunk(1, [1, 2, 3]);
      expect(t.seenIndices.length, 1);
      expect(t.chunks.containsKey(1), true);
      expect(t.progress, 33);
    });

    test('deduplicates chunks', () {
      final t = Transfer(id: 'AB');
      t.total = 2;
      t.addChunk(1, [1, 2]);
      t.addChunk(1, [3, 4]); // duplicate
      expect(t.seenIndices.length, 1);
      expect(t.chunks[1], [1, 2]); // original unchanged
    });

    test('marks complete when all chunks received', () {
      final t = Transfer(id: 'AB');
      t.total = 2;
      t.addChunk(1, [1]);
      expect(t.isComplete, false);
      t.addChunk(2, [2]);
      expect(t.isComplete, true);
      expect(t.progress, 100);
    });

    test('resets to initial state', () {
      final t = Transfer(id: 'AB');
      t.total = 3;
      t.addChunk(1, [1, 2, 3]);
      t.error = 'test error';
      t.encoding = 'fountain';
      t.fountainSymbols = 5;
      t.reset();
      expect(t.total, 0);
      expect(t.chunks.isEmpty, true);
      expect(t.error, null);
      expect(t.encoding, 'sequential');
      expect(t.fountainSymbols, 0);
    });

    test('sequential displayProgress and label track recovered chunks', () {
      final t = Transfer(id: 'AB')..total = 4;
      t.addChunk(1, [1]);
      expect(t.displayProgress, closeTo(0.25, 1e-9));
      expect(t.progressLabel, '1 / 4 chunks');
    });

    test('fountain displayProgress tracks symbols, not recovered blocks', () {
      final t = Transfer(id: 'CD')
        ..encoding = 'fountain'
        ..total = 100
        ..fountainSymbols = 40;
      t.addChunk(1, [1]); // only 1 block recovered so far

      // Sequential progress would show ~1%; fountain shows ~40% (symbols/K).
      expect(t.displayProgress, closeTo(0.40, 1e-9));
      expect(t.progressLabel, '40 symbols · 1 / 100 blocks');
    });

    test('fountain displayProgress caps below 1.0 until actually complete', () {
      final t = Transfer(id: 'EF')
        ..encoding = 'fountain'
        ..total = 10
        ..fountainSymbols = 30; // more symbols than K, but not decoded yet
      t.addChunk(1, [1]);
      expect(t.displayProgress, 0.99);

      // Once every block is recovered, it reads a full 1.0.
      for (var i = 2; i <= 10; i++) {
        t.addChunk(i, [i]);
      }
      expect(t.isComplete, true);
      expect(t.displayProgress, 1.0);
    });
  });
}
