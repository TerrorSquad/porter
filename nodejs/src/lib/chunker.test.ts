
import { test } from 'node:test';
import assert from 'node:assert';
import { Chunker } from './chunker';

test('Chunker splits content correctly', () => {
  const content = Buffer.from('HelloWorld'.repeat(100)); // 1000 chars
  const chunker = new Chunker(content);

  // Mock options
  chunker.calculateLayout(24, {
    buffer: 10,
    useBase64: false,
    addHeader: true
  });

  assert.ok(chunker.chunks.length > 0, 'Should create chunks');

  // Verify header format
  const firstChunk = chunker.chunks[0];
  assert.match(firstChunk, /^\d+\|\d+\|/, 'Chunk should start with header index|total|');
});

test('Chunker handles base64', () => {
    const input = Buffer.from([0, 1, 2, 3, 255]);
    const chunker = new Chunker(input);
    // Use larger rows to ensure V1 capacity doesn't split this tiny payload
    chunker.calculateLayout(40, {
        buffer: 10,
        useBase64: true,
        addHeader: true
    });

    // Header + Base64
    const firstChunk = chunker.chunks[0];
    const parts = firstChunk.split('|');
    // We added 'mode' flag, so now 4 parts: index|total|mode|payload
    assert.strictEqual(parts.length, 4);

    const payload = parts[3];
    const checkBuf = Buffer.from(payload, 'base64');
    assert.deepStrictEqual(checkBuf, input);
});
