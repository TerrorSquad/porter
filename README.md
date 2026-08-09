# Porter — Air-Gapped File Transfer via QR Codes

**Transfer files between computers without a network. Scan QR codes from a terminal with any device camera.**

```bash
porter-sender myfile.txt
# → Phone scans QR codes, file is reassembled locally
```

## 📦 Components

| Component                                   | Role                                                                              | Status                                                                                                    |
| ------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| **[`rust-sender/`](rust-sender/README.md)** | Terminal QR-slideshow sender + `porter serve` HTTP receiver, single static binary | Active — the primary sender going forward                                                                 |
| **[`flutter/`](flutter/README.md)**         | Receiver app (Android + macOS), scans QR frames and reassembles the file          | Active — the real receiver, in daily use                                                                  |
| **[`nodejs/`](nodejs/README.md)**           | Original TypeScript sender — **deprecated**                                       | Deprecated, not in CI. Only `porter join` is still current; `serve` and the sender live in `rust-sender/` |

Why the sender moved to Rust: a single static binary needs no Node.js
runtime on the sending machine, which matters for an air-gapped tool. See
[`docs/adr/0004-sender-language-rust.md`](docs/adr/0004-sender-language-rust.md).

## 🚀 Quick Start

```bash
cd rust-sender
cargo build --release
./target/release/porter-sender myfile.txt --slideshow
```

Or with `mise` from the repo root: `mise run rust-install` builds and
copies the binary to `~/.local/bin/porter-sender`.

**→ See [rust-sender/README.md](rust-sender/README.md) for the full sender
docs (controls, `--fountain`, `porter serve`) and
[flutter/README.md](flutter/README.md) for the receiver app.**

## 🎯 How It Works

```text
Offline Computer              Phone / Receiver
   (Sender)                    (Scanner)
       │
       ├─ Read file
       ├─ Split into chunks
       ├─ Encode as Base64 (binary) or fountain (LT code)
       ├─ Create QR codes
       └─ Display slideshow
              │
              │ [QR Code Stream]
              │
              └──→ Camera scans
                   ├─ Detect QR
                   ├─ Parse header
                   ├─ Assemble chunks
                   └─ Save file
```

## 🚀 Features

✅ **Offline** — No internet, no cloud, no telemetry
✅ **Fast** — chunks/sec depends on lighting and terminal size; `--multi` renders several QR codes per frame
✅ **Single binary** — the Rust sender needs no runtime installed on the sending machine
✅ **Reliable** — header protocol handles dropped/reordered chunks
✅ **Flexible** — works with any camera, terminal, phone OS
✅ **Fountain mode** — `--fountain` (LT codes): rebuild a file from _any_ sufficient subset of frames, ideal for long/lossy scans
✅ **Resumable receiver** — the Flutter app resumes an interrupted transfer from on-disk chunks, no re-scanning

## 💾 What's Inside

```text
.
├── rust-sender/            # Rust sender + porter serve (primary sender)
│   └── src/                # cli, chunker, fountain, renderer, tui, serve
├── flutter/                # Receiver app (Android/macOS)
│   └── lib/                # services (assembler, fountain decoder), providers, screens
├── nodejs/                 # DEPRECATED TypeScript sender; only join is current
│   └── src/lib/            # chunker, renderer, receiver, joiner, fountain
├── docs/adr/                # Architecture decision records
├── mise.toml
└── README.md
```

## 📱 Wire Format

Sequential chunks: `index|total|mode|id|payload`. Fountain (LT code)
symbols: `F|seq|K|fileSize|id|payload`. Checksum: `CHECKSUM|T|id|sha256`.
Any conformant receiver just needs to parse this format — the xorshift32
PRNG and degree table that derive `(degree, indices)` for fountain mode
must stay bit-identical across implementations; see
[`docs/adr/0002-fountain-vs-sequential.md`](docs/adr/0002-fountain-vs-sequential.md).

## 🔐 Security

- **Offline by design** — no network calls from the sender or the QR path
- **No default disk trace** — the Rust sender's slideshow-position file (`.porter_history`) is opt-in via `--resume`, not written by default
- **No telemetry** — no analytics or tracking anywhere
- **Local processing** — all QR generation and decoding on-device

## 🔨 Development

```bash
mise run rust-build     # cargo build --release
mise run rust-test       # cargo test
mise run rust-check      # cargo clippy + cargo fmt --check
mise run flutter-build   # flutter build macos --release
mise run node-build      # pnpm run build (nodejs/, deprecated)
mise run node-lint       # prettier + eslint + markdownlint (whole repo)
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for prerequisites and conventions,
and [`docs/adr/`](docs/adr/) for the architectural decisions behind the
receiver's worker isolate, the fountain codec, and the sender's Rust move.

## 🤝 Contributing

This is a hobby project, but PRs welcome for:

- Performance improvements
- Better error messages
- New receiver platforms (iOS, desktop)
- Documentation improvements

## 📄 License

ISC

---

Made with ❤️ for secure, offline file transfer.
