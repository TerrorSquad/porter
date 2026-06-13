import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/transfer.dart';

class FileHandler {
  /// Saves the assembled transfer to [outputDirectory] if given (creating it
  /// if necessary), otherwise to the default downloads directory
  /// (~/Downloads on macOS), falling back to the app's documents directory.
  static Future<String> saveFile(Transfer transfer, {String? outputDirectory}) async {
    if (transfer.assembled == null) {
      throw Exception('No assembled data to save');
    }

    final dir = await resolveOutputDirectory(outputDirectory);
    final filename = _generateFilename(transfer);
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(transfer.assembled!);
    return file.path;
  }

  /// Resolves the directory transfers are saved to: [outputDirectory] if
  /// given (creating it if necessary), otherwise the default downloads
  /// directory (~/Downloads on macOS), falling back to the app's documents
  /// directory.
  static Future<Directory> resolveOutputDirectory(String? outputDirectory) async {
    if (outputDirectory != null && outputDirectory.isNotEmpty) {
      final dir = Directory(outputDirectory);
      await dir.create(recursive: true);
      return dir;
    }

    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir;
    } catch (e) {
      // Fall through to app documents.
    }

    return getApplicationDocumentsDirectory();
  }

  static String _generateFilename(Transfer transfer) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ext = guessExtension(transfer);
    return 'porter-$timestamp$ext';
  }

  static String guessExtension(Transfer transfer) {
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
