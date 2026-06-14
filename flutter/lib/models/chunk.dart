class DataChunk {
  final int index;
  final int total;
  final String mode; // 'T' = text, 'B' = binary, 'C' = compressed
  final String id;
  final String payload;

  DataChunk({
    required this.index,
    required this.total,
    required this.mode,
    required this.id,
    required this.payload,
  });

  factory DataChunk.fromQRString(String raw) {
    final parts = raw.split('|');
    if (parts.length < 5) throw FormatException('Invalid chunk format');

    return DataChunk(
      index: int.parse(parts[0]),
      total: int.parse(parts[1]),
      mode: parts[2],
      id: parts[3],
      payload: parts.sublist(4).join('|'), // payload may contain |
    );
  }
}

/// A fountain (LT code) symbol: `F|seq|K|fileSize|id|payload`. Unlike
/// [DataChunk], `seq` is just a PRNG seed — the source-block indices it
/// combines are derived from it, not transmitted. See FountainDecoder.
class FountainChunk {
  final int seq;
  final int k;
  final int fileSize;
  final String id;
  final String payload; // base64 of the XOR'd block

  FountainChunk({
    required this.seq,
    required this.k,
    required this.fileSize,
    required this.id,
    required this.payload,
  });

  factory FountainChunk.fromQRString(String raw) {
    final parts = raw.split('|');
    if (parts.length < 6 || parts[0] != 'F') {
      throw FormatException('Invalid fountain chunk format');
    }

    return FountainChunk(
      seq: int.parse(parts[1]),
      k: int.parse(parts[2]),
      fileSize: int.parse(parts[3]),
      id: parts[4],
      payload: parts.sublist(5).join('|'), // payload may contain |
    );
  }
}

class ChecksumChunk {
  final String id;
  final String checksum;

  ChecksumChunk({required this.id, required this.checksum});

  factory ChecksumChunk.fromQRString(String raw) {
    if (!raw.startsWith('CHECKSUM|')) throw FormatException('Not a checksum');
    final parts = raw.split('|');
    if (parts.length < 4) throw FormatException('Invalid checksum format');
    return ChecksumChunk(id: parts[2], checksum: parts[3]);
  }
}
