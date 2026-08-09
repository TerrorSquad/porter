# CLAUDE.md

Guidance for Claude Code working in this repo.

## What this is

Porter: air-gapped file transfer via dynamic QR codes. A terminal sender
displays a file as a slideshow of QR frames; a phone app scans and
reassembles them. No network, no cloud — the QR codes are the wire.

## Package manager

`rust-sender/` uses `cargo`; `flutter/` uses `pub`. There is **no
JavaScript in this repo** — no `package.json`, no `node_modules`, no
pnpm/npm/yarn. Don't add one back without a decision to match: the Node
package and its prettier/eslint/markdownlint toolchain were deleted
outright (ADR-0006), and release-please now tracks `version.txt`
(`release-type: simple`) rather than a manifest version.

Formatting is per-language and self-contained: `cargo fmt` for Rust,
`dart format` for Dart, `.editorconfig` for everything else (JSON, YAML,
Markdown). Nothing formats Markdown automatically anymore — that is
intentional, not an oversight.

## Sender (`rust-sender/`)

The active sender — a ratatui TUI (QR grid, sidebar, status/input line)
plus `porter serve` (HTTP receiver on `axum`), single static binary, no
Node.js runtime needed. See `docs/adr/0004-*.md` for why it replaced the
TypeScript sender. `cargo test` / `cargo clippy --all-targets` / `cargo
fmt --check` from `rust-sender/`; `mise run rust-*` tasks from the root.

## Sender, legacy (`nodejs/`) — DELETED

The TypeScript implementation is gone (ADR-0006). Every feature it had is
in `rust-sender/`: the sender, `porter serve` (`serve.rs`) and `porter
join` (`join.rs`). Rust source files still cite `nodejs/src/...` paths in
their `//!` headers as the origin of each port — those are historical
references, readable via `git show backup-before-scrub:nodejs/...`, not
live paths. Don't recreate the directory.

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
