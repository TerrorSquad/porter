# Porter — Rust Sender

Single-binary QR-slideshow sender (`porter-sender <file>`) and HTTP
receiver (`porter-sender serve`), replacing the TypeScript sender's
QR-display path. No Node.js runtime required on the sending machine — see
[`docs/adr/0004-sender-language-rust.md`](../docs/adr/0004-sender-language-rust.md)
for why.

## Quick Start

```bash
cargo build --release
./target/release/porter-sender myfile.txt
```

Or via `mise` from the repo root:

```bash
mise run rust-install   # builds + copies to ~/.local/bin/porter-sender
porter-sender myfile.txt
```

## Sending

A full ratatui TUI: a QR grid, a bordered sidebar (chunk/progress/version/
ETA/elapsed/loop count), and a status/input line.

```bash
porter-sender myfile.txt --slideshow --speed=0.3
porter-sender bigfile.bin --fountain          # LT-code, any sufficient subset
```

Controls: `→`/`l`/`k`/space next, `←`/`h`/`j` back, `Shift+←→` scrub ~100
chunks, `J` jump to a chunk, `G` gap-fill mode (loop only specific
indices), `+`/`-` speed, `I` toggle the sidebar, `S` toggle slideshow,
`Q` quit. `--resume` persists slideshow position across restarts via
`.porter_history` (off by default — no disk trace unless requested).

Run with no arguments for the full flag list.

## Receiving (`porter serve`)

```bash
porter-sender serve --port=8080 --output-dir=received
```

Accepts raw uploads, `multipart/form-data`, and QR-scan JSON (sequential,
fountain, and checksum frames) at `POST /upload`; auto-joins completed
transfers. Built on `axum` — see the ADR above for why over hand-rolled
`hyper`.

## What's not here

`porter join` (multi-part joiner) stays in [`nodejs/`](../nodejs) —
deliberately not ported yet, see the ADR's open questions.

## Development

```bash
cargo test              # 11 tests, includes cross-language fixture parity
                         # against flutter/test/fixtures/fountain_sample.json
cargo clippy --all-targets -- -D warnings
cargo fmt --check
```

Or via `mise`: `rust-build`, `rust-test`, `rust-check`, `rust-send`,
`rust-serve` (see the repo root [`mise.toml`](../mise.toml)).

The fountain PRNG/degree table and wire format
(`index|total|mode|id|payload`, `F|seq|K|fileSize|id|payload`,
`CHECKSUM|T|id|sha256`) must stay bit-identical to the Dart receiver
(`flutter/lib/services/fountain_codec.dart`) and the TypeScript sender —
see [`docs/adr/0002-fountain-vs-sequential.md`](../docs/adr/0002-fountain-vs-sequential.md).
