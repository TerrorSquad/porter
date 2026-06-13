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
      t.reset();
      expect(t.total, 0);
      expect(t.chunks.isEmpty, true);
      expect(t.error, null);
    });
  });
}
