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
