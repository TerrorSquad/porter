import '../models/chunk.dart';

class ChunkParser {
  /// Parse a QR code string into either a DataChunk or ChecksumChunk
  static dynamic parseQR(String raw) {
    raw = raw.trim();
    if (raw.isEmpty) return null;

    // Try checksum format: CHECKSUM|T|id|sha256
    if (raw.startsWith('CHECKSUM|')) {
      try {
        return ChecksumChunk.fromQRString(raw);
      } catch (e) {
        return null;
      }
    }

    // Try data format: index|total|mode|id|payload
    try {
      return DataChunk.fromQRString(raw);
    } catch (e) {
      return null;
    }
  }
}
