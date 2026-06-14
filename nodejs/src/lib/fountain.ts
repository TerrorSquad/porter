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
    // No max(1, ...) here: the ideal-soliton weight floors to 0 once
    // i*(i-1) > k (around i > sqrt(k)). Flooring those to 1 instead would
    // give every high degree weight 1 — a huge uniform tail of enormous
    // degrees that, for a large file (K in the hundreds of thousands), makes
    // most symbols XOR tens of thousands of blocks (catastrophically slow and
    // undecodable). Letting them stay 0 caps the max degree near sqrt(K).
    weights[i] = Math.floor(k / (i * (i - 1)));
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
  // Smallest degree d (>= 1) with cumWeights[d] > r. cumWeights is strictly
  // increasing, so binary search — a linear scan here is O(K) per symbol, which
  // dominates encode/decode time for large files (K in the hundreds of thousands).
  let lo = 1;
  let hi = cumWeights.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (cumWeights[mid] > r) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return lo;
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
 * Lazy "infinite pool" fountain (LT code) encoder. Mirrors Chunker's public
 * surface (chunks, version, chunkId, checksum, getSha256/getMd5,
 * calculateLayout) so Renderer/porter.ts need no changes to render its output.
 *
 * `chunks` is a Proxy that synthesises each symbol string on access rather than
 * materialising the whole pool: for a large file K can be hundreds of thousands
 * of blocks and N = 3K symbols, so precomputing every symbol up front would
 * burn billions of XOR ops and hundreds of MB of strings before the first frame
 * (it looked like a hang). The renderer only ever touches a few indices at a
 * time, and each symbol is cheap (avg degree ~ln K) to rebuild on demand.
 */
export class FountainChunker {
  public chunks: string[] = [];
  public version: number = 1;
  public blockSize: number = 0;
  public k: number = 0;
  public chunkId: string = '';
  public checksum: string = ''; // SHA256 of the original (unpadded) content

  private content: Buffer;
  private blocks: Buffer[] = [];
  private table: DegreeTable = { cumWeights: [0, 1], total: 1 };
  private symbolCount: number = 0; // N (symbols, excluding the checksum chunk)
  private fileSize: number = 0;

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

  /** Builds the `F|seq|K|fileSize|id|payload` string for one symbol on demand. */
  private buildSymbol(seq: number): string {
    const { indices } = sampleIndices(seq, this.k, this.table);
    const symbol = Buffer.alloc(this.blockSize);
    for (const idx of indices) {
      const block = this.blocks[idx - 1];
      for (let b = 0; b < this.blockSize; b++) {
        symbol[b] ^= block[b];
      }
    }
    return `F|${seq}|${this.k}|${this.fileSize}|${this.chunkId}|${symbol.toString('base64')}`;
  }

  /**
   * Chooses a QR version from the terminal size (same heuristic as
   * Chunker.calculateLayout) and splits the content into K zero-padded blocks.
   * Symbols are generated lazily via the `chunks` proxy (see class doc).
   * `options.useBase64`/`addHeader`/`addChecksum`/`currentPart`/`totalParts`
   * are ignored: fountain payloads are always base64, always headered, and
   * always followed by a checksum chunk (the decoder relies on it to verify
   * reconstruction).
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

    this.fileSize = this.content.length;
    this.k = Math.max(1, Math.ceil(this.fileSize / this.blockSize));

    this.table = buildDegreeTable(this.k);

    this.blocks = [];
    for (let i = 0; i < this.k; i++) {
      const start = i * this.blockSize;
      const slice = this.content.subarray(start, start + this.blockSize);
      if (slice.length === this.blockSize) {
        this.blocks.push(slice);
      } else {
        const padded = Buffer.alloc(this.blockSize);
        slice.copy(padded);
        this.blocks.push(padded);
      }
    }

    // N/K=3 was chosen empirically (see fountain.test.ts) as the smallest
    // round redundancy factor that guarantees the peeling decoder fully
    // recovers all K blocks from the complete pool, across K=1..2000+,
    // with comfortable margin for symbol loss during scanning.
    this.symbolCount = Math.max(this.k + 20, Math.ceil(this.k * 3));

    // Total frames = N symbols + 1 trailing checksum chunk. Each index is
    // synthesised on access; the backing array is sparse (no per-symbol cost).
    const total = this.symbolCount + 1;
    const checksumChunk = `CHECKSUM|T|${this.chunkId}|${this.checksum}`;
    const target = new Array<string>(total);

    this.chunks = new Proxy(target, {
      get: (t, prop, receiver) => {
        if (prop === 'length') return total;
        if (typeof prop === 'string' && /^\d+$/.test(prop)) {
          const i = Number(prop);
          if (i < total) {
            return i === this.symbolCount ? checksumChunk : this.buildSymbol(i);
          }
        }
        return Reflect.get(t, prop, receiver);
      },
    });
  }
}
