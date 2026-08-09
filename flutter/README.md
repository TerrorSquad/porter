# Porter Receiver — Flutter App

Fast offline QR code file receiver for Android and macOS.

**Status**: In active use. See [docs/architecture.md](docs/architecture.md) for
the real architecture (worker isolate, fountain decoding, disk resume) —
sections below cover quick start and workflow only.

## Quick Start

```bash
# 1. Install Flutter (if not already done)
# https://flutter.dev/docs/get-started/install

# 2. Get dependencies
flutter pub get

# 3. Run on device
flutter run

# 4. Point phone at QR codes from Node.js sender
# cd ../nodejs && ./dist/porter.mjs myfile.pdf --slideshow
```

## What's Included

| Component        | Notes                                                                |
| ---------------- | -------------------------------------------------------------------- |
| QR scanning      | Uses `mobile_scanner` (vendored fork — see architecture doc)         |
| Chunk parsing    | Sequential (T/B/C modes) and fountain (LT code)                      |
| Data assembly    | Worker isolate, gzip decompression, SHA-256, GF(2) fallback          |
| Disk resume      | Hydrates in-progress transfers from `chunk_NNNNNN.bin` on cold start |
| File I/O         | Saves to Downloads                                                   |
| UI (scanning)    | Progress bar, torch control                                          |
| UI (transfers)   | Transfer list / history                                              |
| State management | Provider pattern; worker isolate owns decode state                   |

## Project Structure

See [docs/architecture.md](docs/architecture.md) for the full, kept-current
file tree and data flow — not duplicated here to avoid drifting out of sync
again.

## Key Features

- **Real-time scanning** — No manual triggers, continuous QR detection
- **Offline only** — No internet, no cloud, no telemetry
- **Multiple modes** — Text, Binary, Compressed (gzip), Fountain (LT code)
- **Resumable** — killed/relaunched app resumes from on-disk chunks
- **SHA-256 verification** — Checksum validation on completion
- **Dark theme** — optimized for low light

## Performance

Scan/decode speed depends on device CPU, lighting, and QR code size. See
[docs/architecture.md](docs/architecture.md) for the actual bottlenecks
found and fixed (worker isolate migration, GF(2) elimination cap, debounced
metadata writes) and current memory characteristics.

## Building

### Android APK

```bash
flutter build apk --release
# → build/app/outputs/flutter-app/release/app-release.apk
```

### macOS App

```bash
flutter build macos --release
# → build/macos/Build/Release/porter_receiver.app
```

## Development

### Hot reload

```bash
flutter run
# Press 'r' to reload, 'R' to restart
```

### Tests

```bash
flutter test
```

### Logs

```bash
flutter logs
```

## Architecture

Camera → `mobile_scanner` → `ChunkParser` → worker isolate (`Assembler` +
`FountainDecoder` + disk I/O) → `ProgressSnapshot` → `ScannerProvider` → UI.
See [docs/architecture.md](docs/architecture.md) for the full breakdown,
including why decoding runs off the UI thread and how disk resume works.

## Docs

- **[features.md](docs/features.md)** — What's implemented, TODO, testing checklist
- **[architecture.md](docs/architecture.md)** — Data flow, class design, performance notes
- **[setup.md](docs/setup.md)** — Installation, build, deployment, troubleshooting
- **[ANDROID_APP_SPEC.md](docs/ANDROID_APP_SPEC.md)** — Original design spec (historical; see architecture.md/features.md for current reality)

## Workflow

### Sending (Node.js CLI)

```bash
cd ../nodejs
./dist/porter.mjs largefile.tar.gz --slideshow
```

### Receiving (Flutter App)

1. Launch app on Android device or macOS
2. Point at QR codes from sender (auto-starts scanning)
3. App detects and assembles chunks automatically, showing live progress
4. On completion, file is saved and SHA-256 verified automatically

`porter serve`/`porter join` (HTTP relay, multi-part joining) remain
TypeScript-only for now — see the root [`docs/adr/`](../docs/adr/) for the
sender's Rust migration status.

## Limitations

- **QR size limit**: QR codes have max ~2KB capacity; files are split into chunks
- **Lighting dependent**: Poor lighting = dropped frames = slower scanning

## Testing

```bash
flutter test
```

Manual end-to-end test with the Node.js sender:

```bash
cd nodejs && ./dist/porter.mjs test.txt --slideshow --speed=0.5
# Device: open app, scan codes — file should assemble, verify, and save
```

For detailed test cases, see [docs/features.md](docs/features.md#testing-checklist).

## License

ISC (same as Porter)
