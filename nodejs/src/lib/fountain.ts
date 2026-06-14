import crypto from 'crypto';
import { getMaxCapacity } from './constants.js';
import { makeChunkId, type ChunkOptions } from './chunker.js';

// Header reserve for `F|seq|K|fileSize|id|` — generous enough for 7-digit seq,
// 6-digit K, 10-digit fileSize, 2-char id, and the 5 separators/marker.
const FOUNTAIN_HEADER_RESERVE = 32;

// Mix constant for seeding the PRNG from a sequence number. Any fixed odd
// constant works; this is just splitmix-style "golden ratio" noise.
const SEED_XOR = 0x9e3779b9;

/**
 * xorshift32 (Marsaglia, shifts 13/17/5). Must stay bit-for-bit identical to
 * the Dart port in flutter/lib/services/fountain_codec.dart — encoder and
 * decoder derive (degree, indices) independently from the same `seq`.
 */
function xorshift32(x: number): number {
  x ^= x << 13;
  x ^= x >>> 17;
  x ^= x << 5;
  return x >>> 0;
}

/** Returns a function that yields successive uint32 values, seeded from `seq`. */
export function makeRng(seq: number): () => number {
  let state = (seq ^ SEED_XOR) >>> 0;
  if (state === 0) state = SEED_XOR;
  return () => {
    state = xorshift32(state);
    return state;
  };
}

export interface DegreeTable {
  // cumWeights[0] = 0, cumWeights[d] = sum of weights for degrees 1..d
  cumWeights: number[];
  total: number;
}

/**
 * Robust-soliton-inspired degree distribution, expressed entirely with
 * integer weights so the same table (and the same draw-by-modulo) produces
 * identical degrees in TS and Dart.
 *
 * - weight(1) = 1, weight(i) = floor(K / (i*(i-1))) for i = 2..K
 *   (approximates the ideal soliton distribution rho(i); rho(2) dominates)
 * - a "tau" correction spreads extra weight across the low degrees
 *   1..S-1 (S = floor(sqrt(K))) and adds a spike of weight S at degree S,
 *   mirroring robust soliton's tau(i) term and mitigating the last-block
 *   problem
 * - K <= 2: degree is always 1 (avoids degenerate tables for trivial transfers)
 */
export function buildDegreeTable(k: number): DegreeTable {
  if (k <= 2) {
    return { cumWeights: [0, 1], total: 1 };
  }

  const weights = new Array<number>(k + 1).fill(0);
  weights[1] = 1;
  for (let i = 2; i <= k; i++) {
    weights[i] = Math.max(1, Math.floor(k / (i * (i - 1))));
  }

  const s = Math.max(2, Math.floor(Math.sqrt(k)));
  for (let i = 1; i < s; i++) {
    weights[i] += Math.max(1, Math.floor(s / i));
  }
  weights[s] += s;

  const cumWeights = new Array<number>(k + 1).fill(0);
  let running = 0;
  for (let i = 1; i <= k; i++) {
    running += weights[i];
    cumWeights[i] = running;
  }

  return { cumWeights, total: running };
}

function pickDegree(r: number, cumWeights: number[]): number {
  for (let d = 1; d < cumWeights.length; d++) {
    if (r < cumWeights[d]) return d;
  }
  return cumWeights.length - 1;
}

/**
 * Derives the (degree, source-block indices) tuple for symbol `seq` over `k`
 * source blocks. Indices are 1-based and sorted ascending. Pass a
 * precomputed `table` (from buildDegreeTable) to avoid rebuilding it per call.
 */
export function sampleIndices(
  seq: number,
  k: number,
  table?: DegreeTable,
): { degree: number; indices: number[] } {
  const t = table ?? buildDegreeTable(k);
  const rng = makeRng(seq);

  const r = rng() % t.total;
  const degree = pickDegree(r, t.cumWeights);

  const indices = new Set<number>();
  while (indices.size < degree && indices.size < k) {
    const idx = (rng() % k) + 1;
    indices.add(idx);
  }

  return { degree: indices.size, indices: Array.from(indices).sort((a, b) => a - b) };
}

/**
 * "Precomputed pool" fountain (LT code) encoder. Mirrors Chunker's public
 * surface (chunks, version, chunkId, checksum, getSha256/getMd5,
 * calculateLayout) so Renderer/porter.ts need no changes to render its output.
 */
export class FountainChunker {
  public chunks: string[] = [];
  public version: number = 1;
  public blockSize: number = 0;
  public k: number = 0;
  public chunkId: string = '';
  public checksum: string = ''; // SHA256 of the original (unpadded) content

  private content: Buffer;

  constructor(content: Buffer) {
    this.content = content;
    const digest = crypto.createHash('sha256').update(content).digest();
    this.checksum = digest.toString('hex');
    this.chunkId = makeChunkId(digest[0] ?? 0, digest[1] ?? 0);
  }

  public getSha256(): string {
    return this.checksum;
  }

  public getMd5(): string {
    return crypto.createHash('md5').update(this.content).digest('hex');
  }

  /**
   * Chooses a QR version from the terminal size (same heuristic as
   * Chunker.calculateLayout), splits the content into K zero-padded blocks,
   * and precomputes the symbol pool. `options.useBase64`/`addHeader`/
   * `addChecksum`/`currentPart`/`totalParts` are ignored: fountain payloads
   * are always base64, always headered, and always followed by a checksum
   * chunk (the decoder relies on it to verify reconstruction).
   */
  public calculateLayout(rows: number, options: ChunkOptions) {
    const availableRows = rows - options.buffer;
    const maxVer = Math.floor((availableRows * 2 - 17 - 4) / 4);
    this.version = Math.max(1, Math.min(40, maxVer));

    const ecc = options.eccLevel || 'L';
    const charCapacity = getMaxCapacity(this.version, ecc);

    const workingCapacity = charCapacity - FOUNTAIN_HEADER_RESERVE;
    // Payloads are XOR'd binary blocks, always base64-encoded.
    this.blockSize = Math.floor(workingCapacity * 0.75);
    if (this.blockSize <= 0) this.blockSize = 16; // safety floor

    const fileSize = this.content.length;
    this.k = Math.max(1, Math.ceil(fileSize / this.blockSize));

    const table = buildDegreeTable(this.k);

    const blocks: Buffer[] = [];
    for (let i = 0; i < this.k; i++) {
      const start = i * this.blockSize;
      const slice = this.content.subarray(start, start + this.blockSize);
      if (slice.length === this.blockSize) {
        blocks.push(slice);
      } else {
        const padded = Buffer.alloc(this.blockSize);
        slice.copy(padded);
        blocks.push(padded);
      }
    }

    // N/K=3 was chosen empirically (see fountain.test.ts) as the smallest
    // round redundancy factor that guarantees the peeling decoder fully
    // recovers all K blocks from the complete pool, across K=1..2000+,
    // with comfortable margin for symbol loss during scanning.
    const n = Math.max(this.k + 20, Math.ceil(this.k * 3));

    this.chunks = [];
    for (let seq = 0; seq < n; seq++) {
      const { indices } = sampleIndices(seq, this.k, table);
      const symbol = Buffer.alloc(this.blockSize);
      for (const idx of indices) {
        const block = blocks[idx - 1];
        for (let b = 0; b < this.blockSize; b++) {
          symbol[b] ^= block[b];
        }
      }
      const payload = symbol.toString('base64');
      this.chunks.push(`F|${seq}|${this.k}|${fileSize}|${this.chunkId}|${payload}`);
    }

    this.chunks.push(`CHECKSUM|T|${this.chunkId}|${this.checksum}`);
  }
}
