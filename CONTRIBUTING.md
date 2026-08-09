# Contributing

## Prerequisites

- Rust (stable) for the sender — `rust-sender/`.
- Flutter (stable channel) for the receiver app.
- Node + pnpm (versions pinned in `mise.toml` — `mise install` if you use
  mise) for the repo-wide JS tooling (prettier, eslint, markdownlint),
  which lives in `nodejs/`. The `nodejs/` package itself is **deprecated
  and fully superseded** by `rust-sender/` — see `docs/adr/0006-*.md`.

## Getting started

```bash
cd rust-sender && cargo build --release
cd flutter && flutter pub get
pnpm install               # nodejs/ workspace deps + repo JS tooling
```

Sending: `mise run rust-send <file>` or
`rust-sender/target/release/porter-sender <file> --slideshow`.
Receiving: `cd flutter && flutter run` on a device, point it at the sender.

## Before you push

```bash
# rust-sender/
cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check

# flutter/
flutter test
flutter analyze

# nodejs/ (deprecated — only if you touched join)
cd nodejs && pnpm test

# lint/format the whole repo (tooling lives in nodejs/)
mise run node-lint
```

Or via `mise run rust-check` / `mise run rust-test` from the root. No
pre-commit/pre-push hooks are wired up today — run these by hand for
whichever side you touched.

## Project structure

- `rust-sender/` — the active sender: QR-slideshow TUI + `porter serve`
  (`src/main.rs`, `src/tui.rs`, `src/serve.rs`, etc.). See
  [`rust-sender/README.md`](rust-sender/README.md).
- `nodejs/` — original TypeScript sender CLI (`src/porter.ts` +
  `src/lib/`). `serve`/`join` stay here indefinitely; the QR-display
  sender code is superseded (see `docs/adr/0004-*.md`).
- `flutter/` — receiver app. See
  [`flutter/docs/architecture.md`](flutter/docs/architecture.md).
- `docs/adr/` — architecture decision records.

## Conventions

- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `chore:`, scoped e.g. `feat(flutter): ...`).
  release-please parses these to cut releases and generate
  `CHANGELOG.md` — never hand-edit that file.
- **Decisions:** record significant/architectural choices as an ADR in
  [`docs/adr/`](docs/adr/).
- **Wire format:** anything touching the fountain PRNG/degree table or the
  chunk wire formats must stay bit-identical across sender and receiver —
  see `docs/adr/0002-*.md`.

## Tests

- `rust-sender/src/**/*.rs` (`#[cfg(test)] mod tests`) — `cargo test`.
- `nodejs/src/lib/*.test.ts` — node's built-in test runner (`pnpm test`).
- `flutter/test/**` — `flutter test` (unit + widget).
- Cross-language wire-format parity uses shared fixtures (e.g.
  `flutter/test/fixtures/fountain_sample.json`, checked from Rust, Dart,
  and originally TypeScript) rather than one language's suite driving
  another.
