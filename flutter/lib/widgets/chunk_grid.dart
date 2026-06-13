import 'package:flutter/material.dart';

/// A compact grid of small squares showing which chunks have been received.
///
/// Chunks are grouped into buckets so the grid never exceeds [maxCells]
/// squares, regardless of [total]. Each cell is green when every chunk in
/// its bucket has been received, amber when some but not all have, and grey
/// when none have.
class ChunkGrid extends StatelessWidget {
  static const int maxCells = 400;

  final int total;
  final Set<int> seenIndices;

  const ChunkGrid({super.key, required this.total, required this.seenIndices});

  @override
  Widget build(BuildContext context) {
    if (total <= 0) return const SizedBox.shrink();

    final bucketSize = (total / maxCells).ceil();
    final bucketCount = (total / bucketSize).ceil();

    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (var bucket = 0; bucket < bucketCount; bucket++) _buildCell(bucket, bucketSize),
      ],
    );
  }

  Widget _buildCell(int bucket, int bucketSize) {
    final start = bucket * bucketSize + 1;
    final end = ((bucket + 1) * bucketSize).clamp(0, total);

    var received = 0;
    for (var i = start; i <= end; i++) {
      if (seenIndices.contains(i)) received++;
    }

    final count = end - start + 1;
    final Color color;
    if (received == 0) {
      color = Colors.grey.shade800;
    } else if (received == count) {
      color = Colors.green.shade400;
    } else {
      color = Colors.amber.shade600;
    }

    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1)),
    );
  }
}
