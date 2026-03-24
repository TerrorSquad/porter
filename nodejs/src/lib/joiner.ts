// Porter — join subcommand (porter join)
// Mirrors golang/join.go + transfer_manifest.go

import fs from 'fs';
import path from 'path';
import crypto from 'crypto';

interface PartEntry {
  index: number;
  fileName: string;
}

function alphaPartSuffix(index: number): string {
  let value = index;
  let suffix = '';
  do {
    suffix = String.fromCharCode('a'.charCodeAt(0) + (value % 26)) + suffix;
    value = Math.floor(value / 26);
  } while (value > 0);
  while (suffix.length < 2) suffix = 'a' + suffix;
  return suffix;
}

function scanPartFiles(dir: string, base: string): PartEntry[] {
  const prefix = `${base}.part`;
  const results: PartEntry[] = [];
  let max = 0;

  for (const entry of fs.readdirSync(dir)) {
    if (!entry.startsWith(prefix)) continue;
    const suffix = entry.slice(prefix.length);
    let idx = 0;
    for (const ch of suffix) idx = idx * 26 + (ch.charCodeAt(0) - 97);
    idx += 1; // back to 1-based
    results.push({ index: idx, fileName: entry });
    if (idx > max) max = idx;
  }

  results.sort((a, b) => a.index - b.index);

  // Report gaps
  const seen = new Set(results.map((r) => r.index));
  for (let i = 1; i <= max; i++) {
    if (!seen.has(i)) {
      const name = `${base}.part${alphaPartSuffix(i - 1)}`;
      console.warn(`Warning: missing part ${i} (${name})`);
    }
  }

  return results.filter((r) => seen.has(r.index));
}

function loadChecksum(dir: string, base: string): string {
  const checksumFile = path.join(dir, `${base}.sha256`);
  if (!fs.existsSync(checksumFile)) return '';
  return fs.readFileSync(checksumFile, 'utf8').trim();
}

function resolveTransferDir(target: string): { dir: string; base: string } | null {
  // Direct path to a transfer directory
  if (fs.existsSync(target) && fs.statSync(target).isDirectory()) {
    const name = path.basename(target);
    return { dir: target, base: name };
  }

  // Path to any file inside a transfer directory
  if (fs.existsSync(target) && fs.statSync(target).isFile()) {
    const dir = path.dirname(target);
    const base = path.basename(dir);
    return { dir, base };
  }

  // Transfer ID or folder name in CWD
  const candidate = path.join(process.cwd(), target);
  if (fs.existsSync(candidate) && fs.statSync(candidate).isDirectory()) {
    return { dir: candidate, base: target };
  }

  return null;
}

export function runJoin(args: string[]): void {
  const targets: string[] = [];
  let outputFile = '';
  let force = false;
  let verify = true;

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--output' || a === '-o') {
      outputFile = args[++i] ?? '';
      continue;
    }
    if (a === '--force' || a === '-f') {
      force = true;
      continue;
    }
    if (a === '--no-verify') {
      verify = false;
      continue;
    }
    if (!a.startsWith('-')) {
      targets.push(a);
      continue;
    }
    console.error(`Unknown join flag: ${a}`);
    process.exit(1);
  }

  if (!targets.length) {
    console.error(
      'Usage: porter join <transfer-dir|file|id> [...] [--output <path>] [--force] [--no-verify]',
    );
    process.exit(1);
  }

  for (const target of targets) {
    const resolved = resolveTransferDir(target);
    if (!resolved) {
      console.error(`Error: cannot find transfer directory for "${target}"`);
      process.exit(1);
    }

    const { dir, base } = resolved;
    const parts = scanPartFiles(dir, base);
    if (!parts.length) {
      console.error(`Error: no part files found in ${dir}`);
      process.exit(1);
    }

    const dest = outputFile ? path.resolve(outputFile) : path.join(dir, `${base}.joined`);

    if (fs.existsSync(dest) && !force) {
      console.error(`Error: output file already exists: ${dest} (use --force to overwrite)`);
      process.exit(1);
    }

    const totalSize = parts.reduce(
      (sum, p) => sum + fs.statSync(path.join(dir, p.fileName)).size,
      0,
    );
    console.log(`Joining ${parts.length} parts (${totalSize} bytes total) → ${dest}`);

    const hash = crypto.createHash('sha256');
    const tmp = `${dest}.tmp.${process.pid}`;
    const fd = fs.openSync(tmp, 'w');
    try {
      for (const p of parts) {
        const data = fs.readFileSync(path.join(dir, p.fileName));
        fs.writeSync(fd, data);
        hash.update(data);
      }
    } finally {
      fs.closeSync(fd);
    }

    const actual = hash.digest('hex');
    console.log(`SHA-256: ${actual}`);

    if (verify) {
      const expected = loadChecksum(dir, base);
      if (expected) {
        if (expected.toLowerCase() !== actual.toLowerCase()) {
          fs.unlinkSync(tmp);
          console.error(`Checksum mismatch: expected ${expected}, got ${actual}`);
          process.exit(1);
        }
        console.log('Checksum verified ✓');
      } else {
        console.log('(no checksum file — skipping verification)');
      }
    }

    fs.renameSync(tmp, dest);
    const stat = fs.statSync(dest);
    console.log(`Joined: ${dest} (${stat.size} bytes)`);
  }
}
