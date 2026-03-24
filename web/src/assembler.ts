// Porter Receiver — chunk assembly logic
// Chunk format: index|total|mode|id|payload  (1-based index)
// Checksum   :  CHECKSUM|T|id|sha256

export type ChunkMode = 'T' | 'B' | 'C';

export interface Transfer {
  id: string;
  total: number;
  mode: ChunkMode;
  chunks: Map<number, Uint8Array>; // 1-based index → decoded bytes
  checksum?: string; // expected SHA-256 (from CHECKSUM chunk)
  seen: Set<number>; // dedup: indices already received
  complete: boolean;
  assembled?: Uint8Array;
  verified?: boolean; // true = SHA-256 matched; false = mismatch; undefined = not yet checked
  checksumMismatch?: boolean; // true only if verified is false
  error?: string;
  createdAt: number;
  completedAt?: number;
}

export interface AssemblerCallbacks {
  onProgress?: (t: Transfer) => void;
  onComplete?: (t: Transfer) => void;
}

// ── Parsing ──────────────────────────────────────────────────────────────────

type DataChunk = {
  kind: 'data';
  id: string;
  index: number;
  total: number;
  mode: ChunkMode;
  payload: string;
};

type ChecksumChunk = {
  kind: 'checksum';
  id: string;
  checksum: string;
};

function parseChunk(raw: string): DataChunk | ChecksumChunk | null {
  if (!raw) return null;

  // CHECKSUM|T|id|sha256
  if (raw.startsWith('CHECKSUM|')) {
    const p1 = raw.indexOf('|', 9); // after "CHECKSUM"
    const p2 = raw.indexOf('|', p1 + 1);
    if (p1 < 0 || p2 < 0) return null;
    const id = raw.slice(p1 + 1, p2);
    const checksum = raw.slice(p2 + 1).trim();
    if (id.length !== 2 || !checksum) return null;
    return { kind: 'checksum', id, checksum };
  }

  // index|total|mode|id|payload  (payload may contain '|')
  const p1 = raw.indexOf('|');
  if (p1 < 0) return null;
  const p2 = raw.indexOf('|', p1 + 1);
  if (p2 < 0) return null;
  const p3 = raw.indexOf('|', p2 + 1);
  if (p3 < 0) return null;
  const p4 = raw.indexOf('|', p3 + 1);
  if (p4 < 0) return null;

  const index = parseInt(raw.slice(0, p1), 10);
  const total = parseInt(raw.slice(p1 + 1, p2), 10);
  const mode = raw.slice(p2 + 1, p3);
  const id = raw.slice(p3 + 1, p4);
  const payload = raw.slice(p4 + 1);

  if (!Number.isInteger(index) || index < 1) return null;
  if (!Number.isInteger(total) || total < 1) return null;
  if (mode !== 'T' && mode !== 'B' && mode !== 'C') return null;
  if (id.length !== 2) return null;

  return { kind: 'data', id, index, total, mode: mode as ChunkMode, payload };
}

// ── Assembler ────────────────────────────────────────────────────────────────

export class Assembler {
  private transfers = new Map<string, Transfer>();

  constructor(private readonly cbs: AssemblerCallbacks = {}) {}

  /**
   * Feed a raw QR string. Returns true if it contained new information
   * (new data chunk or new checksum), false if duplicate or unrecognised.
   */
  ingest(raw: string): boolean {
    const chunk = parseChunk(raw.trim());
    if (!chunk) return false;

    if (chunk.kind === 'checksum') {
      const t = this.getOrCreate(chunk.id, 0, 'T');
      if (t.checksum === chunk.checksum) return false; // already have it
      t.checksum = chunk.checksum;
      if (t.assembled) {
        // Transfer already assembled — verify now
        verifyChecksum(t, this.cbs);
      } else {
        this.tryComplete(t);
      }
      return true;
    }

    const { id, index, total, mode, payload } = chunk;
    const t = this.getOrCreate(id, total, mode);

    // Grow total if we see a larger value (shouldn't happen, but be safe)
    if (total > t.total) t.total = total;

    if (t.complete) return false;
    if (t.seen.has(index)) return false; // duplicate

    t.seen.add(index);
    t.chunks.set(index, decodePayload(mode, payload));
    t.mode = mode;

    this.cbs.onProgress?.(t);
    this.tryComplete(t);
    return true;
  }

