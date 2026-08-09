# Porter Android App — Architecture

## Project Structure

```text
flutter/
├── lib/
│   ├── main.dart                    # App entry point, theme setup
│   ├── models/
│   │   ├── chunk.dart               # DataChunk, FountainChunk, ChecksumChunk parsing
│   │   ├── transfer.dart            # Transfer state (id, chunks, progress) — the
│   │   │                            #   main isolate's mirror only carries scalars,
│   │   │                            #   see applySnapshot()
│   │   ├── progress_snapshot.dart   # Lightweight cross-isolate progress payload
│   │   └── hydrated_transfer.dart   # Rebuilt-from-disk transfer state
│   ├── services/
│   │   ├── chunk_parser.dart        # QR → chunk/checksum parsing
│   │   ├── assembler.dart           # Core assembly logic, SHA-256, gzip — runs
│   │   │                            #   entirely inside the worker isolate
│   │   ├── assembler_worker.dart    # Long-lived worker isolate + main-isolate handle
│   │   ├── fountain_codec.dart      # Shared LT-code PRNG/degree table (TS parity)
│   │   ├── fountain_decoder.dart    # Peeling + capped GF(2) decoder for --fountain
│   │   ├── chunk_storage.dart       # Per-chunk disk writes + disk hydration scan
│   │   ├── chunk_metadata_writer.dart # Debounces metadata.json writes
│   │   └── file_handler.dart        # Save to Downloads/Documents
│   ├── providers/
│   │   └── scanner_provider.dart    # State management (Provider), owns the worker isolate
│   └── screens/
│       ├── scanning_screen.dart     # Main camera + QR detection UI
│       ├── transfers_screen.dart    # Transfer list / history UI
│       └── settings_screen.dart     # App settings
├── android/
│   └── AndroidManifest.xml          # Permissions, app config
├── pubspec.yaml                     # Dependencies
└── docs/
    ├── features.md
    ├── architecture.md (this file)
    ├── setup.md
    └── ANDROID_APP_SPEC.md          # Original design spec (historical)
```

## Data Flow

```text
Camera Frame
    ↓
mobile_scanner (native QR detection, main isolate)
    ↓
ScannerProvider.ingestQR() — posts the raw QR string to the worker isolate
    ═══════════════════ isolate boundary ═══════════════════
    ↓
ChunkParser.parseQR()                                    (worker isolate)
    ↓
Assembler.ingest()                                        (worker isolate)
    ├─ DuplicateCheck (seenIndices)
    ├─ Decode payload (UTF-8, Base64)
    ├─ ChunkStorage.writeChunk() — per-chunk .bin write, async
    ├─ ChunkMetadataWriter.markDirty() — debounced metadata.json (≤ 1/5s)
    └─ tryComplete() when all chunks arrived
         ├─ Concatenate chunks
         ├─ Decompress if mode='C'
         ├─ SHA-256 verification
         └─ onComplete callback → TransferCompletedEvent (assembled bytes)
    ═══════════════════ isolate boundary ═══════════════════
    ↓
ScannerProvider._onWorkerEvent() applies ProgressSnapshot to its Transfer
mirror, notifyListeners()                                  (main isolate)
    ↓
ScanningScreen / TransfersScreen (rebuild)
    ↓
FileHandler.saveFile() (user action)
    ↓
Downloads folder
```

