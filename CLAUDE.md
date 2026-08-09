# CLAUDE.md

Guidance for Claude Code working in this repo.

## What this is

Porter: air-gapped file transfer via dynamic QR codes. A terminal sender
displays a file as a slideshow of QR frames; a phone app scans and
reassembles them. No network, no cloud — the QR codes are the wire.

## Package manager

`nodejs/` uses **pnpm** (`pnpm-workspace.yaml`, `pnpm-lock.yaml`). Never
`npm` or `yarn`. `rust-sender/` uses `cargo`. Tool versions pinned in
`mise.toml`.

All JS tooling — `package.json`, prettier, eslint, markdownlint — lives in
`nodejs/`, not the root. Prettier and markdownlint still cover the whole
repo via `../` globs in their configs; run them with `mise run node-lint`
or `pnpm --dir nodejs exec <tool>`. The root keeps no `package.json`;
release-please tracks `version.txt` (`release-type: simple`).

## Sender (`rust-sender/`)

The active sender — a ratatui TUI (QR grid, sidebar, status/input line)
plus `porter serve` (HTTP receiver on `axum`), single static binary, no
Node.js runtime needed. See `docs/adr/0004-*.md` for why it replaced the
TypeScript sender. `cargo test` / `cargo clippy --all-targets` / `cargo
fmt --check` from `rust-sender/`; `mise run rust-*` tasks from the root.

## Sender, legacy (`nodejs/`) — DEPRECATED

TypeScript CLI (`porter.ts`), built with Rollup to a standalone `.mjs`.
Deprecated and not covered by CI. `porter serve` **is** ported (see
`rust-sender/src/serve.rs`); `porter join` (`joiner.ts`, 178 lines) is the
only subcommand with no Rust equivalent and the only reason this package
still exists. The sender path prints a deprecation warning at startup.
Don't build new work here — port to `rust-sender/` instead. `pnpm test`
(node's `--test` runner) from `nodejs/`.

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
