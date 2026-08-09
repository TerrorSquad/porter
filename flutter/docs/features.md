# Porter Android App — Features

## ✅ Implemented

### Core QR Scanning

- [x] Real-time camera feed with `mobile_scanner`
- [x] Continuous QR detection (no manual trigger)
- [x] Torch/flash toggle for low-light
- [x] Visual feedback on successful scan

### Data Parsing & Assembly

- [x] Parse chunk format: `index|total|mode|id|payload`
- [x] Parse fountain format: `F|seq|K|fileSize|id|payload` (LT codes)
- [x] Deduplication: skip duplicate scans
- [x] Support modes: T (text), B (binary), C (compressed)
- [x] Header validation

### File Assembly

- [x] Concatenate chunks in order
- [x] Gzip decompression for mode C
- [x] Base64 decoding for modes B & C
- [x] Text mode (T) UTF-8 handling
- [x] Fountain (LT code) decode: peeling + GF(2) fallback, any-subset recovery

### SHA-256 Verification

- [x] Compute SHA-256 of assembled data
- [x] Compare with checksum chunk
- [x] Display verification status

### File Export

- [x] Save to Downloads (Android 11+)
- [x] Fallback to app Documents
- [x] Auto-detect file extension (PNG, JPG, PDF, ZIP, TXT)
- [x] Auto-generated filename with timestamp

### UI/UX

- [x] Scanning screen with progress bar
- [x] Chunk/symbol counter (current / total)
- [x] Duplicate counter
- [x] Transfer list / history screen
- [x] Dark theme with green accents
- [x] Error messages

---

## 🔄 TODO / Future Enhancements

### Camera & Performance

- [ ] Optimize jsQR alternatives (faster QR libraries)
- [ ] Frame throttling to reduce CPU load
- [ ] Configurable camera resolution
- [ ] Portrait + Landscape auto-rotation

### UI Polish

- [ ] Scanning frame overlay animation
- [ ] Haptic feedback on chunk detection
- [ ] Better error recovery screens

### Advanced Features

- [ ] Relay to `porter serve` (POST chunks to server)
- [ ] Multiple concurrent transfers
- [ ] File sharing after save
- [ ] Checksum display/copying
- [ ] Speed statistics

### Build Variants

- [ ] macOS app (same code, different build target)
- [ ] iOS app (requires different QR library)
- [ ] Windows app (same Flutter code)

---

## Known Limitations

- **QR Library**: Currently uses `mobile_scanner` (vendored fork, pinned — see
  `docs/architecture.md`) which wraps system camera APIs. Performance depends
  on device CPU.
- **Large Files**: Scan time scales with chunk count and lighting/device
  speed, not file size directly.
- **Memory**: Recovered block bytes are held in memory ~3x over by assembly
  time (decoder state, transfer state, assembly buffer) — see
  `docs/architecture.md` for the actual bottlenecks found and fixed
  (worker isolate migration, lazy disk hydration, GF(2) elimination cap).

---

## Testing Checklist

- [ ] Single chunk transfer
- [ ] Multi-chunk transfer (10+)
- [ ] Dropped chunk recovery
- [ ] Duplicate deduplication
- [ ] Text mode with special characters
- [ ] Binary mode (images, PDFs)
- [ ] Compressed mode (gzip)
- [ ] SHA-256 verification
- [ ] File save to Downloads
- [ ] Error handling (corrupt data, save failures)
- [ ] Orientation changes mid-scan
- [ ] Low-light scanning
- [ ] Camera permission denial
