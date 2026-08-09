import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/utils/format.dart';

void main() {
  group('fountainHint', () {
    // The old UI showed one static line for the whole run, so 5% and 95%
    // looked identical — and with blocks pinned near 0 for most of a large
    // transfer, a healthy scan was indistinguishable from a hang.
    test('reports collection progress against symbols needed, not K', () {
      final hint = fountainHint(
        symbols: 68752,
        symbolsNeeded: 141930, // 2 * 70965
        blocks: 4344,
        totalBlocks: 70965,
        newPerSecond: 4.0,
      );
      expect(hint, contains('48%'));
      expect(hint, contains('left'));
    });

    test('switches to a decoding message once enough symbols are in', () {
      final hint = fountainHint(
        symbols: 145000,
        symbolsNeeded: 141930,
        blocks: 4344,
        totalBlocks: 70965,
        newPerSecond: 4.0,
      );
      expect(hint, contains('Decoding'));
    });

    test('omits an ETA when no new symbols are arriving', () {
      final hint = fountainHint(
        symbols: 100,
        symbolsNeeded: 1000,
        blocks: 0,
        totalBlocks: 660,
        newPerSecond: 0,
      );
      expect(hint, isNot(contains('left')));
      expect(hint, contains('10%'));
    });
  });

  group('formatDuration / formatEta at large scales', () {
    test('renders multi-hour spans as hours, not hundreds of minutes', () {
      expect(formatDuration(const Duration(minutes: 196)), '3h 16m');
    });

    test('rounds ETAs to half hours', () {
      expect(formatEta(const Duration(minutes: 147)), '~2h 30m');
      expect(formatEta(const Duration(seconds: 30)), 'under a minute');
    });
  });
}
