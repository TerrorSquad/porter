import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:porter_receiver/models/relay_state.dart';
import 'package:porter_receiver/models/transfer.dart';
import 'package:porter_receiver/providers/scanner_provider.dart';
import 'package:porter_receiver/providers/settings_provider.dart';
import 'package:porter_receiver/widgets/chunk_grid.dart';
import 'package:porter_receiver/widgets/transfer_card.dart';

/// Pumps a [TransferCard] for [transfer] inside the providers it depends on.
Future<void> pumpCard(
  WidgetTester tester,
  Transfer transfer, {
  ScannerProvider? scanner,
  String relayUrl = '',
}) async {
  SharedPreferences.setMockInitialValues(
    relayUrl.isEmpty ? {} : {'porter.relayUrl': relayUrl},
  );
  final settings = SettingsProvider();
  await settings.ready;

  await tester.pumpWidget(
    MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<ScannerProvider>.value(value: scanner ?? ScannerProvider()),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: Scaffold(body: TransferCard(transfer: transfer)),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TransferCard', () {
    testWidgets('status badge shows Scanning… while incomplete and Complete once done', (tester) async {
      final scanning = Transfer(id: 'AB')
        ..total = 2
        ..seenIndices.add(1);
      await pumpCard(tester, scanning);
      expect(find.text('Scanning…'), findsOneWidget);
      expect(find.text('Complete'), findsNothing);

      final complete = Transfer(id: 'CD')
        ..total = 2
        ..seenIndices.addAll({1, 2});
      await pumpCard(tester, complete);
      expect(find.text('Complete'), findsOneWidget);
      expect(find.text('Scanning…'), findsNothing);
    });

    testWidgets('status badge shows Error when transfer.error is set', (tester) async {
      final transfer = Transfer(id: 'AB')
        ..total = 2
        ..seenIndices.add(1)
        ..error = 'boom';
      await pumpCard(tester, transfer);
      expect(find.text('Error'), findsOneWidget);
    });

    testWidgets('checksum badge reflects verified/unverified/failed', (tester) async {
      final unverified = Transfer(id: 'AB')
        ..total = 1
        ..seenIndices.add(1);
      await pumpCard(tester, unverified);
      expect(find.text('— Unverified'), findsOneWidget);

      final verified = Transfer(id: 'CD')
        ..total = 1
        ..seenIndices.add(1)
        ..verified = true;
      await pumpCard(tester, verified);
      expect(find.text('✓ Verified'), findsOneWidget);

      final failed = Transfer(id: 'EF')
        ..total = 1
        ..seenIndices.add(1)
        ..verified = false;
      await pumpCard(tester, failed);
      expect(find.text('✗ Failed'), findsOneWidget);
    });

    testWidgets('save button is disabled until the transfer is complete', (tester) async {
      final incomplete = Transfer(id: 'AB')
        ..total = 2
        ..seenIndices.add(1);
      await pumpCard(tester, incomplete);
      final incompleteButton = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(incompleteButton.onPressed, isNull);

      final complete = Transfer(id: 'CD')
        ..total = 2
        ..seenIndices.addAll({1, 2});
      await pumpCard(tester, complete);
      final completeButton = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(completeButton.onPressed, isNotNull);
    });

    testWidgets('toggling "Show missing" reveals the chunk grid and missing ranges', (tester) async {
      final transfer = Transfer(id: 'AB')
        ..total = 4
        ..seenIndices.addAll({1, 3});

      await pumpCard(tester, transfer);

      expect(find.text('Show missing ▼'), findsOneWidget);
      expect(find.byType(ChunkGrid), findsNothing);

      await tester.tap(find.text('Show missing ▼'));
      await tester.pump();

      expect(find.text('Hide missing ▲'), findsOneWidget);
      expect(find.byType(ChunkGrid), findsOneWidget);
      expect(find.text('Missing: 2, 4'), findsOneWidget);
    });

    testWidgets('shows a Fountain badge only for fountain-encoded transfers', (tester) async {
      final sequential = Transfer(id: 'AB')
        ..total = 2
        ..seenIndices.add(1);
      await pumpCard(tester, sequential);
      expect(find.text('Fountain'), findsNothing);

      final fountain = Transfer(id: 'CD')
        ..encoding = 'fountain'
        ..mode = 'B'
        ..total = 4
        ..seenIndices.addAll({1, 2});
      await pumpCard(tester, fountain);
      expect(find.text('Fountain'), findsOneWidget);
    });

    testWidgets('fountain transfers show symbols collected and relabel missing text', (tester) async {
      final transfer = Transfer(id: 'AB')
        ..encoding = 'fountain'
        ..mode = 'B'
        ..total = 4
        ..fountainFileSize = 50
        ..fountainSymbols = 7
        ..seenIndices.addAll({1, 3});

      await pumpCard(tester, transfer);

      // Symbol count is the headline progress signal for fountain transfers.
      expect(find.text('7 / 8 symbols · 2 / 4 blocks decoded'), findsOneWidget);

      await tester.tap(find.text('Show missing ▼'));
      await tester.pump();

      expect(find.byType(ChunkGrid), findsOneWidget);
      expect(
        find.text('2 blocks not yet recovered — keep scanning, any frames will do'),
        findsOneWidget,
      );
      // The sequential "Missing: <ranges>" phrasing must not appear.
      expect(find.textContaining('Missing:'), findsNothing);
    });

    testWidgets('relay row is hidden when no relay URL is configured', (tester) async {
      final transfer = Transfer(id: 'AB')
        ..total = 1
        ..seenIndices.add(1);
      await pumpCard(tester, transfer);
      expect(find.textContaining('Relay'), findsNothing);
    });

    testWidgets('relay row shows waiting state before any relay activity', (tester) async {
      final transfer = Transfer(id: 'AB')
        ..total = 1
        ..seenIndices.add(1);
      await pumpCard(tester, transfer, relayUrl: 'http://example.com');
      expect(find.text('○ Relay: waiting for first chunk…'), findsOneWidget);
    });

    testWidgets('relay row shows the error state', (tester) async {
      final transfer = Transfer(id: 'AB')
        ..total = 1
        ..seenIndices.add(1);
      final scanner = ScannerProvider();
      scanner.relayStates['AB'] = RelayState(lastError: 'boom');
      await pumpCard(tester, transfer, scanner: scanner, relayUrl: 'http://example.com');
      expect(find.text('✕ Relay: error — boom'), findsOneWidget);
    });

    testWidgets('relay row shows the joined path once available', (tester) async {
      final transfer = Transfer(id: 'AB')
        ..total = 1
        ..seenIndices.add(1);
      final scanner = ScannerProvider();
      scanner.relayStates['AB'] = RelayState(sent: 1, joinedPath: '/tmp/joined/AB.bin');
      await pumpCard(tester, transfer, scanner: scanner, relayUrl: 'http://example.com');
      expect(find.text('✓ Relay: joined → /tmp/joined/AB.bin'), findsOneWidget);
    });

    testWidgets('relay row shows the complete state', (tester) async {
      final transfer = Transfer(id: 'AB')
        ..total = 1
        ..seenIndices.add(1);
      final scanner = ScannerProvider();
      scanner.relayStates['AB'] = RelayState(sent: 1, complete: true);
      await pumpCard(tester, transfer, scanner: scanner, relayUrl: 'http://example.com');
      expect(find.text('✓ Relay: complete'), findsOneWidget);
    });

    testWidgets('relay row shows the in-progress sent count', (tester) async {
      final transfer = Transfer(id: 'AB')
        ..total = 2
        ..seenIndices.add(1);
      final scanner = ScannerProvider();
      scanner.relayStates['AB'] = RelayState(sent: 2);
      await pumpCard(tester, transfer, scanner: scanner, relayUrl: 'http://example.com');
      expect(find.text('⇡ Relay: 2 chunks saved'), findsOneWidget);
    });
  });
}
