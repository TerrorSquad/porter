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
