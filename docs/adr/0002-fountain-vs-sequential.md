# ADR-0002: Fountain (LT-code) vs. sequential chunk encoding

**Status:** Accepted · **Date:** 2026-08-09

## Context

QR-slideshow transfer has no back-channel: the receiver can't ask the
sender to resend a dropped frame. Two encoding strategies exist for this:

- **Sequential** (`index|total|mode|id|payload`): each chunk is a fixed
  1-based slice of the file. A dropped/missed frame means waiting for the
  sender's next loop to re-display exactly that index.
- **Fountain / LT code** (`F|seq|K|fileSize|id|payload`): each transmitted
  symbol is the XOR of a pseudo-random subset of the `K` source blocks,
  chosen deterministically from `seq` via a shared PRNG. _Any_ sufficient
  subset of symbols reconstructs all `K` blocks — no specific symbol needs
  to be re-seen.

## Options (verified 2026-08-09)

- **Sequential only** — simplest, but a single consistently-missed frame
  (bad lighting angle, motion blur at a specific point in the loop) stalls
  the whole transfer until the sender loops back to it.
- **Fountain only** — no positional dependency, but per-symbol decode
  overhead (PRNG regeneration, peeling bookkeeping) is wasted for small
  files where sequential's simplicity is enough.
- **Both, sender-selectable** — sequential for small/simple transfers,
  fountain for large/lossy-scanning scenarios. This is what's implemented;
  the wire format's leading token (`F` vs. a bare index) disambiguates.

## Decision

Support both. Fountain mode transmits `N = 3K` symbols per full loop (3x
redundancy over the `K` source blocks) — enough that a receiver catching a
random subset of frames converges without needing the sender to loop
indefinitely. The `(degree, indices)` mapping for each symbol is derived
from its `seq` via `sampleIndices`/`buildDegreeTable`
(`flutter/lib/services/fountain_codec.dart`), never transmitted — sender
and receiver regenerate it identically from a shared xorshift32 PRNG
(Marsaglia, shifts 13/17/5) and integer-weighted degree table. Any drift
between implementations breaks decoding silently (wrong indices assumed
per symbol), which is why this exact algorithm must stay bit-identical
across the TypeScript sender, the planned Rust sender, and the Dart
receiver — see [ADR-0004](0004-sender-language-rust.md).

**Decoding** (`flutter/lib/services/fountain_decoder.dart`) is two-tier:

1. **Peeling** (belief propagation): a symbol touching only one still-unknown
   block resolves it directly; resolving a block can cascade, peeling
   further symbols down to a single unknown in turn. This is the fast path
   and handles the overwhelming majority of recovery.
2. **Gaussian elimination over GF(2)** as a fallback for the "stuck core" —
   a small set of mutually-overlapping symbols that peeling alone can't
   resolve even though the system is fully determined. This is common at
   small `K` and can occur at any `K`. GE is capped at
   `maxEliminationMissingCount` (default 500): it only runs once fewer than
   500 blocks remain missing, so it solves at most a ~500×500 system, never
   an O(K²)/O(K³) matrix over the full block count. Above that threshold,
   peeling alone must carry the transfer — this trades a theoretical
   "could solve it now" for guaranteed UI-thread safety at large K (tens of
   thousands of blocks).

Progress signal: `symbolCount` (distinct symbols ingested) climbs steadily
as frames are scanned and is what the UI shows, since `recoveredCount`
(blocks solved) stays near zero until enough redundancy has accumulated,
then completes in a burst — an artifact of how peeling convergence works,
not a bug.

## Consequences

- Fountain mode tolerates arbitrary frame drops with no positional
  dependency, at the cost of 3x transmitted redundancy and PRNG/peeling
  CPU overhead per symbol.
- The GE cap means a fountain transfer can theoretically stall completely
  above 500 stuck blocks — never observed in practice given the degree
  distribution, but if it does happen the transfer needs more symbols
  (more loop time), not a config change, since raising the cap
  re-introduces the O(K²)/O(K³) stall risk it exists to prevent.
- Sequential mode stays simpler and cheaper for cases where a lossless
  scan loop is realistic (small file, good lighting, short loop).

## Open questions

- None currently open.
