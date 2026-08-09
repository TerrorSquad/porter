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
  if (d.inHours < 1) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }
  // Large transfers run for hours; "196m 00s" is unreadable next to "3h 16m".
  return '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
}

/// Rounds a duration to a coarse, honest-looking ETA — "~2h 30m", not
/// "2h 27m 13s". The underlying rate estimate is noisy enough that extra
/// precision would be false confidence.
String formatEta(Duration d) {
  if (d.inMinutes < 1) return 'under a minute';
  if (d.inHours < 1) return '~${d.inMinutes} min';
  final halves = (d.inMinutes / 30).round() * 30;
  return '~${halves ~/ 60}h ${(halves % 60).toString().padLeft(2, '0')}m';
}

/// Explains what a fountain transfer is doing right now, and how much longer
/// it needs, given the current rate of *new* symbols per second.
///
/// A single static "keep scanning" line was the old behaviour, and it read
/// identically at 5% and 95% — with blocks pinned near zero for most of the
/// run, that made a healthy transfer indistinguishable from a hung one.
String fountainHint({
  required int symbols,
  required int symbolsNeeded,
  required int blocks,
  required int totalBlocks,
  required double newPerSecond,
}) {
  if (symbols >= symbolsNeeded && blocks < totalBlocks) {
    return 'Decoding — blocks are being recovered now, keep the codes in view';
  }

  final remaining = symbolsNeeded - symbols;
  if (remaining <= 0) return 'Collecting the last few symbols…';

  final pct = (symbols / symbolsNeeded * 100).clamp(0, 99).toStringAsFixed(0);

  // Which phase the transfer is in changes what the user should expect, and
  // saying the wrong one is worse than saying nothing. Before the avalanche
  // blocks really do sit near zero and a flat count is normal; afterwards
  // each new symbol decodes roughly one block, and claiming otherwise makes
  // healthy progress look wrong. Measured on a real transfer: 68752 symbols
  // for 4344 blocks early on, then 28839 symbols for 28103 blocks later.
  final decoding = blocks > totalBlocks * 0.1;
  final phase = decoding
      ? 'blocks are decoding as symbols arrive'
      : 'blocks stay near 0 until enough symbols are in';

  if (newPerSecond <= 0) {
    return 'Collecting symbols: $pct% — $phase';
  }

  final eta = formatEta(Duration(seconds: (remaining / newPerSecond).round()));
  return 'Collecting symbols: $pct% · $eta left — $phase';
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
