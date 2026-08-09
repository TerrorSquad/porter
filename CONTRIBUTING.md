# Contributing

## Prerequisites

- Rust (stable) for the sender — `rust-sender/`.
- Flutter (stable channel) for the receiver app.

That is the whole list. There is no JavaScript in this repo — the Node
package and its toolchain were removed in `docs/adr/0006-*.md`.

## Getting started

```bash
cd rust-sender && cargo build --release
cd flutter && flutter pub get
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
```

Or via `mise run rust-check` / `mise run rust-test` from the root.

A `forge` pre-commit hook runs `cargo fmt` and `dart format` on staged
changes (`mise run hooks-install` to set it up). Everything else — tests,
clippy, `flutter analyze` — is on you to run for whichever side you
touched.

## Project structure

- `rust-sender/` — the active sender: QR-slideshow TUI + `porter serve`
  (`src/main.rs`, `src/tui.rs`, `src/serve.rs`, etc.). See
  [`rust-sender/README.md`](rust-sender/README.md).
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
- `flutter/test/**` — `flutter test` (unit + widget).
- Cross-language wire-format parity uses shared fixtures (e.g.
  `flutter/test/fixtures/fountain_sample.json`, checked from Rust and
  Dart) rather than one language's suite driving another.
