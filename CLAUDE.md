# CLAUDE.md

Guidance for Claude Code working in this repo.

## What this is

Porter: air-gapped file transfer via dynamic QR codes. A terminal sender
displays a file as a slideshow of QR frames; a phone app scans and
reassembles them. No network, no cloud — the QR codes are the wire.

## Package manager

Root and `nodejs/` use **pnpm** (`pnpm-workspace.yaml`, `pnpm-lock.yaml`).
Never `npm` or `yarn`. `rust-sender/` uses `cargo`. Tool versions pinned
in `mise.toml`.

## Sender (`rust-sender/`)

The active sender — a ratatui TUI (QR grid, sidebar, status/input line)
plus `porter serve` (HTTP receiver on `axum`), single static binary, no
Node.js runtime needed. See `docs/adr/0004-*.md` for why it replaced the
TypeScript sender. `cargo test` / `cargo clippy --all-targets` / `cargo
fmt --check` from `rust-sender/`; `mise run rust-*` tasks from the root.

## Sender, legacy (`nodejs/`)

TypeScript CLI (`porter.ts`), built with Rollup to a standalone `.mjs`.
`porter serve` and `porter join` (multi-part joiner) stay here
indefinitely — not on the Rust replacement path (`porter join` isn't
ported at all yet). The QR-display/slideshow sender code here is dead
once the Rust sender is the daily driver, kept only until `porter
serve`/`porter join` are addressed separately. `pnpm test` (node's
`--test` runner) / `pnpm run build` from `nodejs/`.

## Receiver (`flutter/`)

Flutter app (Android + macOS), scans QR frames and reassembles the file.
Long-lived worker isolate owns decoding/disk I/O; only lightweight
`ProgressSnapshot`s cross back to the UI isolate — see
[`flutter/docs/architecture.md`](flutter/docs/architecture.md) for the full
data flow and [`docs/adr/`](docs/adr/) for why. `flutter test` / `flutter
analyze` from `flutter/`.

## Wire format

Sequential: `index|total|mode|id|payload`. Fountain (LT code):
`F|seq|K|fileSize|id|payload`. Checksum: `CHECKSUM|T|id|sha256`. The
xorshift32 PRNG + degree table that derives fountain `(degree, indices)`
from `seq` must stay bit-identical across sender and receiver
implementations — see `docs/adr/0002-*.md` and `docs/adr/0004-*.md`.

## Testing conventions

- Flutter: `flutter test` (unit + widget), `flutter analyze` (lint/type
  check). No golden-image tests today.
- Rust: `cargo test` (includes cross-language fixture parity tests).
- Node.js: `pnpm test` (node's built-in test runner over `src/lib/*.test.ts`).
- Cross-language wire-format parity is verified via shared fixtures (e.g.
  `flutter/test/fixtures/fountain_sample.json`), not by running one
  language's tests against another.

## Commit conventions

[Conventional Commits](https://www.conventionalcommits.org/) (`feat:`,
`fix:`, `docs:`, `chore:`, scoped like `feat(flutter): ...`). The git
history is already consistent with this — release-please parses it to cut
releases and generate `CHANGELOG.md` (never hand-edit that file).

## Decisions

Significant/architectural choices are recorded as ADRs in
[`docs/adr/`](docs/adr/) — check there before assuming a design is
accidental.
