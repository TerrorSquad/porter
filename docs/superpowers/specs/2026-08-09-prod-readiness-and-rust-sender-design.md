# Porter: Prod-Readiness Pass + Rust Sender Port

**Status**: Approved for implementation
**Date**: 2026-08-09

## Context

Porter (air-gapped file transfer via dynamic QR codes) has grown through a
series of feature branches — fountain codes, Android build, the Flutter
receiver's isolate migration and disk-resume support — without corresponding
investment in repo hygiene, CI, or documentation of _why_ the bigger
architectural calls were made. Separately, the Node.js/TypeScript sender
(`nodejs/`) has been identified as a target for a full rewrite: the user
wants a single static binary (no Node.js runtime dependency on the sending
machine, which matters for an air-gapped tool) and is drawn to Rust's
terminal-UI ecosystem (`ratatui`) for building richer sender controls
(speed adjustment, jump-to-chunk, gap-fill looping) than the current
hand-rolled-ANSI TypeScript sender supports.

This session budget runs out at the next token reset (~4am); implementation
starts fresh after that, building on top of the currently-open
`feat/receiver-isolate-refactor` PR (#7). This document is the spec to
implement against — six workstreams, sequenced so the cheap/low-risk ones
land first and the large Rust port (open-ended, can safely spill into a
follow-up session) goes last.

`porter serve` (HTTP receiver) and `porter join` (multi-part joiner) are
explicitly **deferred, not ported tonight** — see the note in workstream 6.
`nodejs/` stays alive for those two subcommands; only the QR-display sender
portion moves to Rust in this pass.

## Workstreams, in implementation order

### 1. Meta-docs

- **`CLAUDE.md`** at repo root. Terse, one `##` section per subsystem
  (matching the pattern from `/Users/gninkovic/projects/gstack`'s
  `CLAUDE.md`): package manager/tooling, Flutter receiver pointer (link to
  `flutter/docs/architecture.md`), Rust sender pointer (once it exists),
  testing conventions, commit conventions. 5–15 lines per section, no
  fluff.
- **`CONTRIBUTING.md`**: Prerequisites → Getting started → Before you push
  → Project structure → Conventions → Tests (gstack's structure).
- **`CHANGELOG.md`** + **release-please** config (`.release-please-manifest.json`,
  a `release-please.yml` GitHub Action), conventional-commits based. The
  repo's git history is already conventional-commit-styled
  (`feat(flutter): ...`, `fix(flutter): ...`), so this is wiring up
  automation, not changing habits.
- Fix root `package.json`: `"name": "php_booster"` is a stale leftover from
  an unrelated template — rename to something reflecting this repo (e.g.
  `"porter"`).
- Fix `flutter/README.md`: replace "Status: Initial scaffold complete" and
  the now-inaccurate feature table (references a deleted `result_screen.dart`
  flow) with current reality — point at `flutter/docs/architecture.md` for
  the real architecture description rather than duplicating it.

### 2. CI

`.github/workflows/` (currently doesn't exist at all — zero CI today):

- **`flutter-ci.yml`**: triggered on PRs touching `flutter/**`. Steps:
  `flutter pub get`, `flutter test`, `flutter analyze`. No app builds, no
  signing, no secrets — matches the "test+analyze only" decision made
  during design.
- **`rust-ci.yml`** (once the Rust sender exists — see workstream 6):
  `cargo test`, `cargo clippy -- -D warnings`, `cargo fmt --check`.
- **No `nodejs-ci.yml`.** `nodejs/` is being replaced by the Rust sender
  and isn't getting active investment (workstream 4 already dropped its
  dependency updates); adding CI for a codebase on its way out isn't
  worth it. `porter serve`/`porter join` staying TypeScript (workstream 6)
  means they stay untested by CI — rely on local `pnpm test` if/when
  they're touched. Revisit if/when a `serve`/`join` port spec materializes.

### 3. Architecture docs

`docs/adr/` using the gstack template — `# ADR-000N: Title` → `## Context`
→ `## Options (verified <date>)` → `## Decision` → `## Consequences` →
`## Open questions`, plus a `docs/adr/README.md` index:

- **ADR-0001**: Flutter receiver isolate migration — why a long-lived
  worker isolate over `compute()`/`Isolate.run()`, what crosses the isolate
  boundary and what doesn't (lightweight `ProgressSnapshot`s, never the
  `chunks` byte map).
- **ADR-0002**: Fountain (LT-code) vs. sequential chunk encoding — when
  each is used, the redundancy factor (N=3K) and why, the GF(2) elimination
  cap (`maxEliminationMissingCount`).
- **ADR-0003**: Disk hydration design — trusting `.bin` filenames over
  `metadata.json`, lazy byte-loading via `Transfer.chunkReader`, the known
  fountain-mode limitation (peeling state isn't persisted, resumed fountain
  transfers restart peeling from scratch).
- **ADR-0004**: Sender language — TypeScript → Rust. Records the actual
  reasoning from this session: single-static-binary was the primary driver
  (no Node.js runtime needed on the sending machine, which matters for an
  air-gapped tool), Rust's `ratatui`/`crossterm` ecosystem was the
  secondary driver over Go's more hand-rolled terminal-control story.
  Notes what must stay bit-identical across the language boundary (the
  xorshift32 PRNG + degree table, since the already-shipped Dart receiver
  depends on it) and what's a clean rewrite (everything else).

### 4. Dependency updates (Flutter only)

Node dependency updates are **dropped entirely** — the sender portion of
`nodejs/` is being replaced (workstream 6) and `porter serve`/`porter
join` (the parts that remain) aren't getting active feature investment
right now either, so bumping their deps isn't worth the risk/effort
tonight.

- Bump non-`mobile_scanner` Flutter deps (`archive`, `share_plus`,
  `path_provider`, `flutter_lints`, `file_picker`, `url_launcher`,
  `shared_preferences`, `http`, `crypto`, `convert`, `provider`) via
  `flutter pub upgrade --major-versions`, then run the full test suite
  (`flutter test`) and `flutter analyze` before committing. If any bump
  breaks something, that specific package's bump gets reverted/pinned
  rather than blocking the rest.
- `mobile_scanner` (the vendored fork at `flutter/third_party/mobile_scanner`,
  pinned to 7.2.0 vs. upstream 7.4.0) stays pinned. This needs manually
  re-diffing the macOS camera-enumeration patch onto a newer upstream
  release — real effort, real risk of breaking camera selection, and the
  7.2→7.4 changelog is mostly camera lifecycle/orientation fixes, not
  urgent. Recorded as a known gap (a `docs/adr/` entry or a `TODO` comment
  pointing at this spec) rather than silently ignored.

### 5. Code cleanup

Folded into the verification steps of workstreams 1 and 4 rather than run
as a separate deep audit — fix anything else obviously stale/wrong
encountered while touching each area (e.g. `flutter/docs/architecture.md`
already had one stale file-tree reference fixed in a prior session; check
for others in the same pass).

### 6. Rust sender — QR-display sender only (serve/join deferred)

**Scope**: full feature-parity rewrite of the QR-display sender path
(`porter.ts` + `renderer.ts`/`chunker.ts`/`fountain.ts`/`state.ts`), plus
the new TUI controls. `porter serve` (HTTP receiver, `receiver.ts`, 876
lines) and `porter join` (multi-part joiner, `joiner.ts`, 178 lines) are
**explicitly deferred** — not ported tonight. `nodejs/` stays in the repo
for those two subcommands; it is _not_ retired at the end of this
workstream, only slimmed down once/if the sender path is fully verified
and cut over.

Rationale for deferring: `serve`/`join` are a genuinely separate problem
(HTTP server, multipart parsing, LAN-facing) from the terminal QR sender,
with their own framework decision to make (see "Deferred, not in scope
tonight" below). Porting them can be a follow-up spec once the sender
port has proven the wire-format-compatibility approach works end-to-end
against the real Flutter receiver.

#### What must stay bit-identical

- Chunk wire formats: `index|total|mode|id|payload` (sequential),
  `F|seq|K|fileSize|id|payload` (fountain), `CHECKSUM|T|id|sha256`.
- The xorshift32 PRNG (Marsaglia, shifts 13/17/5) and the integer-weighted
  degree table (`buildDegreeTable`/`sampleIndices`) — the already-shipped
  Dart receiver (`flutter/lib/services/fountain_codec.dart`) derives
  `(degree, indices)` from `seq` independently on the decode side; any
  drift breaks fountain-mode transfers silently. Verify via a cross-language
  fixture test (the existing `test/fixtures/fountain_sample.json` pattern
  used by both the current TS and Dart test suites — regenerate an
  equivalent fixture from the Rust encoder and confirm the Dart decoder
  still accepts it byte-for-byte).
- QR version-selection heuristic (terminal rows → max version that fits,
  the `(availableRows * 2 - 17 - 4) / 4` formula in `chunker.ts`/`fountain.ts`).
- Half-block Unicode rendering (`█`/`▀`/`▄`/` `) with the DEC
  synchronized-output escapes (`\x1b[?2026h` / `\x1b[?2026l`) — this is
  what prevents camera-visible tearing mid-frame; losing it would
  regress an already-solved problem.

#### Feature surface to port (from `nodejs/src/porter.ts` + `lib/`)

**Sender (QR display)**:

- QR code generation: the `qrcode` crate (crates.io) is the leading
  candidate — verify during implementation that it exposes per-module
  bit access (dark/light grid cells), since the half-block renderer needs
  raw module data, not a pre-rendered image. If it doesn't expose that
  cleanly, fall back to porting the encoder logic directly (QR encoding
  itself is a fixed, well-specified algorithm — not a large port if
  needed).
- Input: single file, multi-part `.partNNN`/`.partXX` auto-concatenation
  (`--split-aware`), stdin.
- Encoding: sequential (`Chunker`) and fountain (`FountainChunker`),
  `--base64`, `--verify=<checksum-file>`.
- Rendering: half-block QR, quiet-zone border, `--invert`, multi-QR grid
  (`--multi=N|auto`, auto-fits to terminal size), `--ecc=L|M|Q|H`,
  `--no-info` sidebar toggle, `--buffer=N`.
- Playback: slideshow loop, `--speed=<seconds>`, resize-reactive
  re-layout, progress persistence across restarts (mirrors `state.ts`'s
  `.porter_history` file).
- **New controls** (the actual feature request, not present in the TS
  sender today): `+`/`-` speed adjust, arrow-key single-step,
  Shift+arrow turbo-scrub (jump ~100 chunks), `J` jump-to-chunk (prompt
  for index), `G` gap-fill mode (paste/load a list or ranges of missing
  chunk indices, loop only those until cleared), pause/play toggle.

#### Deferred, not in scope tonight

- **`porter serve`** (HTTP receiver, `receiver.ts`, 876 lines) and
  **`porter join`** (multi-part joiner, `joiner.ts`, 178 lines) stay
  TypeScript. If/when they're ported later: the current implementation is
  a hand-rolled HTTP server (Node's built-in `http` module, no framework)
  with hand-rolled multipart parsing (boundary detection via regex,
  manual buffer slicing) — a future spec should decide `axum` vs.
  hand-rolled `hyper`, and `multer` vs. continuing the hand-rolled
  tradition, rather than deciding it implicitly by what's convenient
  mid-implementation.

#### Explicit non-goals for this workstream

- Porting `porter serve`/`porter join` (see Deferred, above).
- No signing/packaging/distribution pipeline (e.g. cross-compilation
  matrix, GitHub Releases binary uploads) — building a working `cargo
build --release` binary is the bar, not shipping installers.
- No attempt to unify the Rust sender's fountain/QR logic into a shared
  crate consumable by anything else — it's a standalone binary.

## Verification

- **Workstreams 1–5**: `flutter test` and `flutter analyze` pass after
  every dependency bump; CI workflows verified by opening a throwaway PR
  (or `act`-style local run) to confirm they actually trigger and pass;
  ADRs reviewed for accuracy against the current code (not just written
  once and forgotten).
- **Workstream 6**: `cargo test` covering the ported chunker/fountain
  logic with golden-vector tests mirroring the existing TS
  (`fountain.test.ts`, `chunker.test.ts`) and Dart
  (`fountain_decoder_test.dart`) test suites. End-to-end verification:
  run the new Rust sender against the real, already-working Flutter
  receiver (the exact manual test loop used throughout this session) —
  send a real file, confirm the receiver decodes it correctly, in both
  sequential and fountain mode. `nodejs/`'s TypeScript sender
  (`porter.ts`'s slideshow path) can be removed once the Rust sender has
  reached parity and been used for a real transfer; `porter serve`/
  `porter join` remain in `nodejs/` regardless (see Deferred, above), so
  `nodejs/` itself stays in the repo either way.
