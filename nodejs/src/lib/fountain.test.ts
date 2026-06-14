import { test } from 'node:test';
import assert from 'node:assert';
import { makeRng, buildDegreeTable, sampleIndices, FountainChunker } from './fountain.js';

// --- Golden vectors: PRNG ---
// These pin down xorshift32's output sequence. The Dart port
// (flutter/lib/services/fountain_codec.dart) must reproduce these exactly.

test('makeRng(0) produces the expected sequence', () => {
  const rng = makeRng(0);
  const values = [rng(), rng(), rng(), rng(), rng()];
  assert.deepStrictEqual(values, [1359758873, 3761132862, 2075758394, 25405621, 3862129951]);
});

test('makeRng(1) produces the expected sequence', () => {
  const rng = makeRng(1);
  const values = [rng(), rng(), rng(), rng(), rng()];
  assert.deepStrictEqual(values, [1359504952, 3827716927, 3866437631, 332804602, 1758100174]);
});

// --- Golden vectors: degree table ---

test('buildDegreeTable for k=1 and k=2 forces degree 1', () => {
  assert.deepStrictEqual(buildDegreeTable(1), { cumWeights: [0, 1], total: 1 });
  assert.deepStrictEqual(buildDegreeTable(2), { cumWeights: [0, 1], total: 1 });
});

test('buildDegreeTable for k=10 matches the golden table', () => {
  assert.deepStrictEqual(buildDegreeTable(10), {
    cumWeights: [0, 4, 10, 14, 15, 16, 17, 18, 19, 20, 21],
    total: 21,
  });
});

test('buildDegreeTable for k=100 matches the golden table', () => {
  const table = buildDegreeTable(100);
  assert.strictEqual(table.total, 214);
  assert.strictEqual(table.cumWeights[1], 11);
  assert.strictEqual(table.cumWeights[2], 66);
  assert.strictEqual(table.cumWeights[3], 85);
  assert.strictEqual(table.cumWeights[10], 124);
  assert.strictEqual(table.cumWeights[100], 214);
});

// --- Golden vectors: sampleIndices ---

test('sampleIndices for k=10 matches the golden (degree, indices) pairs', () => {
  assert.deepStrictEqual(sampleIndices(0, 10), { degree: 3, indices: [2, 3, 5] });
  assert.deepStrictEqual(sampleIndices(1, 10), { degree: 1, indices: [8] });
  assert.deepStrictEqual(sampleIndices(2, 10), { degree: 2, indices: [1, 7] });
  assert.deepStrictEqual(sampleIndices(3, 10), {
    degree: 9,
    indices: [1, 2, 3, 4, 5, 6, 7, 9, 10],
  });
  assert.deepStrictEqual(sampleIndices(4, 10), { degree: 2, indices: [1, 3] });
});

test('sampleIndices for k=1 always returns degree 1, index [1]', () => {
  for (let seq = 0; seq < 3; seq++) {
    assert.deepStrictEqual(sampleIndices(seq, 1), { degree: 1, indices: [1] });
  }
});

// --- FountainChunker ---

test('FountainChunker produces the expected shape for a small input', () => {
  const content = Buffer.from('Hello, fountain coding world! This is a test of LT codes.');
  const fc = new FountainChunker(content);
  fc.calculateLayout(24, { buffer: 10, useBase64: false, addHeader: true, eccLevel: 'L' });

  assert.strictEqual(fc.k, 4);
  assert.strictEqual(fc.blockSize, 16);
  assert.strictEqual(fc.version, 1);
  // N = max(k+20, ceil(k*3)) = max(24, 12) = 24, plus 1 checksum chunk
  assert.strictEqual(fc.chunks.length, 25);
  assert.strictEqual(fc.chunkId, 'dv');
  assert.strictEqual(
    fc.getSha256(),
    'e9f9a2e49367eda5c4c444fc2a3cdf0312fd73eeadfd6994f61951130d093687',
  );
  assert.strictEqual(fc.chunks[0], 'F|0|4|57|dv|aXMgaXMgYSB0ZXN0IG9mIA==');
  assert.strictEqual(fc.chunks[fc.chunks.length - 1], `CHECKSUM|T|dv|${fc.getSha256()}`);
});

