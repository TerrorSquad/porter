// Porter — fountain (LT code) decoder for the HTTP receiver (porter serve).
//
// Mirrors flutter/lib/services/fountain_decoder.dart: a peeling decoder with a
// GF(2) Gaussian-elimination fallback for the small "stuck core" peeling can
// leave behind. Reuses the encoder's codec (makeRng/buildDegreeTable/
// sampleIndices) so the (degree, source-block indices) mapping is regenerated
// identically — it is never transmitted.

import { buildDegreeTable, sampleIndices, type DegreeTable } from './fountain.js';

export interface RecoveredBlock {
  index: number; // 1-based
  bytes: Buffer;
}

interface PendingSymbol {
  xor: Buffer;
  unresolved: Set<number>;
}

export class FountainDecoder {
  public readonly k: number;
  public readonly blockSize: number;
  private readonly table: DegreeTable;

  private readonly recovered = new Map<number, Buffer>(); // 1-based index → bytes
  private readonly seenSeqs = new Set<number>();
  private readonly pending: PendingSymbol[] = [];

  constructor(k: number, blockSize: number) {
    this.k = k;
    this.blockSize = blockSize;
    this.table = buildDegreeTable(k);
  }

  get recoveredCount(): number {
    return this.recovered.size;
  }

  /** Distinct symbols ingested so far. */
  get symbolCount(): number {
    return this.seenSeqs.size;
  }

  get isComplete(): boolean {
    return this.recovered.size === this.k;
  }

  hasSeq(seq: number): boolean {
    return this.seenSeqs.has(seq);
  }

  private get missingCount(): number {
    return this.k - this.recovered.size;
  }

  private xorInto(dst: Buffer, src: Buffer): void {
    for (let b = 0; b < this.blockSize; b++) dst[b] ^= src[b];
  }

  /**
   * Feeds one symbol into the decoder. Returns the source blocks newly
   * recovered as a direct or cascaded result (empty if the symbol was a
   * duplicate, fully redundant, or merely queued for later).
   */
  addSymbol(seq: number, bytes: Buffer): RecoveredBlock[] {
    if (this.isComplete) return [];
    if (this.seenSeqs.has(seq)) return [];
    this.seenSeqs.add(seq);

    const { indices } = sampleIndices(seq, this.k, this.table);

    // Private, blockSize-normalised copy so XOR-reduction never mutates the
    // caller's buffer and short/long payloads are tolerated.
    const xor = Buffer.alloc(this.blockSize);
    bytes.copy(xor, 0, 0, Math.min(this.blockSize, bytes.length));

    const unresolved = new Set<number>();
    for (const idx of indices) {
      const known = this.recovered.get(idx);
      if (known) this.xorInto(xor, known);
      else unresolved.add(idx);
    }

    const newlyRecovered: RecoveredBlock[] = [];

    if (unresolved.size === 0) return newlyRecovered; // fully redundant

    if (unresolved.size === 1) {
      this.recoverAndCascade(unresolved.values().next().value as number, xor, newlyRecovered);
    } else {
      this.pending.push({ xor, unresolved });
    }

    // Peeling stalls on a "stuck core" of mutually-overlapping symbols even when
    // the data is fully determined (common at small K). Whenever enough
    // independent equations exist to possibly solve the residual, fall back to
    // Gaussian elimination over GF(2). The `pending >= missing` gate keeps GE off
    // the fast path until near the end, and peeling having consumed most symbols
    // keeps the residual (and so GE) small. (It must not also require that this
    // symbol stalled peeling: if the *last* symbol of a stream makes progress but
    // leaves a solvable core, no further symbol arrives to trigger the solve.)
    if (!this.isComplete && this.pending.length >= this.missingCount) {
      this.solveResidualByElimination(newlyRecovered);
    }

    return newlyRecovered;
  }

  /** Records block [index], then peels it (and any singletons it exposes) out
   * of every pending symbol, recovering more blocks in cascade. */
  private recoverAndCascade(index: number, bytes: Buffer, out: RecoveredBlock[]): void {
    const queue: Array<{ idx: number; bytes: Buffer }> = [{ idx: index, bytes }];

    while (queue.length > 0) {
      const { idx, bytes: blockBytes } = queue.pop()!;
      if (this.recovered.has(idx)) continue;

      this.recovered.set(idx, blockBytes);
      out.push({ index: idx, bytes: blockBytes });

      for (let i = this.pending.length - 1; i >= 0; i--) {
        const p = this.pending[i];
        if (!p.unresolved.delete(idx)) continue;
        this.xorInto(p.xor, blockBytes);

        if (p.unresolved.size === 0) {
          this.pending.splice(i, 1);
        } else if (p.unresolved.size === 1) {
          this.pending.splice(i, 1);
          queue.push({ idx: p.unresolved.values().next().value as number, bytes: p.xor });
        }
      }
    }
  }

  /** Symmetric difference of two index sets (GF(2) addition of coefficients). */
  private xorSets(a: Set<number>, b: Set<number>): Set<number> {
    const r = new Set(a);
    for (const x of b) {
      if (!r.delete(x)) r.add(x);
    }
    return r;
  }

  /** Solves the residual system of [pending] equations via Gaussian elimination
   * over GF(2). On full rank it recovers every remaining block and clears
   * [pending]; otherwise it leaves state untouched and waits for more symbols. */
  private solveResidualByElimination(out: RecoveredBlock[]): void {
    const unknowns = this.missingCount;

    // Forward elimination into row-echelon form, keyed by each row's smallest
    // (pivot) coefficient. Work on copies so a non-full-rank attempt is a no-op.
    const pivots = new Map<number, PendingSymbol>();
    for (const p of this.pending) {
      let coeffs = new Set(p.unresolved);
      const bytes = Buffer.from(p.xor);

      while (coeffs.size > 0) {
        let pivot = Infinity;
        for (const c of coeffs) if (c < pivot) pivot = c;
        const existing = pivots.get(pivot);
        if (!existing) {
          pivots.set(pivot, { xor: bytes, unresolved: coeffs });
          break;
        }
        coeffs = this.xorSets(coeffs, existing.unresolved);
        this.xorInto(bytes, existing.xor);
      }
    }

    if (pivots.size < unknowns) return; // not yet uniquely solvable

    // Back-substitution: largest pivot index down, so higher-index coefficients
    // are already solved when we reach each row.
    const solution = new Map<number, Buffer>();
    const pivotIndicesDesc = [...pivots.keys()].sort((a, b) => b - a);
    for (const pivot of pivotIndicesDesc) {
      const row = pivots.get(pivot)!;
      const bytes = Buffer.from(row.xor);
      for (const c of row.unresolved) {
        if (c === pivot) continue;
        const solved = solution.get(c);
        if (solved) this.xorInto(bytes, solved);
      }
      solution.set(pivot, bytes);
    }

    this.pending.length = 0;
    for (const [index, bytes] of solution) {
      if (this.recovered.has(index)) continue;
      this.recovered.set(index, bytes);
      out.push({ index, bytes });
    }
  }

  /** Concatenates the recovered blocks 1..k in order. Throws if incomplete.
   * Callers trim the result to the original file size themselves. */
  assemble(): Buffer {
    if (!this.isComplete) {
      throw new Error(`Cannot assemble: ${this.recoveredCount} of ${this.k} blocks recovered`);
    }
    const parts: Buffer[] = [];
    for (let i = 1; i <= this.k; i++) parts.push(this.recovered.get(i)!);
    return Buffer.concat(parts);
  }
}
