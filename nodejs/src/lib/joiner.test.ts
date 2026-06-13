import { test, describe } from 'node:test';
import assert from 'node:assert';
import fs from 'fs';
import os from 'os';
import path from 'path';
import crypto from 'crypto';
import { runJoin } from './joiner.js';

function makeTmpDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'porter-joiner-'));
}

function sha256Hex(content: Buffer): string {
  return crypto.createHash('sha256').update(content).digest('hex');
}

/** Captures console.log/warn/error output produced while `fn` runs. */
function captureConsole<T>(fn: () => T): {
  result: T;
  logs: string[];
  warns: string[];
  errors: string[];
} {
  const logs: string[] = [];
  const warns: string[] = [];
  const errors: string[] = [];
  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;
  console.log = (...args: unknown[]) => logs.push(args.map(String).join(' '));
  console.warn = (...args: unknown[]) => warns.push(args.map(String).join(' '));
  console.error = (...args: unknown[]) => errors.push(args.map(String).join(' '));
  try {
    const result = fn();
    return { result, logs, warns, errors };
  } finally {
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
  }
}

/** Runs runJoin, intercepting process.exit so the test process keeps running. */
function runJoinCapturing(args: string[]): {
  exitCode: number | undefined;
  logs: string[];
  warns: string[];
  errors: string[];
} {
  const logs: string[] = [];
  const warns: string[] = [];
  const errors: string[] = [];
  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;
  const origExit = process.exit;
  let exitCode: number | undefined;

  console.log = (...args: unknown[]) => logs.push(args.map(String).join(' '));
  console.warn = (...args: unknown[]) => warns.push(args.map(String).join(' '));
  console.error = (...args: unknown[]) => errors.push(args.map(String).join(' '));
  process.exit = ((code?: number) => {
    exitCode = code;
    throw new Error('__process_exit__');
  }) as unknown as typeof process.exit;

  try {
    runJoin(args);
  } catch (e) {
    if (!(e instanceof Error && e.message === '__process_exit__')) throw e;
  } finally {
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
    process.exit = origExit;
  }

  return { exitCode, logs, warns, errors };
}

describe('runJoin', () => {
  test('joins alphabetic parts and verifies the checksum', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'porter-joiner-'));
    try {
      const base = path.basename(dir);
      const partA = Buffer.from('Hello, ');
      const partB = Buffer.from('World!');
      fs.writeFileSync(path.join(dir, `${base}.partaa`), partA);
      fs.writeFileSync(path.join(dir, `${base}.partab`), partB);
      fs.writeFileSync(path.join(dir, `${base}.sha256`), sha256Hex(Buffer.concat([partA, partB])));

      const { result, logs } = captureConsole(() => runJoin([dir]));
      assert.strictEqual(result, undefined);

      const joined = fs.readFileSync(path.join(dir, `${base}.joined`));
      assert.strictEqual(joined.toString(), 'Hello, World!');
      assert.ok(logs.some((l) => l.includes('Checksum verified')));
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('warns about a missing part but still joins what is present', () => {
    const dir = makeTmpDir();
    try {
      const base = path.basename(dir);
      fs.writeFileSync(path.join(dir, `${base}.partaa`), 'AAA');
      // .partab intentionally missing
      fs.writeFileSync(path.join(dir, `${base}.partac`), 'CCC');

      const { logs, warns } = captureConsole(() => runJoin([dir]));

      assert.ok(warns.some((w) => w.includes(`missing part 2 (${base}.partab)`)));
      assert.ok(logs.some((l) => l.includes('no checksum file')));

      const joined = fs.readFileSync(path.join(dir, `${base}.joined`));
      assert.strictEqual(joined.toString(), 'AAACCC');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('exits with an error on checksum mismatch', () => {
    const dir = makeTmpDir();
    try {
      const base = path.basename(dir);
      fs.writeFileSync(path.join(dir, `${base}.partaa`), 'content');
      fs.writeFileSync(path.join(dir, `${base}.sha256`), 'not-the-real-checksum');

      const { exitCode, errors } = runJoinCapturing([dir]);
      assert.strictEqual(exitCode, 1);
      assert.ok(errors.some((e) => e.includes('Checksum mismatch')));
      assert.ok(!fs.existsSync(path.join(dir, `${base}.joined`)));
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--no-verify skips checksum verification even if it would mismatch', () => {
    const dir = makeTmpDir();
    try {
      const base = path.basename(dir);
      fs.writeFileSync(path.join(dir, `${base}.partaa`), 'content');
      fs.writeFileSync(path.join(dir, `${base}.sha256`), 'not-the-real-checksum');

      const { exitCode } = runJoinCapturing([dir, '--no-verify']);
      assert.strictEqual(exitCode, undefined);

      const joined = fs.readFileSync(path.join(dir, `${base}.joined`));
      assert.strictEqual(joined.toString(), 'content');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('refuses to overwrite an existing output file without --force', () => {
    const dir = makeTmpDir();
    try {
      const base = path.basename(dir);
      fs.writeFileSync(path.join(dir, `${base}.partaa`), 'new-content');
      fs.writeFileSync(path.join(dir, `${base}.joined`), 'old-content');

      const { exitCode, errors } = runJoinCapturing([dir]);
      assert.strictEqual(exitCode, 1);
      assert.ok(errors.some((e) => e.includes('already exists')));
      assert.strictEqual(fs.readFileSync(path.join(dir, `${base}.joined`), 'utf8'), 'old-content');

      const { exitCode: forcedExit } = runJoinCapturing([dir, '--force']);
      assert.strictEqual(forcedExit, undefined);
      assert.strictEqual(fs.readFileSync(path.join(dir, `${base}.joined`), 'utf8'), 'new-content');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('errors when given no targets', () => {
    const { exitCode, errors } = runJoinCapturing([]);
    assert.strictEqual(exitCode, 1);
    assert.ok(errors.some((e) => e.includes('Usage: porter join')));
  });

  test('errors when the transfer directory cannot be resolved', () => {
    const { exitCode, errors } = runJoinCapturing(['definitely-does-not-exist-xyz']);
    assert.strictEqual(exitCode, 1);
    assert.ok(errors.some((e) => e.includes('cannot find transfer directory')));
  });

  test('errors when no part files are found', () => {
    const dir = makeTmpDir();
    try {
      const { exitCode, errors } = runJoinCapturing([dir]);
      assert.strictEqual(exitCode, 1);
      assert.ok(errors.some((e) => e.includes('no part files found')));
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});
