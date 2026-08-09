import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/providers/scanner_provider.dart';
import 'package:porter_receiver/services/assembler_worker.dart';

/// Polls [condition] until it becomes true or [timeout] elapses.
Future<void> waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('waitFor condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding installs an HttpOverrides that fakes HttpClient (always
  // 400) — the relay tests below need a real client to talk to their local
  // loopback HttpServer, so restore normal HTTP behavior for this suite.
  HttpOverrides.global = null;

  group('ScannerProvider', () {
    late Directory tmpDir;
    late ScannerProvider provider;

    setUp(() async {
      tmpDir = Directory.systemTemp.createTempSync('porter_scanner_test_');
      provider = ScannerProvider();
      await provider.ready;
    });

    tearDown(() async {
      provider.dispose();
      await tmpDir.delete(recursive: true);
    });

    test('ingestQR tracks new chunks, duplicates and completion', () async {
      String? completedId;
      provider.onTransferComplete = (t) => completedId = t.id;

      provider.ingestQR('1|2|T|AB|Hello', outputDirectory: tmpDir.path);
      await waitFor(() => provider.totalScanned == 1);
      expect(provider.duplicatesSkipped, 0);
      expect(provider.activeTransfer?.id, 'AB');

      // Same chunk again is a duplicate.
      provider.ingestQR('1|2|T|AB|Hello', outputDirectory: tmpDir.path);
      await waitFor(() => provider.duplicatesSkipped == 1);
      expect(provider.totalScanned, 1);

      provider.ingestQR('2|2|T|AB|World', outputDirectory: tmpDir.path);
      await waitFor(() => completedId == 'AB');
      expect(provider.totalScanned, 2);
      expect(provider.allTransfers['AB']?.isComplete, true);

      // Let the async chunk-storage writes settle before tmpDir is removed.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('resetAll clears scan stats, transfers and relay state', () async {
      provider.ingestQR('1|2|T|AB|Hello', outputDirectory: tmpDir.path);
      await waitFor(() => provider.totalScanned == 1);
      provider.ingestQR('1|2|T|AB|Hello', outputDirectory: tmpDir.path); // duplicate
      await waitFor(() => provider.duplicatesSkipped == 1);

      provider.resetAll();

      expect(provider.totalScanned, 0);
      expect(provider.duplicatesSkipped, 0);
      expect(provider.activeTransfer, null);
      expect(provider.allTransfers, isEmpty);
      expect(provider.relayStates, isEmpty);
      expect(provider.relayLastOk, null);
    });

    test('reset(id) clears only the matching transfer', () async {
      provider.ingestQR('1|2|T|AB|Hello', outputDirectory: tmpDir.path);
      provider.ingestQR('1|1|T|CD|Solo', outputDirectory: tmpDir.path);
      await waitFor(() => provider.allTransfers.containsKey('AB') && provider.allTransfers.containsKey('CD'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The most recently ingested chunk (CD) is the active transfer.
      provider.reset('CD');

      expect(provider.allTransfers.containsKey('AB'), true);
      expect(provider.allTransfers.containsKey('CD'), false);
      expect(provider.activeTransfer, null);
    });

    test('scansPerSecond and bytesPerSecond reflect recent activity', () async {
      provider.ingestQR('1|2|T|AB|Hello', outputDirectory: tmpDir.path);

      await waitFor(() => provider.scansPerSecond > 0 && provider.bytesPerSecond > 0);
    });

    test('estimatedSenderIntervalMs is null until enough new chunks arrive, then '
        'reflects new-chunk gaps and ignores duplicate scans', () async {
      expect(provider.estimatedSenderIntervalMs, null);

      // Duplicates alone (no distinct new chunks yet) must not produce an
      // estimate — they say nothing about how fast the sender is advancing.
      provider.ingestQR('1|5|T|AB|One', outputDirectory: tmpDir.path);
      await waitFor(() => provider.totalScanned == 1);
      for (var i = 0; i < 5; i++) {
        provider.ingestQR('1|5|T|AB|One', outputDirectory: tmpDir.path); // duplicate
      }
      await waitFor(() => provider.duplicatesSkipped == 5);
      expect(provider.estimatedSenderIntervalMs, null);

      // Distinct new chunks, spaced ~30ms apart, give a real estimate.
      for (final line in ['2|5|T|AB|Two', '3|5|T|AB|Thr', '4|5|T|AB|Fou']) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        provider.ingestQR(line, outputDirectory: tmpDir.path);
      }
      await waitFor(() => provider.totalScanned == 4);

      final estimate = provider.estimatedSenderIntervalMs;
      expect(estimate, isNotNull);
      expect(estimate!, greaterThan(0));
      // Loose bound — real timing, not exact — just proves it's in the
      // right ballpark for a ~30ms-spaced sequence, not e.g. milliseconds
      // from the unrelated first chunk/duplicate burst.
      expect(estimate, lessThan(500));
    });

    test('speedHint suggests increasing sender speed when duplicates dominate', () async {
      expect(provider.speedHint, null);

      // One new chunk, then many duplicate scans of it (attempts/frame high)
      // — the classic "receiver is idling between sender frame changes" case.
      provider.ingestQR('1|5|T|AB|One', outputDirectory: tmpDir.path);
      await waitFor(() => provider.totalScanned == 1);
      for (var i = 0; i < 10; i++) {
        provider.ingestQR('1|5|T|AB|One', outputDirectory: tmpDir.path);
      }
      await waitFor(() => provider.duplicatesSkipped == 10);

      for (final line in ['2|5|T|AB|Two', '3|5|T|AB|Thr']) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        provider.ingestQR(line, outputDirectory: tmpDir.path);
      }
      await waitFor(() => provider.totalScanned == 3);

      expect(provider.speedHint, SpeedHint.increase);
    });

    test('speedHint suggests slowing down when almost every scan is a new chunk', () async {
      // Every scan lands a new chunk — attempts/frame near 1, no slack.
      for (final line in ['1|5|T|AB|One', '2|5|T|AB|Two', '3|5|T|AB|Thr', '4|5|T|AB|Fou']) {
        provider.ingestQR(line, outputDirectory: tmpDir.path);
      }
      await waitFor(() => provider.totalScanned == 4);

      expect(provider.speedHint, SpeedHint.decrease);
    });

    test('hydrateFromDisk resumes an interrupted transfer without re-ingesting', () async {
      // Simulate a transfer that was killed after 2 of 3 chunks were saved.
      provider.ingestQR('1|3|T|AB|One', outputDirectory: tmpDir.path);
      provider.ingestQR('2|3|T|AB|Two', outputDirectory: tmpDir.path);
      await waitFor(() => provider.totalScanned == 2);
      provider.flushAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Fresh provider, as if the app was relaunched.
      final resumed = ScannerProvider();
      await resumed.ready;
      addTearDown(resumed.dispose);

      await resumed.hydrateFromDisk(tmpDir.path);
      await waitFor(() => resumed.allTransfers.containsKey('AB'));

      expect(resumed.allTransfers['AB']?.seenIndices, {1, 2});
      // Hydration alone shouldn't surface the transfer as "active" before any
      // scanning happens in this session.
      expect(resumed.activeTransfer, null);

      // Re-scanning an already-hydrated chunk is a duplicate for state, but
      // must still surface the transfer as active — otherwise a resumed
      // transfer whose next few scans all happen to already be hydrated
      // would appear to do nothing on screen.
      resumed.ingestQR('1|3|T|AB|One', outputDirectory: tmpDir.path);
      await waitFor(() => resumed.activeTransfer?.id == 'AB');

      // Scanning the missing chunk completes the transfer using only new
      // information — no re-scan of chunks 1/2 was needed.
      String? completedId;
      resumed.onTransferComplete = (t) => completedId = t.id;
      resumed.ingestQR('3|3|T|AB|Three', outputDirectory: tmpDir.path);
      await waitFor(() => completedId == 'AB');
      expect(resumed.allTransfers['AB']?.isComplete, true);

      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    group('relay', () {
      HttpServer? server;

      tearDown(() async {
        await server?.close(force: true);
        server = null;
      });

      Future<String> startServer(Future<void> Function(HttpRequest req) handler) async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server!.listen((req) async {
          await handler(req);
        });
        return 'http://127.0.0.1:${server!.port}';
      }

      test('successful relay marks relayLastOk and records sent chunks', () async {
        final url = await startServer((req) async {
          await req.drain<void>();
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'transferId': 'AB', 'duplicate': false}));
          await req.response.close();
        });

        provider.ingestQR('1|2|T|AB|Hello', relayUrl: url, outputDirectory: tmpDir.path);

        await waitFor(() => provider.relayLastOk != null);

        expect(provider.relayLastOk, true);
        expect(provider.relayStates['AB']?.sent, 1);
        expect(provider.relayStates['AB']?.lastError, null);

        // Let the async chunk-storage writes settle before tmpDir is removed.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      test('duplicate relay response does not increment sent', () async {
        final url = await startServer((req) async {
          await req.drain<void>();
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'transferId': 'AB', 'duplicate': true}));
          await req.response.close();
        });

        provider.ingestQR('1|2|T|AB|Hello', relayUrl: url, outputDirectory: tmpDir.path);

        await waitFor(() => provider.relayLastOk != null);

        expect(provider.relayLastOk, true);
        expect(provider.relayStates['AB']?.sent, 0);

        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      test('HTTP error response sets relayLastOk to false', () async {
        final url = await startServer((req) async {
          await req.drain<void>();
          req.response.statusCode = 500;
          await req.response.close();
        });

        provider.ingestQR('1|2|T|AB|Hello', relayUrl: url, outputDirectory: tmpDir.path);

        await waitFor(() => provider.relayLastOk != null);

        expect(provider.relayLastOk, false);
        expect(provider.relayStates, isEmpty);

        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      test('complete response records verified flag and joined path', () async {
        final url = await startServer((req) async {
          await req.drain<void>();
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'transferId': 'AB',
            'complete': true,
            'verified': true,
            'joinedPath': '/tmp/joined/AB.bin',
          }));
          await req.response.close();
        });

        provider.ingestQR('1|2|T|AB|Hello', relayUrl: url, outputDirectory: tmpDir.path);

        await waitFor(() => provider.relayStates['AB']?.complete == true);

        final state = provider.relayStates['AB']!;
        expect(state.complete, true);
        expect(state.verified, true);
        expect(state.joinedPath, '/tmp/joined/AB.bin');

        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    });
  });

  group('stall and worker-death reporting', () {
    // The UI could not distinguish "working" from "dead": the camera and FPS
    // readout live on the main isolate and keep running even after the worker
    // isolate stops. A live transfer sat at 42% CPU with zero progress for 14
    // minutes with nothing on screen to say so.
    test('a fatal worker event marks the provider dead and stalled', () async {
      final provider = ScannerProvider();
      addTearDown(provider.dispose);
      await provider.ready;

      expect(provider.workerDead, false);
      expect(provider.isStalled, false);

      provider.applyWorkerEvent(
        WorkerCrashEvent('boom', 'stack', isFatal: true),
      );

      expect(provider.workerDead, true);
      expect(provider.isStalled, true);
      expect(provider.workerError, 'boom');
    });

    test('a non-fatal worker error is reported without marking it dead',
        () async {
      final provider = ScannerProvider();
      addTearDown(provider.dispose);
      await provider.ready;

      provider.applyWorkerEvent(WorkerCrashEvent('recoverable', null));

      expect(provider.workerError, 'recoverable');
      expect(provider.workerDead, false);
      expect(provider.isStalled, false,
          reason: 'one failed message is not a stall');
    });

    test('sinceLastNewChunk survives past the rate window', () async {
      final provider = ScannerProvider();
      addTearDown(provider.dispose);
      await provider.ready;

      expect(provider.sinceLastNewChunk, isNull);

      provider.applyWorkerEvent(ScanCountedEvent(true));

      // Tracked on its own field, not derived from the pruned rate window --
      // that window empties after 30s, which is exactly when a stall needs
      // detecting.
      expect(provider.sinceLastNewChunk, isNotNull);
      expect(provider.sinceLastNewChunk!.inSeconds, lessThan(2));
    });
  });
}
