// Porter — HTTP receiver (porter serve)
// Mirrors golang/receiver.go + transfer_manifest.go

import http from 'http';
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import os from 'os';
import { FountainDecoder } from './fountain-decoder.js';

// ── Naming helpers ────────────────────────────────────────────────────────────

function chunkFileBase(id: string): string {
  const cleaned = id.replace(/[/\\\x00-\x1f]/g, '_').trim();
  return cleaned || 'chunk';
}

function alphaPartSuffix(index: number): string {
  if (index < 0) return 'aa';
  let value = index;
  let suffix = '';
  do {
    suffix = String.fromCharCode('a'.charCodeAt(0) + (value % 26)) + suffix;
    value = Math.floor(value / 26);
  } while (value > 0);
  while (suffix.length < 2) suffix = 'a' + suffix;
  return suffix;
}

function transferDirectory(outputDir: string, id: string): string {
  return path.join(outputDir, chunkFileBase(id));
}

function transferManifestPath(outputDir: string, id: string): string {
  const base = chunkFileBase(id);
  return path.join(transferDirectory(outputDir, id), `${base}.meta.json`);
}

function transferJoinPath(outputDir: string, id: string): string {
  const base = chunkFileBase(id);
  return path.join(transferDirectory(outputDir, id), `${base}.joined`);
}

function chunkPartFileName(id: string, index: number): string {
  return `${chunkFileBase(id)}.part${alphaPartSuffix(index - 1)}`;
}

function chunkChecksumFileName(id: string): string {
  return `${chunkFileBase(id)}.sha256`;
}

// ── Types ─────────────────────────────────────────────────────────────────────

interface QRScanUpload {
  content?: string;
  raw?: string;
  format?: string;
}

interface QRChunkUpload {
  index: number;
  total: number;
  mode: string;
  id: string;
  payload: Buffer;
  isChecksum: boolean;
  checksum?: string;
}

export interface TransferManifest {
  id: string;
  directory: string;
  totalParts: number;
  receivedParts: number;
  missingParts: number[];
  partFiles: string[];
  checksum?: string;
  checksumFile?: string;
  joinedFile?: string;
  joinedSHA256?: string;
  checksumVerified: boolean;
  complete: boolean;
  updatedAt: string;
  [key: string]: unknown;
}

export interface UploadResult {
  fileName: string;
  path: string;
  size: number;
  duplicate?: boolean;
  existingPath?: string;
  sha256?: string;
  transferId?: string;
  manifestPath?: string;
  complete?: boolean;
  verified?: boolean;
  joinedPath?: string;
}

// ── Per-transfer async lock ───────────────────────────────────────────────────

const transferLocks = new Map<string, Promise<void>>();

function withTransferLock<T>(id: string, fn: () => Promise<T>): Promise<T> {
  const key = chunkFileBase(id);
  const prev = transferLocks.get(key) ?? Promise.resolve();
  let release!: () => void;
  const slot = new Promise<void>((r) => {
    release = r;
  });
  transferLocks.set(
    key,
    prev.then(() => slot),
  );
  return prev.then(() => fn()).finally(release);
}

// ── QR parsing ────────────────────────────────────────────────────────────────

function normalizeFormat(fmt: string): string {
  return fmt.toUpperCase().replace(/_/g, '');
}

function tryParseQRScanUpload(body: Buffer): QRScanUpload | null {
  const s = body.toString('utf8').trim();
  if (!s.startsWith('{')) return null;
  try {
    const obj = JSON.parse(s) as Record<string, unknown>;
    const content = typeof obj.content === 'string' ? obj.content : '';
    const raw = typeof obj.raw === 'string' ? obj.raw : '';
    const format = typeof obj.format === 'string' ? obj.format : '';
    if (!content.trim() && !raw.trim()) return null;
    if (format.trim() && normalizeFormat(format.trim()) !== 'QRCODE') return null;
    return { content, raw, format };
  } catch {
    return null;
  }
}

function qrScanBytes(upload: QRScanUpload): Buffer {
  if (upload.raw?.trim()) return Buffer.from(upload.raw.trim(), 'hex');
  return Buffer.from(upload.content ?? '', 'utf8');
}

function validateChunkID(id: string): boolean {
  return [...id].length === 2;
}

