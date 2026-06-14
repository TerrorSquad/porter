import { test } from 'node:test';
import assert from 'node:assert';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import type { AddressInfo } from 'node:net';
import { FountainChunker } from './fountain.js';
import { runReceiver } from './receiver.js';

interface PostResponse {
  status: number;
  body: string;
}

/** POSTs a QR-scan JSON upload ({content}) the way the Flutter relay does. */
function postScan(port: number, content: string): Promise<PostResponse> {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ content });
    const req = http.request(
      {
        host: '127.0.0.1',
        port,
        path: '/upload',
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c) => chunks.push(c as Buffer));
        res.on('end', () =>
          resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') }),
        );
      },
    );
    req.on('error', reject);
    req.end(body);
  });
}

test('porter serve decodes a fountain transfer end-to-end and verifies it', async () => {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'porter-serve-fountain-'));
  const server = runReceiver({ host: '127.0.0.1', port: '0', 'output-dir': outDir });
  await once(server, 'listening');
  const port = (server.address() as AddressInfo).port;

  try {
    const content = Buffer.from('Fountain coding over the porter serve relay! '.repeat(30));
    const fc = new FountainChunker(content);
    fc.calculateLayout(24, { buffer: 10, useBase64: false, addHeader: true, eccLevel: 'L' });

    let last: Record<string, unknown> = {};
    for (const chunk of fc.chunks) {
      const res = await postScan(port, chunk);
      assert.strictEqual(res.status, 200, `chunk rejected: ${res.body}`);
      last = JSON.parse(res.body);
    }

    // The final (checksum) frame should report a complete, verified transfer.
    assert.strictEqual(last.complete, true);
    assert.strictEqual(last.verified, true);

    const joinedPath = last.joinedPath as string;
    assert.ok(joinedPath, 'expected a joinedPath in the response');
    assert.deepStrictEqual(fs.readFileSync(joinedPath), content);
  } finally {
    server.close();
    await once(server, 'close');
    fs.rmSync(outDir, { recursive: true, force: true });
  }
});

test('porter serve recovers a fountain transfer from a lossy, shuffled relay', async () => {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'porter-serve-fountain-'));
  const server = runReceiver({ host: '127.0.0.1', port: '0', 'output-dir': outDir });
  await once(server, 'listening');
  const port = (server.address() as AddressInfo).port;

  try {
    const content = Buffer.from('lossy shuffled fountain relay path '.repeat(25));
    const fc = new FountainChunker(content);
    fc.calculateLayout(24, { buffer: 10, useBase64: false, addHeader: true, eccLevel: 'L' });

    const symbols = fc.chunks.filter((c) => c.startsWith('F|'));
    const checksum = fc.chunks.find((c) => c.startsWith('CHECKSUM|'))!;

    // Drop every 4th symbol, reverse the rest, then send the checksum.
    const delivered = symbols.filter((_, i) => i % 4 !== 0).reverse();

    let last: Record<string, unknown> = {};
    for (const chunk of [...delivered, checksum]) {
      const res = await postScan(port, chunk);
      assert.strictEqual(res.status, 200, `chunk rejected: ${res.body}`);
      last = JSON.parse(res.body);
    }

    assert.strictEqual(last.complete, true);
    assert.strictEqual(last.verified, true);
    assert.deepStrictEqual(fs.readFileSync(last.joinedPath as string), content);
  } finally {
    server.close();
    await once(server, 'close');
    fs.rmSync(outDir, { recursive: true, force: true });
  }
});
