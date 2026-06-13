# Porter Android App — Architecture

## Project Structure

```
flutter/
├── lib/
│   ├── main.dart                 # App entry point, theme setup
│   ├── models/
│   │   ├── chunk.dart           # DataChunk, ChecksumChunk parsing
│   │   └── transfer.dart        # Transfer state (id, chunks, progress)
│   ├── services/
│   │   ├── chunk_parser.dart    # QR → chunk/checksum parsing
│   │   ├── assembler.dart       # Core assembly logic, SHA-256, gzip
│   │   └── file_handler.dart    # Save to Downloads/Documents
│   ├── providers/
│   │   └── scanner_provider.dart # State management (Provider)
│   └── screens/
│       ├── scanning_screen.dart  # Main camera + QR detection UI
│       └── result_screen.dart    # Preview + save UI
├── android/
│   └── AndroidManifest.xml       # Permissions, app config
├── pubspec.yaml                  # Dependencies
└── docs/
    ├── features.md
    ├── architecture.md (this file)
    └── setup.md
```

## Data Flow

```
Camera Frame
    ↓
mobile_scanner (native QR detection)
    ↓
ChunkParser.parseQR()
    ↓
Assembler.ingest()
    ├─ DuplicateCheck (seenIndices)
    ├─ Decode payload (UTF-8, Base64)
    └─ tryComplete() when all chunks arrived
         ├─ Concatenate chunks
         ├─ Decompress if mode='C'
         ├─ SHA-256 verification
         └─ onComplete callback
    ↓
ScannerProvider (notifyListeners)
    ↓
ScanningScreen / ResultScreen (rebuild)
    ↓
FileHandler.saveFile() (user action)
    ↓
Downloads folder
```

## Core Classes

### Transfer

- Holds metadata: `id`, `total`, `mode`
- Stores chunks in `Map<int, List<int>>`
- Tracks deduplication via `seenIndices`
- Status flags: `assembled`, `verified`, `error`

### Assembler

- Maintains `Map<String, Transfer>` for active transfers
- `ingest(raw)`: processes QR strings, returns bool if new data
- `_tryComplete()`: concatenates chunks, decompresses, verifies
- Callbacks: `onProgress`, `onComplete`

### ScannerProvider (Provider pattern)

- Wraps Assembler state
- Tracks stats: `totalScanned`, `duplicatesSkipped`
- Notifies UI on updates
- Methods: `ingestQR()`, `reset()`, `resetAll()`

### ChunkParser

- Static `parseQR()`: returns DataChunk | ChecksumChunk | null
- Handles both formats:
  - Data: `index|total|mode|id|payload`
  - Checksum: `CHECKSUM|T|id|sha256`

### FileHandler

- `saveFile(Transfer)`: writes bytes to Downloads
- `_guessExtension()`: magic byte detection (PNG, JPG, PDF, ZIP)
- Fallback to app Documents if Downloads unavailable

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

- Chunks stored as `List<int>` in HashMap
- For 2 GB transfer: ~2 GB RAM peak
- Consider compression on sender side for large files

### UI Responsiveness

- Assembler runs synchronously (< 1ms per chunk typically)
- File I/O is async (saveFile uses Future)
- GZip decompression can block briefly on large files

## Error Handling

| Scenario                | Handling                      |
| ----------------------- | ----------------------------- |
| Invalid QR format       | Parse returns null, ignored   |
| Missing chunk N         | Assembly fails, error message |
| SHA-256 mismatch        | Set `error`, display in UI    |
| Save permission denied  | Fallback to app Documents     |
| GZip decompression fail | Error message, no retry       |
| Out of memory           | App crash (consider chunking) |

## Future Optimization Ideas

1. **Faster QR library**: Try `qr_scanner_plus` or native ML Kit wrapper
2. **Async assembly**: Offload concatenation to isolate for large files
3. **Streaming file write**: Don't buffer entire assembled data in RAM
4. **Relay mode**: POST chunks to `porter serve` while scanning
5. **Multi-transfer**: Queue multiple transfers and handle sequentially
