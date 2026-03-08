import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const distDir = path.resolve('dist');
const targets = fs.existsSync(distDir)
  ? fs.readdirSync(distDir)
      .filter(fileName => fileName.endsWith('.mjs'))
      .sort()
  : [];

function formatBytes(size) {
  if (size < 1024) {
    return `${size} B`;
  }

  const units = ['KB', 'MB', 'GB'];
  let value = size;
  let unitIndex = -1;

  do {
    value /= 1024;
    unitIndex++;
  } while (value >= 1024 && unitIndex < units.length - 1);

  return `${value.toFixed(1)} ${units[unitIndex]}`;
}

function readSizeReport(fileName) {
  const filePath = path.join(distDir, fileName);
  if (!fs.existsSync(filePath)) {
    return null;
  }

  const content = fs.readFileSync(filePath);
  return {
    fileName,
    bytes: content.length,
    gzipBytes: zlib.gzipSync(content).length,
  };
}

const reports = targets
  .map(readSizeReport)
  .filter(Boolean);

if (reports.length === 0) {
  console.log('No build outputs found in dist/.');
  process.exit(0);
}

console.log('Porter build sizes:');
for (const report of reports) {
  console.log(
    `  ${report.fileName.padEnd(24)} ${String(report.bytes).padStart(8)} bytes  ${formatBytes(report.bytes).padStart(8)}  gzip ${formatBytes(report.gzipBytes).padStart(8)}`
  );
}

const smallestReport = reports.reduce((smallest, current) =>
  current.bytes < smallest.bytes ? current : smallest
);
const largestReport = reports.reduce((largest, current) =>
  current.bytes > largest.bytes ? current : largest
);

if (smallestReport.fileName !== largestReport.fileName) {
  const saved = largestReport.bytes - smallestReport.bytes;
  const ratio = largestReport.bytes > 0 ? (1 - smallestReport.bytes / largestReport.bytes) * 100 : 0;
  console.log(`  ${`delta ${smallestReport.fileName}`.padEnd(24)} ${String(saved).padStart(8)} bytes  ${ratio.toFixed(1)}% smaller than ${largestReport.fileName}`);
}