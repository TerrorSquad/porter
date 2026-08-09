import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/services/assembler_worker.dart';

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

  group('AssemblerWorker', () {
    late Directory tmpDir;
    AssemblerWorker? worker;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('porter_assembler_worker_test_');
    });

    tearDown(() async {
      await worker?.dispose();
      worker = null;
      await tmpDir.delete(recursive: true);
    });

    test('ingests sequential chunks and posts completion with assembled bytes', () async {
      final events = <WorkerEvent>[];
      worker = await AssemblerWorker.spawn(events.add);
      worker!.setOutputDirectory(tmpDir.path);

      worker!.ingestQR('1|2|T|AB|Hello,');
      worker!.ingestQR('2|2|T|AB|World');

      await waitFor(() => events.any((e) => e is TransferCompletedEvent));

      final scanCounted = events.whereType<ScanCountedEvent>().toList();
      expect(scanCounted.length, 2);
      expect(scanCounted.every((e) => e.isNew), true);

      final completed = events.whereType<TransferCompletedEvent>().single;
      expect(completed.snapshot.id, 'AB');
      expect(completed.snapshot.isComplete, true);
      expect(utf8.decode(completed.assembled!), 'Hello,World');

      final chunkFile = File('${tmpDir.path}/AB/chunks/chunk_000001.bin');
      expect(await chunkFile.exists(), true);
    });

    test('decodes a nodejs cross-language fountain fixture', () async {
      final raw = File('test/fixtures/fountain_sample.json').readAsStringSync();
      final fixture = jsonDecode(raw) as Map<String, dynamic>;
      final chunks = (fixture['chunks'] as List).cast<String>();
      final expectedSha = fixture['sha256'] as String;

      final events = <WorkerEvent>[];
      worker = await AssemblerWorker.spawn(events.add);
      worker!.setOutputDirectory(tmpDir.path);

      for (final line in chunks) {
        worker!.ingestQR(line);
      }

      await waitFor(() => events.any((e) => e is TransferCompletedEvent));

      final completed = events.whereType<TransferCompletedEvent>().last;
      expect(completed.snapshot.isComplete, true);
      expect(completed.snapshot.verified, true);
      expect(completed.snapshot.checksum, expectedSha);
    });

    test('hydrateFromDisk without a prior setOutputDirectory call completes an '
        'already-finished transfer without a platform-channel round trip', () async {
      // Regression test: hydrateFromDisk is the very first call ScanningScreen
      // makes (before any ingestQR/setOutputDirectory). If a hydrated
      // transfer turns out to already be complete, its completion write used
      // to fall through to FileHandler.resolveOutputDirectory's
      // getDownloadsDirectory() platform channel — a call from inside the
      // worker isolate mid-hydration that crashed the isolate outright on a
      // real multi-thousand-chunk directory. hydrateFromDisk must adopt its
      // outputDirectory as the worker's working directory up front.
      final t0 = File('${tmpDir.path}/AB/chunks/chunk_000001.bin')
        ..createSync(recursive: true);
      await t0.writeAsBytes(utf8.encode('Hello,'));
      await File('${tmpDir.path}/AB/chunks/chunk_000002.bin').writeAsBytes(utf8.encode('World'));
      await File('${tmpDir.path}/AB/metadata.json').writeAsString(
        jsonEncode({'mode': 'T', 'encoding': 'sequential', 'total': 2}),
      );

      final events = <WorkerEvent>[];
      worker = await AssemblerWorker.spawn(events.add);

      // No setOutputDirectory call here — hydrateFromDisk must work standalone.
      worker!.hydrateFromDisk(tmpDir.path);

      await waitFor(() => events.any((e) => e is TransferCompletedEvent));

      final completed = events.whereType<TransferCompletedEvent>().single;
      expect(completed.snapshot.id, 'AB');
      expect(completed.snapshot.isComplete, true);
      expect(utf8.decode(completed.assembled!), 'Hello,World');

      final finalFile = File('${tmpDir.path}/AB/AB.txt');
      expect(await finalFile.exists(), true);
    });

    test('reset(id) drops in-worker state for that transfer only', () async {
      final events = <WorkerEvent>[];
      worker = await AssemblerWorker.spawn(events.add);
      worker!.setOutputDirectory(tmpDir.path);

      worker!.ingestQR('1|2|T|AB|Hello ');
      worker!.ingestQR('1|1|T|CD|Solo');
      await waitFor(
        () => events.any((e) => e is TransferCompletedEvent && e.snapshot.id == 'CD'),
      );

      worker!.reset('AB');

      // Re-ingesting the same chunk 1 for AB after reset is treated as new
      // (not a duplicate), proving the worker's in-memory state was cleared.
      events.clear();
      worker!.ingestQR('1|2|T|AB|Hello ');
      await waitFor(() => events.any((e) => e is ScanCountedEvent));
      final scanCounted = events.whereType<ScanCountedEvent>().single;
      expect(scanCounted.isNew, true);
    });
  });
}
