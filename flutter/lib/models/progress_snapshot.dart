/// A lightweight, isolate-safe summary of one [Transfer]'s progress. Carries
/// only display-relevant scalars — never the chunk bytes themselves — so it
/// stays cheap to copy across the isolate boundary on every scan.
class ProgressSnapshot {
  final String id;
  final int total;
  final String mode;
  final String encoding;
  final int? fountainFileSize;
  final int fountainSymbols;
  final List<int> seenIndices;
  final int receivedBytes;
  final String? checksum;
  final bool? verified;
  final String? error;
  final bool isComplete;
  final DateTime createdAt;
  final DateTime? completedAt;

  const ProgressSnapshot({
    required this.id,
    required this.total,
    required this.mode,
    required this.encoding,
    required this.fountainFileSize,
    required this.fountainSymbols,
    required this.seenIndices,
    required this.receivedBytes,
    required this.checksum,
    required this.verified,
    required this.error,
    required this.isComplete,
    required this.createdAt,
    required this.completedAt,
  });
}