  getTransfers(): Map<string, Transfer> {
    return this.transfers;
  }

  reset(id?: string): void {
    if (id) {
      this.transfers.delete(id);
    } else {
      this.transfers.clear();
    }
  }

  // ── Private ────────────────────────────────────────────────────────────────

  private getOrCreate(id: string, total: number, mode: ChunkMode): Transfer {
    let t = this.transfers.get(id);
    if (!t) {
      t = {
        id,
        total,
        mode,
        chunks: new Map(),
        seen: new Set(),
        complete: false,
        createdAt: Date.now(),
      };
      this.transfers.set(id, t);
    }
    return t;
  }

  private tryComplete(t: Transfer): void {
    if (t.complete || t.total === 0 || t.chunks.size < t.total) return;

    t.complete = true;
    t.completedAt = Date.now();

    const cbs = this.cbs;
    if (t.mode === 'C') {
      // Gzip decompression is async
      concatChunks(t)
        .then((raw) => decompressGzip(raw))
        .then((decompressed) => {
          t.assembled = decompressed;
          verifyChecksum(t, cbs);
        })
        .catch((err) => {
          t.error = `Decompression failed: ${err instanceof Error ? err.message : String(err)}`;
          cbs.onComplete?.(t);
        });
    } else {
      concatChunks(t)
        .then((bytes) => {
          t.assembled = bytes;
          verifyChecksum(t, cbs);
        })
        .catch((err) => {
          t.error = `Assembly failed: ${err instanceof Error ? err.message : String(err)}`;
          cbs.onComplete?.(t);
        });
    }
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

async function sha256hex(data: Uint8Array): Promise<string> {
  const hashBuffer = await crypto.subtle.digest('SHA-256', data.buffer as ArrayBuffer);
  return [...new Uint8Array(hashBuffer)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function verifyChecksum(t: Transfer, cbs: AssemblerCallbacks): void {
  if (!t.assembled) {
    cbs.onComplete?.(t);
    return;
  }
  if (!t.checksum) {
    cbs.onComplete?.(t);
    return;
  }
  sha256hex(t.assembled)
    .then((actual) => {
      t.verified = actual.toLowerCase() === t.checksum!.toLowerCase();
      t.checksumMismatch = !t.verified;
      if (t.checksumMismatch) {
        t.error = `SHA-256 mismatch: expected ${t.checksum}, got ${actual}`;
      }
      cbs.onComplete?.(t);
    })
    .catch((err) => {
      t.error = `SHA-256 computation failed: ${err instanceof Error ? err.message : String(err)}`;
      cbs.onComplete?.(t);
    });
}

function decodePayload(mode: ChunkMode, payload: string): Uint8Array {
  if (mode === 'T') return new TextEncoder().encode(payload);
  // B and C: base64-encoded bytes
  return base64ToBytes(payload);
}

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function concatChunks(t: Transfer): Promise<Uint8Array> {
  const parts: Uint8Array[] = [];
  for (let i = 1; i <= t.total; i++) {
    const chunk = t.chunks.get(i);
    if (!chunk) throw new Error(`Missing chunk ${i}`);
    parts.push(chunk);
  }
  const totalLen = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(totalLen);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

async function decompressGzip(data: Uint8Array): Promise<Uint8Array> {
  const ds = new DecompressionStream('gzip');
  const writer = ds.writable.getWriter();
  const reader = ds.readable.getReader();
  // Cast is safe: our Uint8Arrays are always backed by a plain ArrayBuffer
  writer.write(data as unknown as Uint8Array<ArrayBuffer>);
  writer.close();
  const parts: Uint8Array[] = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    parts.push(value!);
  }
  const totalLen = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(totalLen);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}