On cold start, `ScannerProvider.hydrateFromDisk()` asks the worker isolate to
scan the output directory for incomplete transfers left over from a killed
run (see [Disk Hydration](#disk-hydration) below) before the user resumes
scanning.

## Core Classes

### Transfer

- Holds metadata: `id`, `total`, `mode`
- Stores chunks in `Map<int, List<int>>` — populated only inside the worker
  isolate; the main isolate's copy of a `Transfer` has this map empty except
  briefly at completion (`assembled` is sent once)
- Tracks deduplication via `seenIndices`
- Status flags: `assembled`, `verified`, `error`
- `applySnapshot(ProgressSnapshot)`: updates all display-relevant fields from
  a cross-isolate snapshot without touching `chunks`

### Assembler

- Maintains `Map<String, Transfer>` for active transfers
- `ingest(raw)`: processes QR strings, returns bool if new data
- `hydrate(List<HydratedTransfer>)`: rebuilds transfers from disk-scanned
  state without re-parsing QR strings (see Disk Hydration)
- `_tryComplete()`: concatenates chunks, decompresses, verifies
- Callbacks: `onProgress`, `onComplete`, `onChunkBytes`, `onChunkReceived`
- Pure logic class with no isolate awareness of its own — it's simply the
  thing that runs _inside_ the worker isolate

### AssemblerWorker (worker isolate)

- `assembler_worker.dart` spawns a single long-lived `Isolate` (not
  `compute()`/`Isolate.run()` — ingest is a continuous stream, not a one-shot
  computation) that owns the real `Assembler`, all per-chunk/metadata disk
  I/O, and the `ChunkMetadataWriter`s
- Only lightweight messages cross the isolate boundary: raw QR strings in;
  `ProgressSnapshotEvent`/`ScanCountedEvent`/`ChunkBytesEvent`/
  `TransferCompletedEvent`/`PersistErrorEvent` out — never the full `chunks`
  map, keeping the UI thread free regardless of transfer size
- `AssemblerWorker` (main isolate) is the handle: `ingestQR()`, `reset()`,
  `setOutputDirectory()`, `flushAll()`, `hydrateFromDisk()`, `dispose()`

### ScannerProvider (Provider pattern)

- Owns the `AssemblerWorker` handle; `ready` resolves once the isolate handshake
  completes (QR strings ingested before that are buffered and replayed)
- Mirrors worker-isolate `Transfer` state locally from `ProgressSnapshot`s
- Tracks stats: `totalScanned`, `duplicatesSkipped`
- Notifies UI on updates
- Methods: `ingestQR()`, `reset()`, `resetAll()`, `flushAll()`,
  `hydrateFromDisk()`

### ChunkParser

- Static `parseQR()`: returns DataChunk | FountainChunk | ChecksumChunk | null
- Handles the formats:
  - Data: `index|total|mode|id|payload`
  - Fountain (LT codes): `F|seq|K|fileSize|id|payload` — Assembler feeds these to
    a per-transfer `FountainDecoder`, which recovers source blocks and pushes
    them through the same `addChunk`/progress machinery as sequential mode
  - Checksum: `CHECKSUM|T|id|sha256`

### FountainDecoder

- Peeling (belief-propagation) decoder with a Gaussian-elimination fallback
  for stalled "stuck core" cases
- `maxEliminationMissingCount` (default 500) caps elimination attempts: above
  that many still-missing blocks, GE's O(N²)/O(N³) cost is skipped entirely
  and only peeling is relied on, so a stalled large-K transfer can't lock the
  isolate running it

### ChunkStorage

- `writeChunk()`: writes one `chunk_NNNNNN.bin` file per received chunk —
  does _not_ touch metadata.json (see ChunkMetadataWriter)
- `writeMetadata()`: full JSON rewrite of a transfer's summary
- `writeAssembledFile()`: writes the final assembled bytes once complete
- `hydrateAll()`: cold-start disk scan (see Disk Hydration)

### ChunkMetadataWriter

- One instance per active transfer (owned by the worker isolate)
- Debounces `metadata.json` writes to at most once per 5 seconds during a
  burst of chunk arrivals; `flush()` forces an immediate write on completion,
  error, or app backgrounding

### FileHandler

- `saveFile(Transfer)`: writes bytes to Downloads
- `_guessExtension()`: magic byte detection (PNG, JPG, PDF, ZIP)
- Fallback to app Documents if Downloads unavailable

## Disk Hydration

On cold start, once `SettingsProvider.ready` resolves and the output
directory is known, `ScanningScreen` calls
`ScannerProvider.hydrateFromDisk(outputDirectory)`, which asks the worker
isolate to scan for transfer directories containing a `chunks/` folder but no
completed final output. `ChunkStorage.hydrateAll()` trusts only the
`chunk_NNNNNN.bin` filenames present as the source of truth for what's been
received — never `metadata.json`'s `seenIndices`, which can legitimately lag
by up to the debounce interval. `metadata.json` is read only for fields not
derivable from the `.bin` files themselves (`mode`, `encoding`, `total`,
`checksum`); a missing or corrupt `metadata.json` still yields a valid
hydration with those fields re-learned once the sender resends header/
checksum chunks.

**Known limitation:** for fountain-encoded transfers, only the
already-_recovered_ source blocks are restored. A `FountainDecoder`'s partial
peeling state (pending symbols, seen seqs) isn't persisted, so a resumed
fountain transfer starts peeling from scratch — already-recovered blocks are
credited immediately, and any redundant re-scanning of previously-seen
symbols is wasted work, not a correctness problem (final SHA-256 verification
still gates completion).

A hydrated transfer appears in `allTransfers` (so it shows up in
`TransfersScreen`) immediately, but does not become the scan screen's
"active" transfer until the user actually scans something in that session.

## Dependencies

| Package          | Purpose                             |
| ---------------- | ----------------------------------- |
| `mobile_scanner` | Native QR detection (Android/iOS)   |
| `provider`       | State management                    |
| `path_provider`  | Access Downloads, Documents folders |
| `archive`        | Gzip decompression                  |
| `crypto`         | SHA-256 hashing                     |
| `convert`        | Base64 encoding/decoding            |

## Performance Considerations

### QR Decoding Bottleneck

- `mobile_scanner` uses native Android APIs (likely ZXing or ML Kit)
- Faster than jsQR but still ~2-10 chunks/sec depending on device
- M1 MacBook / Pixel 7 ~5-10 chunks/sec
- Older devices ~2-3 chunks/sec

### Memory Usage

- Chunks stored as `List<int>` in HashMap, inside the worker isolate only
- For 2 GB transfer: ~2 GB RAM peak in the worker isolate; the main/UI
  isolate's mirror `Transfer` stays lightweight regardless of transfer size
- Consider compression on sender side for large files

### UI Responsiveness

- `Assembler.ingest()` (including any Gaussian-elimination fallback) runs
  entirely inside the worker isolate, off the UI thread
- Per-chunk file I/O and metadata debouncing also happen in the worker
  isolate, asynchronously
- The UI thread only ever receives small `ProgressSnapshot`/event messages

## Error Handling

| Scenario                     | Handling                                       |
| ---------------------------- | ---------------------------------------------- |
| Invalid QR format            | Parse returns null, ignored                    |
| Missing chunk N              | Assembly fails, error message                  |
| SHA-256 mismatch             | Set `error`, display in UI                     |
| Save permission denied       | Fallback to app Documents                      |
| GZip decompression fail      | Error message, no retry                        |
| Out of memory                | App crash (consider chunking)                  |
| Chunk/metadata write failure | Logged via `PersistErrorEvent`, scan continues |

## Future Optimization Ideas

1. **Faster QR library**: Try `qr_scanner_plus` or native ML Kit wrapper
2. **Streaming file write**: Don't buffer entire assembled data in RAM
3. **Relay mode**: POST chunks to `porter serve` while scanning
4. **Multi-transfer**: Queue multiple transfers and handle sequentially
