# Porter wire format

Normative description of what a Porter QR frame contains. This is the one
document three independent implementations must agree on:

| Implementation          | Files                                                           |
| ----------------------- | --------------------------------------------------------------- |
| Rust sender             | `rust-sender/src/chunker.rs`, `src/fountain.rs`                 |
| Node.js sender (legacy) | `nodejs/src/lib/chunker.ts`, `src/lib/fountain.ts`              |
| Flutter receiver        | `flutter/lib/services/chunk_parser.dart`, `fountain_codec.dart` |

If this document and the code disagree, the code is wrong — but fix both.

Cross-language agreement is verified by shared fixtures (e.g.
`flutter/test/fixtures/fountain_sample.json`), not by running one language's
tests against another. See `docs/adr/0002-fountain-vs-sequential.md` and
`docs/adr/0004-sender-language-rust.md` for the decisions behind this.

## Frame types

Every frame is a single QR code whose payload is a UTF-8 string with
`|`-separated fields. Three shapes exist.

### Sequential data frame

```text
index|total|mode|id|payload
```

- `index` — 1-based frame number.
- `total` — total data frames in the transfer (excludes the CHECKSUM frame).
- `mode` — `T` plain text, `B` base64-encoded binary, `C` gzip+base64.
- `id` — 2-char transfer id (see below).
- `payload` — the chunk body. May itself contain `|`, so parsers must split
  on the first four separators only.

### Fountain data frame

```text
F|seq|K|fileSize|id|payload
```

- `seq` — symbol sequence number, 0-based. Determines the symbol's
  `(degree, indices)` — see "Symbol derivation".
- `K` — number of source blocks.
- `fileSize` — original file length in bytes. The last source block is
  zero-padded; the receiver trims the assembled output to this.
- `id` — 2-char transfer id.
- `payload` — base64 of exactly `blockSize` bytes.

`blockSize` is **not transmitted**. The receiver infers it from the decoded
payload length, since every symbol is exactly one block.

### Checksum frame

```text
CHECKSUM|T|id|sha256
```

`sha256` is the lowercase hex digest of the _original_ file. Fountain always
sends this frame; sequential sends it only with `--verify`.

## Transfer id

Two characters derived from the first two bytes of the file's SHA-256:

```text
value = (digest[0] << 8) | digest[1]
id    = ALPHABET[(value >> 6) & 0x3f] + ALPHABET[value & 0x3f]
ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
```

**The id identifies content, not a session.** The same file sent twice gets
the same id. This matters: re-sending a file at a different QR version yields
the same id with a _different_ `K` and `blockSize`, and those two streams are
mutually undecodable. A receiver must therefore key a fountain transfer on
`(id, K, blockSize)`, not on `id` alone — mixing them corrupts the output.
See `Assembler._fountainLayouts`.

## Symbol derivation (fountain)

Sender and receiver independently derive each symbol's source-block indices
from `seq`. This must stay **bit-identical** across implementations; any drift
silently breaks decoding.

### PRNG — xorshift32

```text
state = seq XOR 0x9e3779b9      // if 0, use 0x9e3779b9
next():
  state ^= state << 13
  state ^= state >> 17
  state ^= state << 5
  return state                   // unsigned 32-bit, wrapping
```

TS and Dart must mask to 32 bits explicitly; Rust's `u32` wraps natively.

### Degree table

Integer weights only, so the same table and the same draw-by-modulo produce
identical degrees everywhere.

```text
if K <= 2:  every symbol has degree 1

weights[1] = 1
weights[i] = floor(K / (i * (i - 1)))     for i = 2..K

S = max(2, floor(sqrt(K)))
weights[i] += max(1, floor(S / i))        for i = 1..S-1
weights[S] += S

cum_weights[i] = sum(weights[1..i])
total          = cum_weights[K]
```

Two things that look like bugs and are not:

- `weights[i]` is **not** floored to 1. It reaches 0 once `i*(i-1) > K`
  (around `i > sqrt(K)`), which is what caps the maximum degree near
  `sqrt(K)`. Flooring to 1 would give every high degree equal weight and make
  large-K transfers effectively undecodable.
- `i * (i - 1)` **must be computed in 64-bit**. It overflows `u32` once
  `i > ~65536`, which a large file reaches (K in the hundreds of thousands).
  This was a real bug: it wrapped to a bogus divisor and corrupted the
  distribution.

### Drawing indices

```text
r      = next() mod total
degree = smallest d >= 1 with cum_weights[d] > r
indices = {}
while |indices| < degree and |indices| < K:
    indices.add((next() mod K) + 1)      // 1-based
return sorted(indices)
```

Note the symbol's _effective_ degree is `|indices|`, which can be less than
`degree` if the PRNG repeats an index.

### Symbol value

XOR of the source blocks at `indices`, each zero-padded to `blockSize`.

## Redundancy

The sender emits `N = max(K + 20, ceil(K * 3))` symbols, then the checksum
frame. The 3x factor is empirical (see `fountain.ts`): enough for full peeling
recovery from the complete pool with margin for scan loss.

A receiver needs materially **more than K** distinct symbols before peeling
completes — measured 1.33x–1.89x K across K=50..70965. Progress UI should
scale against ~2x K, not K, or it reads as ~99% complete with a third of the
scanning left.

## Sizing (informative)

Not part of the wire format — a receiver never needs this — but it explains
why `K` and `blockSize` change between runs of the same file.

```text
version   = clamp((rows - buffer) * 2 - 17 - 4) / 4, 1, 40)
capacity  = byte-mode capacity for (version, ecc)
blockSize = floor((capacity - headerReserve) * 0.75)     // fountain
K         = ceil(fileSize / blockSize)
```

Because `version` depends on terminal height, **resizing the terminal
mid-transfer changes `K` and `blockSize`** and forks the stream. Senders
recompute layout on resize; receivers should detect the change rather than
merge the two.

The Rust sender computes the header reserve exactly and forces a single
Byte-mode QR segment, because the crate's "optimal" segmentation can charge
more bits than the byte-mode capacity tables assume — a payload under the
table limit could still be rejected. The Node sender uses a fixed 32-byte
reserve, which underestimates the fountain header for large files.
