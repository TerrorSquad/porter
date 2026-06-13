import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/transfer.dart';

class FileHandler {
  static Future<String> saveFile(Transfer transfer) async {
    if (transfer.assembled == null) {
      throw Exception('No assembled data to save');
    }

    try {
      final dir = await getDownloadsDirectory();
      if (dir == null) {
        // Fallback to app documents
        return _saveToAppDocs(transfer);
      }

      final filename = _generateFilename(transfer);
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(transfer.assembled!);
      return file.path;
    } catch (e) {
      return _saveToAppDocs(transfer);
    }
  }

  static Future<String> _saveToAppDocs(Transfer transfer) async {
    final dir = await getApplicationDocumentsDirectory();
    final filename = _generateFilename(transfer);
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(transfer.assembled!);
    return file.path;
  }

  static String _generateFilename(Transfer transfer) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ext = _guessExtension(transfer);
    return 'porter-$timestamp$ext';
  }

  static String _guessExtension(Transfer transfer) {
    if (transfer.mode == 'T') return '.txt';
    if (transfer.assembled == null || transfer.assembled!.isEmpty) return '.bin';

    final bytes = transfer.assembled!;
    if (bytes.length >= 4) {
      // PNG
      if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47) {
        return '.png';
      }
      // JPG
      if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
        return '.jpg';
      }
      // PDF
      if (bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46) {
        return '.pdf';
      }
      // ZIP
      if (bytes[0] == 0x50 && bytes[1] == 0x4b && bytes[2] == 0x03 && bytes[3] == 0x04) {
        return '.zip';
      }
    }

    return '.bin';
  }
}
