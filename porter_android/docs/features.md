# Porter Android App — Features

## ✅ Implemented

### Core QR Scanning

- [x] Real-time camera feed with `mobile_scanner`
- [x] Continuous QR detection (no manual trigger)
- [x] Torch/flash toggle for low-light
- [x] Visual feedback on successful scan

### Data Parsing & Assembly

- [x] Parse chunk format: `index|total|mode|id|payload`
- [x] Deduplication: skip duplicate scans
- [x] Support modes: T (text), B (binary), C (compressed)
- [x] Header validation

### File Assembly

- [x] Concatenate chunks in order
- [x] Gzip decompression for mode C
- [x] Base64 decoding for modes B & C
- [x] Text mode (T) UTF-8 handling

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
- [x] Chunk counter (current / total)
- [x] Duplicate counter
- [x] Result screen with data preview
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
- [ ] Transfer history/logging (optional)

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

- **QR Library**: Currently uses `mobile_scanner` which wraps system camera APIs. Performance depends on device CPU.
- **Large Files**: 2 GB transfers will take 2-4 hours at 10 chunks/sec. Consider compression on sender side.
- **Memory**: Stores assembled data in RAM. Very large files (>500 MB) may cause OOM on older devices.

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