function parseQRChunk(raw: Buffer): QRChunkUpload | null {
  const s = raw.toString('utf8');

  if (s.startsWith('CHECKSUM|')) {
    const p = s.split('|');
    if (p.length < 4) return null;
    const mode = p[1];
    if (mode !== 'T') return null;
    const id = p[2];
    if (!validateChunkID(id)) return null;
    const checksum = p.slice(3).join('|').trim();
    if (!checksum) return null;
    return { index: 0, total: 0, mode, id, payload: Buffer.alloc(0), isChecksum: true, checksum };
  }

  // index|total|mode|id|payload  (payload may contain '|')
  const p1 = s.indexOf('|');
  if (p1 < 0) return null;
  const p2 = s.indexOf('|', p1 + 1);
  if (p2 < 0) return null;
  const p3 = s.indexOf('|', p2 + 1);
  if (p3 < 0) return null;
  const p4 = s.indexOf('|', p3 + 1);
  if (p4 < 0) return null;

  const index = parseInt(s.slice(0, p1), 10);
  if (!Number.isInteger(index) || index < 1) return null;
  const total = parseInt(s.slice(p1 + 1, p2), 10);
  if (!Number.isInteger(total) || total < 1) return null;
  const mode = s.slice(p2 + 1, p3);
  const id = s.slice(p3 + 1, p4);
  if (!validateChunkID(id)) return null;
  const payloadStr = s.slice(p4 + 1);

  let payload: Buffer;
  if (mode === 'B') {
    payload = Buffer.from(payloadStr, 'base64');
  } else if (mode === 'T') {
    payload = Buffer.from(payloadStr, 'utf8');
  } else {
    return null;
  }

  return { index, total, mode, id, payload, isChecksum: false };
}

// ── Manifest ──────────────────────────────────────────────────────────────────

