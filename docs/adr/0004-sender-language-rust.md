# ADR-0004: Sender language — TypeScript → Rust

**Status:** Accepted (QR-display sender + `porter serve`) · **Date:** 2026-08-09

## Context

The current sender (`nodejs/`, TypeScript, run via `tsx` or bundled to a
standalone `.mjs` with Rollup) requires a Node.js runtime on the sending
machine. Porter is an air-gapped tool — the sending machine is often not
the same machine you'd normally have Node installed on, and "install a
runtime just to send a file" is friction the tool shouldn't impose. The
user also wants richer terminal sender controls (speed adjustment,
jump-to-chunk, gap-fill looping) than the current hand-rolled-ANSI
TypeScript renderer supports, and is drawn to Rust's `ratatui`/`crossterm`
TUI ecosystem for building them.

## Options (verified 2026-08-09)

- **Stay TypeScript, keep bundling to a standalone `.mjs`** — no runtime
  install needed if Node itself is present, but a `.mjs` still needs
  _some_ Node runtime on the target machine; it's not a true
  self-contained binary. Terminal control today is hand-rolled ANSI
  (`renderer.ts`), workable but not what you'd reach for to add the
  requested interactive controls.
- **Go** — compiles to a single static binary, satisfying the
  no-runtime-dependency requirement. Terminal UI story is more
  hand-rolled (no direct `ratatui` equivalent with the same maturity).
- **Rust** — compiles to a single static binary, and `ratatui`/`crossterm`
  is a mature, widely-used TUI stack directly suited to the requested
  controls (speed adjust, scrubbing, jump-to-chunk, gap-fill mode).

## Decision

Port the sender to Rust. **Single-static-binary was the primary driver**
(no Node.js runtime needed on the sending machine); Rust's
`ratatui`/`crossterm` ecosystem over Go's more hand-rolled terminal-control
story was the secondary driver.

**Scope is the QR-display sender plus `porter serve`** — `porter.ts`'s
slideshow path (`renderer.ts`/`chunker.ts`/`fountain.ts`/`state.ts`) and
the HTTP receiver (`receiver.ts`, 876 lines). Originally (2026-08-09,
first pass) `porter serve` was deferred alongside `porter join`; it was
pulled into scope the same night once the sender port's foundations
(fountain codec, crate scaffold) were proven out and the framework
decision below was made explicitly rather than left implicit.

**`porter serve`'s framework: `axum`**, not hand-rolled `hyper`.
`receiver.ts` is 876 lines partly _because_ Node's `http` module has no
routing layer — Rust's `hyper` has the same gap, but `axum` (built on
`hyper`+`tower`) provides routing, extractors, and multipart body
handling for a 3-route server (`GET /`, `POST /upload`, `OPTIONS *`)
without meaningful runtime cost for a single-binary CLI tool. This is the
same "reach for an established crate over hand-rolling" bar applied
elsewhere in this port (e.g. the `qrcode` crate itself) — an 876-line
hand-rolled HTTP server is exactly the case that bar is for.

**`porter join`** (multi-part joiner, `joiner.ts`, 178 lines) remains
deferred — a smaller, more standalone problem than `serve`, not requested
alongside this expansion. `nodejs/` stays in the repo for it
indefinitely; it is not being retired by this decision, only slimmed down
once/if the sender + serve paths are verified and cut over.

**What must stay bit-identical** across the language boundary, since the
already-shipped Dart receiver depends on it independently deriving the
same values:

- Chunk wire formats: `index|total|mode|id|payload` (sequential),
  `F|seq|K|fileSize|id|payload` (fountain), `CHECKSUM|T|id|sha256`.
- The xorshift32 PRNG (Marsaglia, shifts 13/17/5) and integer-weighted
  degree table (`buildDegreeTable`/`sampleIndices`) — see
  [ADR-0002](0002-fountain-vs-sequential.md). Verified via a
  cross-language fixture test: regenerate an equivalent to
  `test/fixtures/fountain_sample.json` from the Rust encoder and confirm
  the Dart decoder still accepts it byte-for-byte.
- The QR version-selection heuristic (`(availableRows * 2 - 17 - 4) / 4`
  in `chunker.ts`/`fountain.ts`) and half-block Unicode rendering
  (`█`/`▀`/`▄`/` `) with DEC synchronized-output escapes
  (`\x1b[?2026h`/`\x1b[?2026l`) — the latter is what prevents
  camera-visible tearing mid-frame; losing it regresses an
  already-solved problem, not a cosmetic detail.

**What's a clean rewrite:** everything else — CLI argument parsing, file
I/O, the QR encoding library choice (`qrcode` crate as the leading
candidate, verified to expose per-module bit access since the half-block
renderer needs raw grid data, not a pre-rendered image; falling back to
porting the encoding algorithm directly if it doesn't), and all TUI
control code (new functionality, not present in the TypeScript sender
today).

## Consequences

- Sending no longer requires a Node.js runtime on the sending machine —
  `cargo build --release` produces a single static binary.
- `nodejs/` doesn't disappear: `porter join` remains TypeScript and
  un-ported. A future spec should decide its Rust port (if any) — likely
  smaller in scope than `serve` was, since it's pure local file
  concatenation/verification with no networking.
- `axum`/`tokio` are now dependencies of `porter-sender` even for the
  sender (non-`serve`) invocation path, since both subcommands share one
  binary — the sender's own code paths stay synchronous/blocking (no
  `async fn` in the CLI/renderer/slideshow-loop code), only `serve`'s
  code is `async`. This costs some binary size and link time versus a
  sender-only build, accepted as the price of one binary instead of two.
- Two implementations of the fountain PRNG/degree table and wire format
  now exist (Rust sender, Dart receiver, plus the still-present
  TypeScript versions until cutover) — any future change to either must
  be mirrored in the other and re-verified via the fixture test, or
  fountain-mode transfers break silently.
- No signing/packaging/distribution pipeline (cross-compilation matrix,
  GitHub Releases binary uploads) is in scope — a working
  `cargo build --release` is the bar for this pass, not shipping
  installers.
- `.porter_history` (progress-resume state) moves from always-on (TS's
  `state.ts` writes it unconditionally on every slideshow save) to
  opt-in-via-flag in the Rust sender — the no-network/no-cloud air-gapped
  premise extends to "no default disk trace" too. TS's behavior is
  unaffected since `nodejs/` isn't being modified.

## Open questions

- Whether/when `porter join` gets ported, and to what shape — deliberately
  deferred, not decided here.
- Whether the Rust sender's fountain/QR logic should ever become a shared
  crate — explicitly a non-goal for the initial port; revisit only if a
  second consumer actually materializes.
- The TS server-side fountain decoder (`nodejs/src/lib/fountain-decoder.ts`)
  has no cap on its Gaussian-elimination fallback, unlike the Dart
  receiver's `maxEliminationMissingCount = 500` (see
  [ADR-0002](0002-fountain-vs-sequential.md)) — an O(K²)/O(K³) stall risk
  on a large fountain transfer through `porter serve`. The Rust port of
  `porter serve`'s decoder follows the Dart (capped) behavior; the TS
  decoder itself is unpatched (`nodejs/` untouched by this ADR) and
  should get a follow-up fix.
