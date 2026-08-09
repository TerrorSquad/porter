import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/models/transfer.dart';
import 'package:porter_receiver/services/chunk_storage.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('porter_chunk_storage_test_');
  });

  tearDown(() async {
    await tmpDir.delete(recursive: true);
  });

  group('ChunkStorage.writeChunk', () {
    test('writes only the .bin file and does not touch metadata.json', () async {
      final t = Transfer(id: 'AB')..total = 2;
      await ChunkStorage.writeChunk(t, 1, [1, 2, 3], outputDirectory: tmpDir.path);

      final chunkFile = File('${tmpDir.path}/AB/chunks/chunk_000001.bin');
      expect(await chunkFile.exists(), true);
      expect(await chunkFile.readAsBytes(), [1, 2, 3]);

      final metaFile = File('${tmpDir.path}/AB/metadata.json');
      expect(await metaFile.exists(), false);
    });
  });

  group('ChunkStorage.writeMetadata', () {
    test('writes the expected JSON shape', () async {
      final t = Transfer(id: 'AB')
        ..total = 2
        ..mode = 'T'
        ..checksum = 'abc123';
      t.addChunk(1, [1, 2, 3]);

      await ChunkStorage.writeMetadata(t, outputDirectory: tmpDir.path);

      final metaFile = File('${tmpDir.path}/AB/metadata.json');
      expect(await metaFile.exists(), true);
      final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;

      expect(json['id'], 'AB');
      expect(json['mode'], 'T');
      expect(json['total'], 2);
      expect(json['seenIndices'], [1]);
      expect(json['missingIndices'], [2]);
      expect(json['receivedBytes'], 3);
      expect(json['checksum'], 'abc123');
      expect(json['isComplete'], false);
    });
  });

  group('ChunkStorage.writeAssembledFile', () {
    test('writes the assembled bytes with a guessed extension', () async {
      final t = Transfer(id: 'AB')
        ..mode = 'B'
        ..assembled = [0x50, 0x4b, 0x03, 0x04];

      final path = await ChunkStorage.writeAssembledFile(t, outputDirectory: tmpDir.path);

      expect(path, endsWith('.zip'));
      expect(await File(path).readAsBytes(), t.assembled);
    });
  });

  group('ChunkStorage.hydrateAll', () {
    test('rebuilds the index set from .bin filenames, trusting them over metadata.json', () async {
      final t = Transfer(id: 'AB')
        ..total = 3
        ..mode = 'T';
      await ChunkStorage.writeChunk(t, 1, [1], outputDirectory: tmpDir.path);
      await ChunkStorage.writeChunk(t, 3, [3], outputDirectory: tmpDir.path);
      // metadata.json intentionally understates seenIndices — hydration must
      // ignore it and trust the .bin files, which show 2 chunks (1 and 3).
      await ChunkStorage.writeMetadata(t, outputDirectory: tmpDir.path);

      final hydrated = await ChunkStorage.hydrateAll(outputDirectory: tmpDir.path);

      expect(hydrated.length, 1);
      final h = hydrated.single;
      expect(h.id, 'AB');
      expect(h.mode, 'T');
      expect(h.total, 3);
      expect(h.seenIndices, {1, 3});
      // Bytes aren't read eagerly, but readChunk fetches them on demand.
      expect(await h.readChunk(1), [1]);
      expect(await h.readChunk(3), [3]);
    });

    test('ignores non-matching filenames in chunks/', () async {
      final chunksDir = Directory('${tmpDir.path}/AB/chunks')..createSync(recursive: true);
      File('${chunksDir.path}/chunk_000001.bin').writeAsBytesSync([9]);
      File('${chunksDir.path}/not_a_chunk.txt').writeAsStringSync('ignore me');

      final hydrated = await ChunkStorage.hydrateAll(outputDirectory: tmpDir.path);

      expect(hydrated.single.seenIndices, {1});
    });

    test('yields a valid hydration when metadata.json is missing or corrupt', () async {
      final chunksDir = Directory('${tmpDir.path}/AB/chunks')..createSync(recursive: true);
      File('${chunksDir.path}/chunk_000001.bin').writeAsBytesSync([1]);

      final hydrated = await ChunkStorage.hydrateAll(outputDirectory: tmpDir.path);
      expect(hydrated.single.seenIndices, {1});
      expect(hydrated.single.total, 0); // unknown without metadata.json

      File('${tmpDir.path}/AB/metadata.json').writeAsStringSync('{not valid json');
      final hydratedWithCorruptMeta = await ChunkStorage.hydrateAll(outputDirectory: tmpDir.path);
      expect(hydratedWithCorruptMeta.single.seenIndices, {1});
    });

    test('skips directories with no chunks/ subfolder, returns empty for an empty base', () async {
      Directory('${tmpDir.path}/not-a-transfer').createSync(recursive: true);

      final hydrated = await ChunkStorage.hydrateAll(outputDirectory: tmpDir.path);
      expect(hydrated, isEmpty);

      final emptyDir = Directory.systemTemp.createTempSync('porter_hydrate_empty_');
      try {
        expect(await ChunkStorage.hydrateAll(outputDirectory: emptyDir.path), isEmpty);
      } finally {
        await emptyDir.delete(recursive: true);
      }
    });

    test('skips a transfer that already has its final output file written', () async {
      final t = Transfer(id: 'AB')
        ..total = 1
        ..mode = 'T'
        ..assembled = [1, 2, 3];
      await ChunkStorage.writeChunk(t, 1, [1, 2, 3], outputDirectory: tmpDir.path);
      await ChunkStorage.writeAssembledFile(t, outputDirectory: tmpDir.path);

      final hydrated = await ChunkStorage.hydrateAll(outputDirectory: tmpDir.path);

      expect(hydrated, isEmpty);
    });

    test('scans thousands of chunks without reading their bytes', () async {
      // Regression test: hydrateAll used to eagerly read every chunk's bytes
      // into memory during the scan, which crashed the app on a real
      // ~14,000-chunk transfer directory. Only filenames should be touched
      // here — content bytes read on demand via readChunk.
      final chunksDir = Directory('${tmpDir.path}/AB/chunks')..createSync(recursive: true);
      const count = 3000;
      // Write oversized placeholder content so an eager full-content read
      // would be slow/memory-heavy enough to notice if the regression
      // reappears, while a filename-only scan stays fast regardless.
      final bigContent = List<int>.filled(64 * 1024, 7);
      for (var i = 1; i <= count; i++) {
        File('${chunksDir.path}/chunk_${i.toString().padLeft(6, '0')}.bin')
            .writeAsBytesSync(bigContent);
      }

      final stopwatch = Stopwatch()..start();
      final hydrated = await ChunkStorage.hydrateAll(outputDirectory: tmpDir.path);
      stopwatch.stop();

      expect(hydrated.single.seenIndices.length, count);
      // A pure filename scan of 3000 entries should be well under a second;
      // reading 3000 * 64KB eagerly would be markedly slower.
      expect(stopwatch.elapsedMilliseconds, lessThan(3000));
    });
  });

  group('seen_seqs sidecar', () {
    test('round-trips appended seqs and tolerates a truncated tail', () async {
      final dir = await Directory.systemTemp.createTemp('porter_seqs');
      addTearDown(() => dir.delete(recursive: true));

      final transfer = Transfer(id: 'abc')..transferDirPath = dir.path;
      await ChunkStorage.appendSeenSeqs(transfer, [1, 2, 70000]);
      await ChunkStorage.appendSeenSeqs(transfer, [4294967295]);

      expect(await ChunkStorage.readSeenSeqs(dir), {1, 2, 70000, 4294967295});

      // Simulate a kill mid-append: a trailing partial uint32 is ignored.
      final f = File('${dir.path}/seen_seqs.bin');
      await f.writeAsBytes([0xAA, 0xBB], mode: FileMode.append);
      expect(await ChunkStorage.readSeenSeqs(dir), {1, 2, 70000, 4294967295});
    });
  });

  group('layout-change recovery', () {
    test('archiveChunks moves the old stream aside, keeping its data', () async {
      final dir = await Directory.systemTemp.createTemp('porter_arch');
      addTearDown(() => dir.delete(recursive: true));
      final t = Transfer(id: 'ar');
      // writeChunk resolves <outputDirectory>/<id>/ and records it on the
      // transfer, so let it establish transferDirPath rather than presuming.
      await ChunkStorage.writeChunk(t, 1, List.filled(40, 7),
          outputDirectory: dir.path);
      final tdir = Directory(t.transferDirPath!);
      await ChunkStorage.appendSeenSeqs(t, [1, 2, 3]);
      await ChunkStorage.archiveChunks(t, outputDirectory: dir.path);

      expect(Directory('${tdir.path}/chunks').existsSync(), false);
      final archived = tdir
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.contains('chunks_superseded_'));
      expect(archived, hasLength(1),
          reason: 'old blocks must be preserved, not deleted');
      expect(File('${tdir.path}/seen_seqs.bin').existsSync(), false,
          reason: 'old seqs describe the old layout and must not be reused');
    });

    /// Reproduces the directory that actually broke: two sender sessions at
    /// different QR versions wrote into one content-hashed folder, leaving
    /// 1617- and 2172-byte blocks interleaved. Hydration must resume the
    /// majority layout and ignore the rest rather than assembling garbage.
    test('hydration keeps only the modal block size in a mixed directory',
        () async {
      final base = await Directory.systemTemp.createTemp('porter_mixed');
      addTearDown(() => base.delete(recursive: true));
      final chunks = Directory('${base.path}/1e/chunks')
        ..createSync(recursive: true);

      for (var i = 1; i <= 30; i++) {
        File('${chunks.path}/chunk_${i.toString().padLeft(6, '0')}.bin')
            .writeAsBytesSync(List.filled(1617, 1));
      }
      for (var i = 31; i <= 40; i++) {
        File('${chunks.path}/chunk_${i.toString().padLeft(6, '0')}.bin')
            .writeAsBytesSync(List.filled(2172, 2));
      }
      File('${base.path}/1e/metadata.json').writeAsStringSync(
          '{"id":"1e","encoding":"fountain","mode":"B","total":100}');

      final hydrated = await ChunkStorage.hydrateAll(outputDirectory: base.path);
      expect(hydrated, hasLength(1));
      expect(hydrated.single.blockSize, 1617);
      expect(hydrated.single.seenIndices, hasLength(30),
          reason: 'the 10 foreign-sized blocks must not be credited');
    });
  });
}