test('FountainChunker chunks all match F|seq|k|fileSize|id|payload format', () => {
  const content = Buffer.from('x'.repeat(500));
  const fc = new FountainChunker(content);
  fc.calculateLayout(24, { buffer: 10, useBase64: false, addHeader: true, eccLevel: 'L' });

  for (let seq = 0; seq < fc.chunks.length - 1; seq++) {
    const parts = fc.chunks[seq].split('|');
    assert.strictEqual(parts[0], 'F');
    assert.strictEqual(parseInt(parts[1]), seq);
    assert.strictEqual(parseInt(parts[2]), fc.k);
    assert.strictEqual(parseInt(parts[3]), content.length);
    assert.strictEqual(parts[4], fc.chunkId);
    const payload = Buffer.from(parts[5], 'base64');
    assert.strictEqual(payload.length, fc.blockSize);
  }
});

test('a full pool of symbols fully reconstructs the original content via peeling decode', () => {
  const content = Buffer.from('The quick brown fox jumps over the lazy dog. '.repeat(20));
  const fc = new FountainChunker(content);
  fc.calculateLayout(24, { buffer: 10, useBase64: false, addHeader: true, eccLevel: 'L' });

  const k = fc.k;
  const blockSize = fc.blockSize;
  const symbols: { seq: number; payload: Buffer }[] = [];
  for (const c of fc.chunks) {
    if (c.startsWith('CHECKSUM')) continue;
    const parts = c.split('|');
    symbols.push({
      seq: parseInt(parts[1]),
      payload: Buffer.from(parts.slice(5).join('|'), 'base64'),
    });
  }

  const recovered = new Map<number, Buffer>();
  const pending = new Map<number, { unresolved: Set<number>; xor: Buffer }>();
  const indexToPending = new Map<number, Set<number>>();
  const queue: number[] = [];
  let nextId = 0;

  function resolveQueue() {
    while (queue.length > 0) {
      const id = queue.pop()!;
      const p = pending.get(id);
      if (!p || p.unresolved.size !== 1) continue;
      const idx = [...p.unresolved][0];
      pending.delete(id);
      if (recovered.has(idx)) continue;
      recovered.set(idx, p.xor);
      const refs = indexToPending.get(idx);
      if (refs) {
        for (const pid of refs) {
          const u = pending.get(pid);
          if (!u) continue;
          u.unresolved.delete(idx);
          for (let b = 0; b < blockSize; b++) u.xor[b] ^= p.xor[b];
          if (u.unresolved.size === 1) queue.push(pid);
          else if (u.unresolved.size === 0) pending.delete(pid);
        }
        indexToPending.delete(idx);
      }
    }
  }

  for (const { seq, payload } of symbols) {
    const { indices } = sampleIndices(seq, k);
    const xor = Buffer.from(payload);
    const unresolved = new Set<number>();
    for (const idx of indices) {
      const rb = recovered.get(idx);
      if (rb) {
        for (let b = 0; b < blockSize; b++) xor[b] ^= rb[b];
      } else {
        unresolved.add(idx);
      }
    }
    const id = nextId++;
    if (unresolved.size === 0) continue;
    if (unresolved.size === 1) {
      pending.set(id, { unresolved, xor });
      queue.push(id);
      resolveQueue();
    } else {
      pending.set(id, { unresolved, xor });
      for (const idx of unresolved) {
        if (!indexToPending.has(idx)) indexToPending.set(idx, new Set());
        indexToPending.get(idx)!.add(id);
      }
    }
  }

  assert.strictEqual(recovered.size, k, 'all source blocks should be recoverable');

  const blocks: Buffer[] = [];
  for (let i = 1; i <= k; i++) blocks.push(recovered.get(i)!);
  const assembled = Buffer.concat(blocks).subarray(0, content.length);
  assert.deepStrictEqual(assembled, content);
});
