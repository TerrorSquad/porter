import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:porter_receiver/models/progress_snapshot.dart';
import 'package:porter_receiver/providers/scanner_provider.dart';
import 'package:porter_receiver/providers/settings_provider.dart';
import 'package:porter_receiver/screens/scanning_screen.dart';
import 'package:porter_receiver/screens/settings_screen.dart';
import 'package:porter_receiver/services/assembler_worker.dart';

const _mobileScannerMethodChannel = MethodChannel(
  'dev.steenbakker.mobile_scanner/scanner/method',
);
const _mobileScannerEventChannel = EventChannel(
  'dev.steenbakker.mobile_scanner/scanner/event',
);
const _deviceOrientationChannel = EventChannel(
  'dev.steenbakker.mobile_scanner/scanner/deviceOrientation',
);
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Mocks the platform channels that [ScanningScreen] touches indirectly via
/// `MobileScannerController.start()` (mobile_scanner) and `SettingsScreen`'s
/// downloads-path lookup (path_provider), so the widget tree can build and
/// run without a real camera or native plugin implementations.
void _setUpPlatformMocks() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(_mobileScannerMethodChannel, (call) async {
    switch (call.method) {
      case 'state':
        return 1; // MobileScannerAuthorizationState.authorized
      case 'start':
        return <String, Object?>{
          'textureId': 0,
          'cameraDirection': 1,
          'currentTorchState': 0,
          'numberOfCameras': 1,
          'size': {'width': 1280.0, 'height': 720.0},
          'handlesCropAndRotation': true,
          'naturalDeviceOrientation': 'PORTRAIT_UP',
          'sensorOrientation': 0,
        };
      default:
        return null;
    }
  });

  messenger.setMockStreamHandler(
    _mobileScannerEventChannel,
    MockStreamHandler.inline(onListen: (arguments, events) {}),
  );
  messenger.setMockStreamHandler(
    _deviceOrientationChannel,
    MockStreamHandler.inline(onListen: (arguments, events) {}),
  );

  messenger.setMockMethodCallHandler(_pathProviderChannel, (call) async {
    if (call.method == 'getDownloadsDirectory') {
      return Directory.systemTemp.path;
    }
    return null;
  });
}

/// Builds the [ProgressSnapshotEvent] a worker isolate would post after
/// ingesting chunk 1 of 2 (mode 'T', id 'AB') — used by widget tests to drive
/// [ScannerProvider] state via [ScannerProvider.applyWorkerEvent] instead of
/// spawning a real isolate (unreliable to tear down inside the headless
/// `flutter_tester` test shell).
ProgressSnapshotEvent _oneOfTwoChunksSnapshot() => ProgressSnapshotEvent(
      ProgressSnapshot(
        id: 'AB',
        total: 2,
        mode: 'T',
        encoding: 'sequential',
        fountainFileSize: null,
        fountainSymbols: 0,
        seenIndices: const [1],
        receivedBytes: 5,
        checksum: null,
        verified: null,
        error: null,
        isComplete: false,
        createdAt: DateTime.now(),
        completedAt: null,
      ),
    );

/// Pumps [ScanningScreen] with the given [scanner] provider.
Future<void> pumpScreen(
  WidgetTester tester,
  ScannerProvider scanner, {
  String relayUrl = '',
}) async {
  SharedPreferences.setMockInitialValues(
    relayUrl.isEmpty ? {} : {'porter.relayUrl': relayUrl},
  );
  final settings = SettingsProvider();
  await settings.ready;

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ScannerProvider>.value(value: scanner),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ],
      child: const MaterialApp(home: ScanningScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScanningScreen', () {
    setUp(_setUpPlatformMocks);

    testWidgets('shows the app bar title and an empty transfers badge', (tester) async {
      final scanner = ScannerProvider();
      addTearDown(scanner.dispose);
      await pumpScreen(tester, scanner);

      expect(find.text('Porter Receiver'), findsOneWidget);

      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(badge.isLabelVisible, false);
    });

    testWidgets('shows the transfers badge count once a transfer exists', (tester) async {
      final scanner = ScannerProvider();
      addTearDown(scanner.dispose);
      scanner.applyWorkerEvent(ScanCountedEvent(true));
      scanner.applyWorkerEvent(_oneOfTwoChunksSnapshot());

      await pumpScreen(tester, scanner);

      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(badge.isLabelVisible, true);
      expect(find.descendant(of: find.byType(Badge), matching: find.text('1')), findsOneWidget);
    });

    testWidgets('idle state shows the placeholder and HUD text', (tester) async {
      final scanner = ScannerProvider();
      addTearDown(scanner.dispose);
      await pumpScreen(tester, scanner);

      expect(find.text('Point camera at QR codes'), findsOneWidget);
      expect(find.text('scanned 0 · new 0 · dupes 0 · 0.0/s · 0 B/s'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('active transfer shows progress and the chunk count', (tester) async {
      final scanner = ScannerProvider();
      addTearDown(scanner.dispose);
      scanner.applyWorkerEvent(_oneOfTwoChunksSnapshot());

      await pumpScreen(tester, scanner);

      // Two layers now: symbol collection behind, blocks decoded in front.
      // The front one is what "progress" means, so assert on its value.
      final bars = tester
          .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator))
          .toList();
      expect(bars, hasLength(2));
      expect(bars.last.value, closeTo(0.5, 1e-9));
      expect(find.text('1 / 2 chunks'), findsOneWidget);
      expect(find.text('Point camera at QR codes'), findsNothing);
    });

    testWidgets('relay dot reflects relayLastOk', (tester) async {
      final scanner = ScannerProvider();
      addTearDown(scanner.dispose);
      await pumpScreen(tester, scanner, relayUrl: 'http://example.com');

      Text dot() => tester.widget<Text>(find.text('●'));
      expect(dot().style?.color, Colors.grey);

      scanner.relayLastOk = true;
      scanner.notifyListeners();
      await tester.pump();
      expect(dot().style?.color, Colors.green);

      scanner.relayLastOk = false;
      scanner.notifyListeners();
      await tester.pump();
      expect(dot().style?.color, Colors.red);
    });

    testWidgets('Settings action opens the settings screen', (tester) async {
      final scanner = ScannerProvider();
      addTearDown(scanner.dispose);
      await pumpScreen(tester, scanner);

      await tester.tap(find.byTooltip('Settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });
}
