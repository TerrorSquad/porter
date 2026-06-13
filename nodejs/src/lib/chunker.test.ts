import { test } from 'node:test';
import assert from 'node:assert';
import { Chunker } from './chunker.js';

test('Chunker splits content correctly', () => {
  const content = Buffer.from('HelloWorld'.repeat(100)); // 1000 chars
  const chunker = new Chunker(content);

  // Mock options
  chunker.calculateLayout(24, {
    buffer: 10,
    useBase64: false,
    addHeader: true,
  });

  assert.ok(chunker.chunks.length > 0, 'Should create chunks');

  // Verify header format
  const firstChunk = chunker.chunks[0];
  assert.match(
    firstChunk,
    /^\d+\|\d+\|[BT]\|..\|/,
    'Chunk should start with header index|total|mode|id|',
  );
});

test('Chunker handles base64', () => {
  const input = Buffer.from([0, 1, 2, 3, 255]);
  const chunker = new Chunker(input);
  // Use larger rows to ensure V1 capacity doesn't split this tiny payload
  chunker.calculateLayout(40, {
    buffer: 10,
    useBase64: true,
    addHeader: true,
  });

  // Header + Base64
  const firstChunk = chunker.chunks[0];
  const parts = firstChunk.split('|');
  assert.strictEqual(parts.length, 5);
  assert.match(parts[3], /^..$/, 'Chunk ID should be exactly 2 characters');

  const payload = parts[4];
  const checkBuf = Buffer.from(payload, 'base64');
  assert.deepStrictEqual(checkBuf, input);
});

test('version clamps to 1 when available rows are tiny', () => {
  const chunker = new Chunker(Buffer.from('hello world'));
  // rows - buffer <= 0 drives maxVer well below 1
  chunker.calculateLayout(10, { buffer: 10, useBase64: false });
  assert.strictEqual(chunker.version, 1);
});

test('version clamps to 40 when rows are huge', () => {
  const chunker = new Chunker(Buffer.from('hello world'));
  chunker.calculateLayout(1000, { buffer: 0, useBase64: false });
  assert.strictEqual(chunker.version, 40);
});

test('chunkSize floors to 50 when computed capacity is non-positive', () => {
  const chunker = new Chunker(Buffer.from('hello world'));
  // V1 + ECC H capacity (7) minus the 16-byte header is negative
  chunker.calculateLayout(10, { buffer: 10, useBase64: false, addHeader: true, eccLevel: 'H' });
  assert.strictEqual(chunker.version, 1);
  assert.strictEqual(chunker.chunkSize, 50);
});

test('addChecksum appends a CHECKSUM chunk matching getSha256()', () => {
  const content = Buffer.from('HelloWorld'.repeat(10));
  const chunker = new Chunker(content);
  chunker.calculateLayout(24, {
    buffer: 10,
    useBase64: false,
    addHeader: true,
    addChecksum: true,
  });

  const lastChunk = chunker.chunks[chunker.chunks.length - 1];
  assert.strictEqual(lastChunk, `CHECKSUM|T|${chunker.chunkId}|${chunker.getSha256()}`);
});

test('getMd5 returns the correct MD5 digest', () => {
  const chunker = new Chunker(Buffer.from('hello'));
  assert.strictEqual(chunker.getMd5(), '5d41402abc4b2a76b9719d911017c592');
});

test('base64 chunkSize is ~75% of the working capacity', () => {
  const chunker = new Chunker(Buffer.from('hello world'));
  // rows=15, buffer=0 -> version 2 -> ECC L capacity 32, minus 16-byte header = 16
  chunker.calculateLayout(15, { buffer: 0, useBase64: true, addHeader: true, eccLevel: 'L' });
  assert.strictEqual(chunker.version, 2);
  assert.strictEqual(chunker.chunkSize, Math.floor((32 - 16) * 0.75));
});
