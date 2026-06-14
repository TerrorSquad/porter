import { test } from 'node:test';
import assert from 'node:assert';
import { FountainChunker } from './fountain.js';
import { FountainDecoder } from './fountain-decoder.js';

/** Encodes `content` with FountainChunker and returns the (seq, payload)
 * symbols plus the transfer's k/blockSize/checksum, mirroring what a receiver
 * sees on the wire. */
function encode(content: Buffer) {
  const fc = new FountainChunker(content);
  fc.calculateLayout(24, { buffer: 10, useBase64: false, addHeader: true, eccLevel: 'L' });
  const symbols: { seq: number; payload: Buffer }[] = [];
  for (const c of fc.chunks) {
    if (c.startsWith('CHECKSUM')) continue;
    const parts = c.split('|');
    symbols.push({
      seq: parseInt(parts[1]),
      payload: Buffer.from(parts.slice(5).join('|'), 'base64'),
    });
  }
  return { fc, symbols };
}

test('recovers the original file from the full symbol pool', () => {
  const content = Buffer.from('The quick brown fox jumps over the lazy dog. '.repeat(20));
  const { fc, symbols } = encode(content);

  const decoder = new FountainDecoder(fc.k, fc.blockSize);
  for (const s of symbols) {
    decoder.addSymbol(s.seq, s.payload);
    if (decoder.isComplete) break;
  }

  assert.strictEqual(decoder.isComplete, true);
  assert.deepStrictEqual(decoder.assemble().subarray(0, content.length), content);
});

test('recovers from a shuffled, lossy symbol stream', () => {
  const content = Buffer.from('order-independent fountain recovery '.repeat(20));
  const { fc, symbols } = encode(content);

  // Drop every 4th symbol and reverse the rest.
  const delivered = symbols.filter((_, i) => i % 4 !== 0).reverse();

  const decoder = new FountainDecoder(fc.k, fc.blockSize);
  for (const s of delivered) decoder.addSymbol(s.seq, s.payload);

  assert.strictEqual(decoder.isComplete, true);
  assert.deepStrictEqual(decoder.assemble().subarray(0, content.length), content);
});

test('completes via Gaussian-elimination fallback when peeling stalls (k=11)', () => {
  // 164 bytes at blockSize 16 → k=11, a case where pure peeling stalls on a
  // stuck core even with the full in-order pool.
  const content = Buffer.from(Array.from({ length: 164 }, (_, i) => (i * 37 + 11) & 0xff));
  const { fc, symbols } = encode(content);
  assert.strictEqual(fc.k, 11);

  const decoder = new FountainDecoder(fc.k, fc.blockSize);
  for (const s of symbols) decoder.addSymbol(s.seq, s.payload);

  assert.strictEqual(decoder.isComplete, true);
  assert.deepStrictEqual(decoder.assemble().subarray(0, content.length), content);
});

test('ignores duplicate seqs and tracks distinct symbol count', () => {
  const content = Buffer.from('dedupe me '.repeat(8));
  const { fc, symbols } = encode(content);

  const decoder = new FountainDecoder(fc.k, fc.blockSize);
  decoder.addSymbol(symbols[0].seq, symbols[0].payload);
  decoder.addSymbol(symbols[0].seq, symbols[0].payload); // duplicate
  assert.strictEqual(decoder.symbolCount, 1);
});