function sha256hex(data: Buffer): string {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function scanPartFiles(
  transferDir: string,
  base: string,
): { parts: Map<number, string>; maxIndex: number } {
  const parts = new Map<number, string>();
  let maxIndex = 0;
  if (!fs.existsSync(transferDir)) return { parts, maxIndex };

  const prefix = `${base}.part`;
  for (const entry of fs.readdirSync(transferDir)) {
    if (!entry.startsWith(prefix)) continue;
    const suffix = entry.slice(prefix.length);
    let idx = 0;
    for (const ch of suffix) idx = idx * 26 + (ch.charCodeAt(0) - 97);
    idx += 1; // 1-based
    parts.set(idx, entry);
    if (idx > maxIndex) maxIndex = idx;
  }
  return { parts, maxIndex };
}

function loadManifest(outputDir: string, id: string): TransferManifest {
  try {
    const raw = fs.readFileSync(transferManifestPath(outputDir, id), 'utf8');
    const m = JSON.parse(raw) as TransferManifest;
    if (!m.id) m.id = chunkFileBase(id);
    return m;
  } catch {
    return {
      id: chunkFileBase(id),
      directory: chunkFileBase(id),
      totalParts: 0,
      receivedParts: 0,
      missingParts: [],
      partFiles: [],
      checksumVerified: false,
      complete: false,
      updatedAt: new Date().toISOString(),
    };
  }
}

function buildManifest(outputDir: string, id: string, totalHint: number): TransferManifest {
  const base = chunkFileBase(id);
  const transferDir = transferDirectory(outputDir, id);
  const { parts, maxIndex } = scanPartFiles(transferDir, base);
  const total = Math.max(totalHint, maxIndex);
  const missing: number[] = [];
  for (let i = 1; i <= total; i++) if (!parts.has(i)) missing.push(i);

  const checksumFile = path.join(transferDir, `${base}.sha256`);
  let checksum = '';
  let checksumFileName = '';
  if (fs.existsSync(checksumFile)) {
    checksum = fs.readFileSync(checksumFile, 'utf8').trim();
    checksumFileName = `${base}.sha256`;
  }

  const sortedParts = [...parts.entries()].sort((a, b) => a[0] - b[0]).map(([, f]) => f);
  const complete = total > 0 && missing.length === 0;

  let joinedSHA256 = '';
  if (complete) {
    const hash = crypto.createHash('sha256');
    for (const pf of sortedParts) hash.update(fs.readFileSync(path.join(transferDir, pf)));
    joinedSHA256 = hash.digest('hex');
  }

  return {
    id: base,
    directory: base,
    totalParts: total,
    receivedParts: parts.size,
    missingParts: missing,
    partFiles: sortedParts,
    checksum: checksum || undefined,
    checksumFile: checksumFileName || undefined,
    joinedFile: complete ? `${base}.joined` : undefined,
    joinedSHA256: joinedSHA256 || undefined,
    checksumVerified:
      complete && !!checksum && checksum.toLowerCase() === joinedSHA256.toLowerCase(),
    complete,
    updatedAt: new Date().toISOString(),
  };
}

function writeManifest(outputDir: string, id: string, manifest: TransferManifest): void {
  const dest = transferManifestPath(outputDir, id);
  const tmp = `${dest}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
  fs.renameSync(tmp, dest);
}

function autoJoin(outputDir: string, manifest: TransferManifest): string {
  if (!manifest.complete || !manifest.partFiles.length) return '';
  const transferDir = transferDirectory(outputDir, manifest.id);
  const joinedPath = transferJoinPath(outputDir, manifest.id);
  if (fs.existsSync(joinedPath)) return joinedPath;

  const hash = crypto.createHash('sha256');
  const fd = fs.openSync(joinedPath, 'w');
  try {
    for (const pf of manifest.partFiles) {
      const data = fs.readFileSync(path.join(transferDir, pf));
      fs.writeSync(fd, data);
      hash.update(data);
    }
  } finally {
    fs.closeSync(fd);
  }

  const actual = hash.digest('hex');
  if (manifest.checksum && manifest.checksum.toLowerCase() !== actual.toLowerCase()) {
    fs.unlinkSync(joinedPath);
    throw new Error(`Checksum mismatch: expected ${manifest.checksum}, got ${actual}`);
  }

  console.log(`Auto-joined ${manifest.partFiles.length} parts into ${joinedPath}`);
  return joinedPath;
}

// ── Chunk storage ─────────────────────────────────────────────────────────────

async function storeQRChunk(outputDir: string, chunk: QRChunkUpload): Promise<UploadResult> {
  return withTransferLock(chunk.id, async () => {
    const transferDir = transferDirectory(outputDir, chunk.id);
    fs.mkdirSync(transferDir, { recursive: true });

    const fileName = chunk.isChecksum
      ? chunkChecksumFileName(chunk.id)
      : chunkPartFileName(chunk.id, chunk.index);
    const fullPath = path.join(transferDir, fileName);

    const content = chunk.isChecksum
      ? Buffer.from((chunk.checksum ?? '') + '\n', 'utf8')
      : chunk.payload;

    const chunkHash = sha256hex(content);

    if (fs.existsSync(fullPath)) {
      // Dedup: same content → skip; different → conflict error
      if (!fs.readFileSync(fullPath).equals(content)) {
        throw new Error(`Conflicting content already exists at ${fullPath}`);
      }
      console.log(`Skipped duplicate chunk ${fullPath}`);
      const prev = loadManifest(outputDir, chunk.id);
      const manifest = buildManifest(outputDir, chunk.id, Math.max(chunk.total, prev.totalParts));
      let joinedPath = '';
      if (manifest.complete) {
        try {
          joinedPath = autoJoin(outputDir, manifest);
        } catch {
          /* logged above */
        }
      }
      writeManifest(outputDir, chunk.id, manifest);
      return {
        fileName,
        path: fullPath,
        size: content.length,
        duplicate: true,
        existingPath: fullPath,
        sha256: chunkHash,
        transferId: manifest.id,
        manifestPath: transferManifestPath(outputDir, chunk.id),
        complete: manifest.complete,
        verified: manifest.checksumVerified,
        joinedPath: joinedPath || undefined,
      };
    }

    fs.writeFileSync(fullPath, content);
    console.log(`Saved chunk ${fullPath} (${content.length} bytes, sha256=${chunkHash})`);

    const prev = loadManifest(outputDir, chunk.id);
    const manifest = buildManifest(outputDir, chunk.id, Math.max(chunk.total, prev.totalParts));
    let joinedPath = '';
    if (manifest.complete) {
      try {
        joinedPath = autoJoin(outputDir, manifest);
      } catch (e) {
        console.error(`Auto-join failed: ${e instanceof Error ? e.message : e}`);
      }
    }
    writeManifest(outputDir, chunk.id, manifest);

    return {
      fileName,
      path: fullPath,
      size: content.length,
      sha256: chunkHash,
      transferId: manifest.id,
      manifestPath: transferManifestPath(outputDir, chunk.id),
      complete: manifest.complete,
      verified: manifest.checksumVerified,
      joinedPath: joinedPath || undefined,
    };
  });
}

// ── Fountain (LT code) decoding ───────────────────────────────────────────────

interface FountainChunkUpload {
  seq: number;
  k: number;
  fileSize: number;
  id: string;
  payload: Buffer;
}

interface FountainState {
  decoder: FountainDecoder;
  k: number;
  fileSize: number;
  checksum?: string;
  joinedPath?: string;
  joinedSha?: string; // sha256 of the written file, cached at join time
  verified?: boolean;
}

// In-memory decoders keyed by sanitized transfer id. Fountain decode is
// all-or-nothing (no useful partial output until ~K symbols arrive), so symbols
// are held in memory for the life of the process rather than persisted per
// symbol; the recovered file, checksum sidecar and manifest are written to disk
// on completion. A server restart mid-transfer therefore loses fountain
// progress (sequential transfers still resume from their part files).
const fountainTransfers = new Map<string, FountainState>();

function parseFountainChunk(raw: Buffer): FountainChunkUpload | null {
  const s = raw.toString('utf8');
  if (!s.startsWith('F|')) return null;

  // F|seq|K|fileSize|id|payload  (payload may contain '|')
  const p1 = s.indexOf('|');
  const p2 = s.indexOf('|', p1 + 1);
  if (p2 < 0) return null;
  const p3 = s.indexOf('|', p2 + 1);
  if (p3 < 0) return null;
  const p4 = s.indexOf('|', p3 + 1);
  if (p4 < 0) return null;
  const p5 = s.indexOf('|', p4 + 1);
  if (p5 < 0) return null;

  const seq = parseInt(s.slice(p1 + 1, p2), 10);
  const k = parseInt(s.slice(p2 + 1, p3), 10);
  const fileSize = parseInt(s.slice(p3 + 1, p4), 10);
  const id = s.slice(p4 + 1, p5);
  if (!Number.isInteger(seq) || seq < 0) return null;
  if (!Number.isInteger(k) || k < 1) return null;
  if (!Number.isInteger(fileSize) || fileSize < 0) return null;
  if (!validateChunkID(id)) return null;

  const payload = Buffer.from(s.slice(p5 + 1), 'base64');
  return { seq, k, fileSize, id, payload };
}

function writeFountainManifest(outputDir: string, id: string, state: FountainState): void {
  const base = chunkFileBase(id);
  const manifest: TransferManifest = {
    id: base,
    directory: base,
    encoding: 'fountain',
    totalParts: state.k,
    receivedParts: state.decoder.recoveredCount,
    symbolsReceived: state.decoder.symbolCount,
    missingParts: [],
    partFiles: [],
    fileSize: state.fileSize,
    checksum: state.checksum,
    joinedFile: state.joinedPath ? path.basename(state.joinedPath) : undefined,
    joinedSHA256: state.joinedSha,
    checksumVerified: state.verified === true,
    complete: state.decoder.isComplete,
    updatedAt: new Date().toISOString(),
  };
  writeManifest(outputDir, id, manifest);
}

// Once decoding completes, write the recovered file (trimmed to the original
// size — the last source block is zero-padded) and verify it against the
// transmitted checksum when that has arrived.
function maybeCompleteFountain(outputDir: string, id: string, state: FountainState): void {
  if (!state.decoder.isComplete) return;

  // Assemble + hash once, when first complete, then cache — later looped
  // symbols and the checksum frame reuse the cached digest.
  if (!state.joinedPath) {
    const assembled = state.decoder.assemble().subarray(0, state.fileSize);
    state.joinedSha = sha256hex(assembled);
    const transferDir = transferDirectory(outputDir, id);
    fs.mkdirSync(transferDir, { recursive: true });
    const joinedPath = transferJoinPath(outputDir, id);
    fs.writeFileSync(joinedPath, assembled);
    state.joinedPath = joinedPath;
    console.log(
      `Fountain decoded ${chunkFileBase(id)} → ${joinedPath} ` +
        `(${assembled.length} bytes, sha256=${state.joinedSha})`,
    );
  }

  // Verify against the transmitted checksum once it's known.
  if (state.checksum && state.verified === undefined) {
    state.verified = state.checksum.toLowerCase() === state.joinedSha!.toLowerCase();
    if (!state.verified) {
      console.error(
        `Fountain checksum mismatch for ${chunkFileBase(id)}: ` +
          `expected ${state.checksum}, got ${state.joinedSha}`,
      );
    }
  }
}

function getOrCreateFountainState(
  outputDir: string,
  id: string,
  k: number,
  fileSize: number,
  blockSize: number,
): FountainState {
  const base = chunkFileBase(id);
  let state = fountainTransfers.get(base);
  if (!state) {
    state = { decoder: new FountainDecoder(k, blockSize), k, fileSize };
    const shaFile = path.join(transferDirectory(outputDir, id), chunkChecksumFileName(id));
    if (fs.existsSync(shaFile)) state.checksum = fs.readFileSync(shaFile, 'utf8').trim();
    fountainTransfers.set(base, state);
  }
  return state;
}

function fountainResult(
  outputDir: string,
  id: string,
  state: FountainState,
  duplicate: boolean,
): UploadResult {
  const base = chunkFileBase(id);
  return {
    fileName: state.joinedPath ? path.basename(state.joinedPath) : `${base}.joined`,
    path: state.joinedPath ?? transferJoinPath(outputDir, id),
    size: state.fileSize,
    duplicate: duplicate || undefined,
    transferId: base,
    manifestPath: transferManifestPath(outputDir, id),
    complete: state.decoder.isComplete,
    verified: state.verified,
    joinedPath: state.joinedPath || undefined,
  };
}

async function storeFountainSymbol(
  outputDir: string,
  chunk: FountainChunkUpload,
): Promise<UploadResult> {
  return withTransferLock(chunk.id, async () => {
    fs.mkdirSync(transferDirectory(outputDir, chunk.id), { recursive: true });
    const state = getOrCreateFountainState(
      outputDir,
      chunk.id,
      chunk.k,
      chunk.fileSize,
      chunk.payload.length,
    );

    const duplicate = state.decoder.hasSeq(chunk.seq);
    if (!duplicate) {
      state.decoder.addSymbol(chunk.seq, chunk.payload);
      maybeCompleteFountain(outputDir, chunk.id, state);
    }
    writeFountainManifest(outputDir, chunk.id, state);
    return fountainResult(outputDir, chunk.id, state, duplicate);
  });
}

async function storeFountainChecksum(
  outputDir: string,
  chunk: QRChunkUpload,
): Promise<UploadResult> {
  return withTransferLock(chunk.id, async () => {
    const transferDir = transferDirectory(outputDir, chunk.id);
    fs.mkdirSync(transferDir, { recursive: true });
    fs.writeFileSync(
      path.join(transferDir, chunkChecksumFileName(chunk.id)),
      (chunk.checksum ?? '') + '\n',
    );

    const state = fountainTransfers.get(chunkFileBase(chunk.id));
    if (!state) {
      // Symbols normally precede the checksum; if not, persist the sidecar and
      // it'll be picked up when the decoder is created.
      return {
        fileName: chunkChecksumFileName(chunk.id),
        path: path.join(transferDir, chunkChecksumFileName(chunk.id)),
        size: 0,
        transferId: chunkFileBase(chunk.id),
      };
    }
    state.checksum = chunk.checksum;
    maybeCompleteFountain(outputDir, chunk.id, state);
    writeFountainManifest(outputDir, chunk.id, state);
    return fountainResult(outputDir, chunk.id, state, false);
  });
}

// ── Raw / multipart upload storage ───────────────────────────────────────────

function findDuplicateByHash(
  outputDir: string,
  checksum: string,
  size: number,
  ignorePath: string,
): string {
  for (const entry of fs.readdirSync(outputDir, { withFileTypes: true })) {
    if (entry.isDirectory()) continue;
    const candidate = path.join(outputDir, entry.name);
    if (candidate === ignorePath) continue;
    if (fs.statSync(candidate).size !== size) continue;
    if (sha256hex(fs.readFileSync(candidate)) === checksum) return candidate;
  }
  return '';
}

function uniqueDestination(dir: string, name: string): string {
  const ext = path.extname(name);
  const base = name.slice(0, name.length - ext.length) || 'upload';
  let candidate = path.join(dir, name);
  if (!fs.existsSync(candidate)) return candidate;
  for (let i = 2; ; i++) {
    candidate = path.join(dir, `${base}-${i}${ext}`);
    if (!fs.existsSync(candidate)) return candidate;
  }
}

function fallbackFileName(name: string, contentType: string): string {
  if (name) return name;
  const ts = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15);
  const ext = contentType.startsWith('image/jpeg')
    ? '.jpg'
    : contentType.startsWith('image/png')
      ? '.png'
      : contentType.startsWith('text/')
        ? '.txt'
        : '.bin';
  return `upload-${ts}${ext}`;
}

function sanitizeFilename(name: string): string {
  return path.basename(name.replace(/\\/g, '/').trim());
}

function requestedFileName(req: http.IncomingMessage): string {
  const u = new URL(req.url ?? '/', 'http://localhost');
  const q = u.searchParams.get('filename');
  if (q?.trim()) return q.trim();
  const xfn = req.headers['x-filename'];
  if (typeof xfn === 'string' && xfn.trim()) return xfn.trim();
  const cd = req.headers['content-disposition'];
  if (cd) {
    const m = cd.match(/filename="?([^";\r\n]+)"?/i);
    if (m?.[1]) return m[1].trim();
  }
  return '';
}

async function readBody(req: http.IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks);
}

async function storeRawUpload(req: http.IncomingMessage, outputDir: string): Promise<UploadResult> {
  const body = await readBody(req);
  if (!body.length) throw new Error('Request body is empty');

  const qrScan = tryParseQRScanUpload(body);
  if (qrScan) {
    const raw = qrScanBytes(qrScan);
    const fountainChunk = parseFountainChunk(raw);
    if (fountainChunk) return storeFountainSymbol(outputDir, fountainChunk);

    const chunk = parseQRChunk(raw);
    if (!chunk) throw new Error('Invalid QR chunk format');
    // A CHECKSUM frame for a fountain transfer (detected by its symbols having
    // arrived) verifies the decoded file rather than a sequential part set.
    if (chunk.isChecksum && fountainTransfers.has(chunkFileBase(chunk.id))) {
      return storeFountainChecksum(outputDir, chunk);
    }
    return storeQRChunk(outputDir, chunk);
  }

  const fileName = fallbackFileName(
    sanitizeFilename(requestedFileName(req)),
    req.headers['content-type'] ?? '',
  );

  const tmp = path.join(outputDir, `.upload-${process.pid}-${Date.now()}`);
  fs.writeFileSync(tmp, body);
  const checksum = sha256hex(body);
  const dup = findDuplicateByHash(outputDir, checksum, body.length, tmp);
  if (dup) {
    fs.unlinkSync(tmp);
    console.log(`Skipped duplicate upload (matches ${dup})`);
    return {
      fileName: path.basename(dup),
      path: dup,
      size: body.length,
      duplicate: true,
      existingPath: dup,
      sha256: checksum,
    };
  }
  const dest = uniqueDestination(outputDir, fileName);
  fs.renameSync(tmp, dest);
  console.log(`Saved upload ${dest} (${body.length} bytes, sha256=${checksum})`);
  return { fileName: path.basename(dest), path: dest, size: body.length, sha256: checksum };
}

async function storeMultipartUpload(
  req: http.IncomingMessage,
  outputDir: string,
): Promise<UploadResult> {
  const ct = req.headers['content-type'] ?? '';
  const bm = ct.match(/boundary=([^\s;]+)/);
  if (!bm) throw new Error('No boundary in multipart Content-Type');

  const body = await readBody(req);
  const boundary = '--' + bm[1];
  const sep = Buffer.from('\r\n' + boundary);

  let offset = body.indexOf(boundary);
  if (offset < 0) throw new Error('Boundary not found in request body');
  offset += boundary.length + 2; // skip \r\n after first boundary

  while (offset < body.length) {
    if (body[offset] === 45 && body[offset + 1] === 45) break; // '--' = end delimiter

    const headerEnd = body.indexOf('\r\n\r\n', offset);
    if (headerEnd < 0) break;
    const headerStr = body.slice(offset, headerEnd).toString('utf8');
    const fnMatch = headerStr.match(/filename="?([^";\r\n]+)"?/i);
    if (!fnMatch) {
      offset = headerEnd + 4;
      continue;
    }

    const partSlice = body.slice(headerEnd + 4);
    const nextBound = partSlice.indexOf(sep);
    const data = nextBound >= 0 ? partSlice.slice(0, nextBound) : partSlice;

    const fileName = fallbackFileName(sanitizeFilename(fnMatch[1]), '');
    const tmp = path.join(outputDir, `.upload-${process.pid}-${Date.now()}`);
    fs.writeFileSync(tmp, data);
    const checksum = sha256hex(data);
    const dup = findDuplicateByHash(outputDir, checksum, data.length, tmp);
    if (dup) {
      fs.unlinkSync(tmp);
      return {
        fileName: path.basename(dup),
        path: dup,
        size: data.length,
        duplicate: true,
        existingPath: dup,
        sha256: checksum,
      };
    }
    const dest = uniqueDestination(outputDir, fileName);
    fs.renameSync(tmp, dest);
    console.log(`Saved upload ${dest} (${data.length} bytes)`);
    return { fileName: path.basename(dest), path: dest, size: data.length, sha256: checksum };
  }

  throw new Error('No file field found in multipart upload');
}

// ── HTTP server ───────────────────────────────────────────────────────────────

function listenURLs(host: string, port: number): string[] {
  if (host !== '0.0.0.0' && host !== '::' && host !== '') {
    return [`http://${host}:${port}/upload`];
  }
  const urls = new Set<string>([`http://127.0.0.1:${port}/upload`]);
  for (const list of Object.values(os.networkInterfaces())) {
    for (const iface of list ?? []) {
      if (iface.family === 'IPv4' && !iface.internal) {
        urls.add(`http://${iface.address}:${port}/upload`);
      }
    }
  }
  return [...urls];
}

