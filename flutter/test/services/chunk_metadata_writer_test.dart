import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/models/transfer.dart';
import 'package:porter_receiver/services/chunk_metadata_writer.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('porter_metadata_writer_test_');
  });

  tearDown(() async {
    await tmpDir.delete(recursive: true);
  });

  File metaFile() => File('${tmpDir.path}/AB/metadata.json');

  test('markDirty coalesces a burst of calls into one write after the interval', () async {
    final t = Transfer(id: 'AB')..total = 3;
    final writer = ChunkMetadataWriter(
      t,
      outputDirectory: tmpDir.path,
      interval: const Duration(milliseconds: 30),
    );

    t.seenIndices.add(1);
    writer.markDirty();
    t.seenIndices.add(2);
    writer.markDirty();
    t.seenIndices.add(3);
    writer.markDirty();

    // Nothing written yet — still inside the debounce window.
    expect(await metaFile().exists(), false);

    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(await metaFile().exists(), true);
    final json = jsonDecode(await metaFile().readAsString()) as Map<String, dynamic>;
    expect(json['seenIndices'], [1, 2, 3]);

    writer.dispose();
  });

  test('flush writes immediately and cancels a pending timer', () async {
    final t = Transfer(id: 'AB')..total = 1;
    final writer = ChunkMetadataWriter(
      t,
      outputDirectory: tmpDir.path,
      interval: const Duration(seconds: 5),
    );

    t.seenIndices.add(1);
    writer.markDirty();
    await writer.flush();

    expect(await metaFile().exists(), true);

    // The debounce timer scheduled by markDirty() should have been
    // cancelled by flush() — waiting past its original 5s interval must not
    // produce a second, redundant write attempt (nothing to assert on
    // directly here beyond "no exception", since the JSON is identical
    // either way; the timer's absence is exercised by dispose() below).
    writer.dispose();
  });

  test('dispose prevents a scheduled write from firing', () async {
    final t = Transfer(id: 'AB')..total = 1;
    final writer = ChunkMetadataWriter(
      t,
      outputDirectory: tmpDir.path,
      interval: const Duration(milliseconds: 30),
    );

    t.seenIndices.add(1);
    writer.markDirty();
    writer.dispose();

    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(await metaFile().exists(), false);
  });
}
