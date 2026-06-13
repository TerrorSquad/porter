/// Formats a byte count as a human-readable string (B/KB/MB/GB, 1 decimal place).
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  double size = bytes.toDouble();
  var unitIndex = 0;

  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }

  final formatted = unitIndex == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return '$formatted ${units[unitIndex]}';
}

/// Formats a [Duration] as a compact human-readable string, e.g. "850ms",
/// "12.3s", "1m 05s".
String formatDuration(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
  if (d.inSeconds < 60) {
    final tenths = (d.inMilliseconds % 1000) ~/ 100;
    return '${d.inSeconds}.${tenths}s';
  }
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
}

/// Condenses a sorted list of chunk indices into comma-separated ranges,
/// e.g. [1, 2, 3, 5, 7, 8] -> "1-3, 5, 7-8". Caps the output at [maxRanges]
/// ranges, appending "+N more" for the remainder.
String formatChunkRanges(List<int> indices, {int maxRanges = 8}) {
  if (indices.isEmpty) return '';

  final ranges = <String>[];
  var start = indices.first;
  var end = indices.first;

  void flush() {
    ranges.add(start == end ? '$start' : '$start-$end');
  }

  for (final index in indices.skip(1)) {
    if (index == end + 1) {
      end = index;
    } else {
      flush();
      start = index;
      end = index;
    }
  }
  flush();

  if (ranges.length > maxRanges) {
    final shown = ranges.take(maxRanges).join(', ');
    return '$shown, +${ranges.length - maxRanges} more';
  }
  return ranges.join(', ');
}
