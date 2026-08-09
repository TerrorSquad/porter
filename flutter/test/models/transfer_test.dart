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

    test('fountain displayProgress tracks blocks, with symbols behind it', () {
      final t = Transfer(id: 'CD')
        ..encoding = 'fountain'
        ..total = 100
        ..fountainSymbols = 40;
      t.addChunk(1, [1]); // only 1 block recovered so far

      // Sequential progress would show ~1%. Fountain scales symbols against
      // the ~1.5K actually needed to decode, not K: dividing by K showed
      // ~99% while a third of the scanning remained, which read as a hang.
      // The bar is blocks over K: a denominator that never moves, where
      // 100% genuinely means done. Symbol collection rides behind it so the
      // pre-avalanche phase still shows movement.
      expect(t.displayProgress, closeTo(1 / 100, 1e-9));
      expect(t.collectionProgress, closeTo(40 / 198, 1e-9));
      expect(t.progressLabel, '1 / 100 blocks · 40 symbols collected');
    });


    test('a resumed transfer is not charged for blocks already on disk', () {
      // Reproduces a real resume: 36% of blocks recovered from disk, symbol
      // count restarted. Charging 2x the *whole* K implied ~13 hours left
      // when most of that work was already done and saved.
      final t = Transfer(id: 'RS')
        ..encoding = 'fountain'
        ..total = 70965
        ..fountainSymbols = 25190;
      for (var i = 1; i <= 25853; i++) {
        t.markSeen(i);
      }

      expect(t.missingBlocks, 70965 - 25853);
      expect(t.fountainSymbolsNeeded, (70965 - 25853) * 2);
      expect(t.fountainSymbolsNeeded, lessThan(70965 * 2),
          reason: 'resumed work must cost less than a cold start');
      expect(t.displayProgress, closeTo(25853 / 70965, 1e-9),
          reason: 'the bar credits the blocks already on disk');
    });

    test('fountain displayProgress only reaches 1.0 when every block is in',
        () {
      final t = Transfer(id: 'EF')
        ..encoding = 'fountain'
        ..total = 10
        ..fountainSymbols = 30; // more symbols than K, but not decoded yet
      t.addChunk(1, [1]);

      // Tracking blocks means the bar cannot outrun reality: collecting more
      // symbols than K does not move it, so the old "cap at 0.99" guard is
      // no longer needed.
      expect(t.displayProgress, closeTo(0.1, 1e-9));
      expect(t.collectionProgress, 1.0,
          reason: 'collection is saturated even though nothing has decoded');

      for (var i = 2; i <= 10; i++) {
        t.addChunk(i, [i]);
      }
      expect(t.isComplete, true);
      expect(t.displayProgress, 1.0);
    });
  });
}