function setCORSHeaders(res: http.ServerResponse): void {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-Filename');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
}

export function runReceiver(flags: Record<string, string>): http.Server {
  const host = flags['host']?.trim() || '0.0.0.0';
  const port = parseInt(flags['port']?.trim() || '8080', 10);
  const outputDir = path.resolve(flags['output-dir']?.trim() || 'received');

  fs.mkdirSync(outputDir, { recursive: true });

  const server = http.createServer(async (req, res) => {
    console.log(`${req.method} ${req.url} from ${req.socket.remoteAddress}`);
    setCORSHeaders(res);

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    const url = new URL(req.url ?? '/', 'http://localhost');

    if (url.pathname === '/' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(
        `Porter receiver is running.\n\nPOST raw bytes to /upload?filename=name.bin\n` +
          `Or send multipart/form-data with a file field to /upload\n\n` +
          `Duplicate uploads are skipped automatically based on file content.\n` +
          `QR scan JSON uploads are unpacked into transfer directories like <id>/<id>.partaa and <id>/<id>.meta.json.\n` +
          `When a transfer is complete, Porter auto-joins it and writes <id>/<id>.joined.\n` +
          `Fountain (LT code) frames "F|..." are decoded on the fly; the recovered file is written to <id>/<id>.joined.\n` +
          `Saving uploads to: ${outputDir}\n`,
      );
      return;
    }

    if (url.pathname === '/upload') {
      if (req.method !== 'POST') {
        res.writeHead(405, { 'Content-Type': 'text/plain' });
        res.end('POST required');
        return;
      }
      try {
        const ct = req.headers['content-type'] ?? '';
        const result = ct.startsWith('multipart/form-data')
          ? await storeMultipartUpload(req, outputDir)
          : await storeRawUpload(req, outputDir);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result) + '\n');
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`Upload error: ${msg}`);
        res.writeHead(400, { 'Content-Type': 'text/plain' });
        res.end(msg);
      }
      return;
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  });

  server.listen(port, host === '0.0.0.0' ? undefined : host, () => {
    console.log(`Porter receiver listening on ${host}:${port}`);
    console.log(`Saving uploads to ${outputDir}`);
    for (const u of listenURLs(host, port)) console.log(`  ${u}`);
    console.log(`\nExamples:`);
    console.log(`  curl --data-binary @file.txt http://127.0.0.1:${port}/upload?filename=file.txt`);
    console.log(`  curl -F file=@photo.jpg http://127.0.0.1:${port}/upload`);
  });

  const shutdown = () =>
    server.close(() => {
      console.log('Receiver stopped.');
      process.exit(0);
    });
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

  return server;
}
