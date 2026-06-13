import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:porter_receiver/models/transfer.dart';
import 'package:porter_receiver/services/file_handler.dart';

void main() {
  group('FileHandler.guessExtension', () {
    test('text mode always returns .txt', () {
      final t = Transfer(id: 'AB');
      t.mode = 'T';
      t.assembled = [0x89, 0x50, 0x4e, 0x47];
      expect(FileHandler.guessExtension(t), '.txt');
    });

    test('detects PNG, JPG, PDF and ZIP magic bytes', () {
      final cases = <List<int>, String>{
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]: '.png',
        [0xff, 0xd8, 0xff, 0xe0]: '.jpg',
        [0x25, 0x50, 0x44, 0x46, 0x2d]: '.pdf',
        [0x50, 0x4b, 0x03, 0x04]: '.zip',
      };

      for (final entry in cases.entries) {
        final t = Transfer(id: 'AB');
        t.mode = 'B';
        t.assembled = entry.key;
        expect(FileHandler.guessExtension(t), entry.value);
      }
    });

    test('falls back to .bin for unrecognized or empty binary data', () {
      final empty = Transfer(id: 'AB');
      empty.mode = 'B';
      empty.assembled = [];
      expect(FileHandler.guessExtension(empty), '.bin');

      final unknown = Transfer(id: 'CD');
      unknown.mode = 'B';
      unknown.assembled = [1, 2, 3, 4];
      expect(FileHandler.guessExtension(unknown), '.bin');
    });
  });

  group('FileHandler.resolveOutputDirectory', () {
    test('creates and returns an explicit directory', () async {
      final base = Directory.systemTemp.createTempSync('porter_filehandler_');
      final target = Directory('${base.path}/nested/output');
      try {
        final dir = await FileHandler.resolveOutputDirectory(target.path);
        expect(dir.path, target.path);
        expect(await target.exists(), true);
      } finally {
        await base.delete(recursive: true);
      }
    });
  });

  group('FileHandler.saveFile', () {
    test('writes assembled bytes to the given output directory', () async {
      final dir = Directory.systemTemp.createTempSync('porter_filehandler_');
      try {
        final t = Transfer(id: 'AB');
        t.mode = 'T';
        t.assembled = utf8.encode('hello world');

        final path = await FileHandler.saveFile(t, outputDirectory: dir.path);

        expect(path, startsWith(dir.path));
        expect(await File(path).readAsBytes(), t.assembled);
        expect(path, endsWith('.txt'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('throws when there is nothing assembled', () async {
      final t = Transfer(id: 'AB');
      final dir = Directory.systemTemp.createTempSync('porter_filehandler_');
      try {
        await expectLater(
          () => FileHandler.saveFile(t, outputDirectory: dir.path),
          throwsException,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
