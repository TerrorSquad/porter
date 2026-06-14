import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:porter_receiver/models/transfer.dart';
import 'package:porter_receiver/providers/scanner_provider.dart';
import 'package:porter_receiver/providers/settings_provider.dart';
import 'package:porter_receiver/screens/transfers_screen.dart';
import 'package:porter_receiver/widgets/transfer_card.dart';

/// Pumps [TransfersScreen] with the given [scanner] provider.
Future<void> pumpScreen(WidgetTester tester, ScannerProvider scanner) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsProvider();
  await settings.ready;

  await tester.pumpWidget(
    MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<ScannerProvider>.value(value: scanner),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: const TransfersScreen(),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TransfersScreen', () {
    testWidgets('shows a placeholder when there are no transfers', (tester) async {
      await pumpScreen(tester, ScannerProvider());

      expect(find.text('No transfers yet — scan a QR code to begin.'), findsOneWidget);
      expect(find.byType(TransferCard), findsNothing);
    });

    testWidgets('lists transfers newest-first', (tester) async {
      final scanner = ScannerProvider();
      scanner.allTransfers['OLD'] = Transfer(
        id: 'OLD',
        createdAt: DateTime(2024, 1, 1),
      );
      scanner.allTransfers['NEW'] = Transfer(
        id: 'NEW',
        createdAt: DateTime(2024, 1, 2),
      );

      await pumpScreen(tester, scanner);

      expect(find.byType(TransferCard), findsNWidgets(2));

      final cards = tester.widgetList<TransferCard>(find.byType(TransferCard)).toList();
      expect(cards[0].transfer.id, 'NEW');
      expect(cards[1].transfer.id, 'OLD');
    });
  });
}
