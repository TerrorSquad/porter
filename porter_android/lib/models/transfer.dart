class Transfer {
  final String id;
  int total = 0;
  String mode = 'T';
  Map<int, List<int>> chunks = {}; // index -> bytes
  Set<int> seenIndices = {};
  String? checksum;
  List<int>? assembled;
  bool? verified;
  String? error;
  DateTime createdAt;
  DateTime? completedAt;

  Transfer({
    required this.id,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  int get progress => total > 0 ? ((seenIndices.length / total) * 100).round() : 0;
  bool get isComplete => total > 0 && seenIndices.length == total;

  void addChunk(int index, List<int> data) {
    if (!seenIndices.contains(index)) {
      seenIndices.add(index);
      chunks[index] = data;
    }
  }

  void reset() {
    total = 0;
    mode = 'T';
    chunks.clear();
    seenIndices.clear();
    checksum = null;
    assembled = null;
    verified = null;
    error = null;
    completedAt = null;
  }
}
