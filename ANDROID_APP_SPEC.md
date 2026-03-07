# Porter Android App — Feature Specification

## 📋 Overview

A standalone Android app that scans continuous QR code streams from a terminal and reassembles the original file offline. Part of the air-gapped file transfer system.

---

## 🎯 Core Features

### 1. **Camera & QR Detection**
- **Real-time camera feed** from rear-facing camera
- **Continuous QR scanning** (not one-shot) using `jsQR` equivalent
- **Auto-detection** — no button press required, scans as QR codes appear
- **Visual feedback** — green frame when QR detected
- **Debouncing** — ignore duplicate scans within 300ms

### 2. **Data Parsing & Assembly**
- **Parse header format**: `index|total|mode|payload`
  - `index`: Chunk number (0-based)
  - `total`: Total chunks
  - `mode`: `T` (Text), `B` (Binary/Base64), `C` (Compressed)
  - `payload`: Actual data (may contain `|` characters)

- **Chunk storage** — Store received chunks in a map by index
- **Progress tracking** — Display `current / total` chunks
- **Validation** — Detect mismatches in total chunk count

### 3. **Data Assembly & Decompression**
- **Concatenate chunks** in index order
- **Text mode (T)** — Concatenate UTF-8 strings directly
- **Binary mode (B)** — Concatenate base64 strings, then decode to bytes
- **Compressed mode (C)** — Concatenate base64 → decode → decompress (gzip)
- **Error handling** — Gracefully handle malformed data or decompression failures

### 4. **File Export**
- **Save to Downloads folder** (Android 11+ compatible)
- **Auto-generate filename** — `porter-{timestamp}.{ext}` (detect extension from data)
- **Fallback options**:
  - Internal app storage (Documents folder)
  - Share dialog for user folder selection
  - Copy to clipboard (for text-only data)

### 5. **UI/UX Requirements**

#### Scanning Screen
- Full-screen camera preview
- Scanning frame overlay (250x250px green border)
- **Progress bar** with percentage (0-100%)
- **Chunk counter** showing `current / total`
- **Reset button** to clear and start over
- Dark theme with high-contrast green accents
- Landscape + portrait support

#### Result Screen (After 100% completion)
- **Data preview** — Scrollable text area showing received content (monospace font)
- **Save File button** — Primary action (green)
- **Scan Again button** — Secondary action (reset, red)
- **File size display** — KB/MB
- Status message ("✓ Saved to Downloads", etc.)

#### Permissions Screen
- Request camera permission on first launch
- Request file storage permission before saving
- Clear explanatory text

### 6. **Performance Characteristics**
- **Target speed**: Handle 2-3 chunks/sec (0.5s per chunk)
- **Frame rate**: 30 FPS camera preview
- **Memory**: Track max 100 chunks without lag
- **CPU**: Efficient QR detection (local processing, no network)

---

## 🛠️ Technical Stack (Flutter)

### Core Packages
- **`camera`** — Real-time camera access
- **`mobile_scanner`** or **`qr_scanner_plus`** — QR detection
- **`archive`** — Gzip decompression
- **`path_provider`** — File system access (Downloads, Documents)
- **`share_plus`** — Share dialog
- **`flutter_test`** + **`integration_test`** — Testing

### State Management
- **`provider`** or **`riverpod`** — Manage scanner state, chunks, progress

### UI Framework
- **Material 3** (dark theme by default)
- **Custom widgets** for frame overlay, progress bar

---

## 📱 User Flow

```
1. USER LAUNCHES APP
   ↓
2. REQUEST PERMISSIONS (Camera, Storage)
   ↓
3. SCANNING SCREEN OPENS
   - Camera feed shows live
   - Frame overlay centered
   - Progress bar at bottom: 0/0
   ↓
4. SENDER DISPLAYS QR CODES
   - First QR detected → chunks set to 1/10
   - Subsequent QRs → progress updates (2/10, 3/10, ...)
   - Already-scanned chunks ignored (debounced)
   ↓
5. 100% COMPLETE
   - Progress bar fills to 100%
   - Auto-transition to Result Screen
   - Data displayed in text area
   ↓
6. SAVE OR SHARE
   - User taps "💾 Save File"
   - File written to Downloads
   - Toast: "Saved to Downloads/porter-1234567890.txt"
   - Option to share from system dialog
   ↓
7. SCAN AGAIN (Optional)
   - User taps "Scan Again"
   - Reset to step 3
```

---

## 🔒 Security & Privacy

- **Offline only** — No internet, no cloud, no telemetry
- **Local processing** — All decompression in-app
- **No logging** — No history file
- **File cleanup** — Users can delete saved files manually
- **Camera access** — Only when app is active

---

## 📊 Data Handling Examples

### Text Mode (T)
```
QR1: 0|3|T|Hello 
QR2: 1|3|T| World
QR3: 2|3|T|!

Result: "Hello World!"
```

### Binary Mode (B)
```
QR1: 0|2|B|aGVsbG8gd29ybGQ=  (base64 for "hello world")
QR2: 1|2|B|

Result: Binary data (file saved as .bin or detected type)
```

### Compressed Mode (C)
```
QR1: 0|1|C|H4sIAA...  (gzip compressed base64)
QR2: (none if large file split)

Result: Decompressed → saved file
```

---

## 🧪 Test Cases

1. **Single chunk** — File small enough for 1 QR
2. **Multiple chunks** — 10+ chunks, sequential
3. **Dropped chunks** — Missing chunk 5/10, still completes when retransmitted
4. **Duplicates** — Same QR scanned twice, only counted once
5. **Text overflow** — Payload with `|` characters
6. **Decompression failure** — Corrupt gzip data → error message
7. **File save failure** — Storage permission denied → Fall back to share
8. **Large files** — 1MB+ (if compressed)
9. **Special characters** — UTF-8 emoji, accents, CJK characters
10. **Orientation change** — Rotate phone mid-scan, state preserved

---

## 🎨 UI Mockup Hints

### Scanning Screen
```
┌─────────────────────────────┐
│     [Camera Feed]           │
│                             │
│       ┌─────────────┐       │
│       │   Scanning  │       │
│       │    Frame    │       │
│       └─────────────┘       │
│                             │
│  Progress: 3 / 10           │
│  ████████░░░░░░░░░░░░░░░░░░ │
│  [Reset]                    │
└─────────────────────────────┘
```

### Result Screen
```
┌─────────────────────────────┐
│      📦 Received Data       │
├─────────────────────────────┤
│ ┌─────────────────────────┐ │
│ │ Hello World!            │ │
│ │ Size: 12 bytes          │ │
│ │ Mode: Text              │ │
│ └─────────────────────────┘ │
├─────────────────────────────┤
│  [💾 Save File] [Scan Again] │
└─────────────────────────────┘
```

---

## 🚀 Success Criteria

✅ Scan and assemble 100-chunk file in < 2 minutes (at 0.5s/chunk)  
✅ Correctly decompress gzip payloads  
✅ Save file to Downloads with auto-detected name  
✅ Handle all 3 modes (T, B, C) seamlessly  
✅ Survive orientation change and brief permission delays  
✅ Clear error messages for user (corrupt data, save failed, etc.)  
✅ Works on Android 12+  

---

## 📦 Related Components

- **Sender CLI** (`/php/utils`): `pnpm porter <file> --slideshow`
- **QR Format**: Defined in `src/lib/chunker.ts` (header protocol: `index|total|mode|payload`)
