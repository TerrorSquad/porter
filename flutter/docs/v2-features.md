# Porter Receiver v2 — Feature Specs

This document specifies the features being added to make the Flutter app the single
Porter receiver client (replacing the web receiver in `web/`). Each section below is
implemented and committed independently, in the order listed.

## 1. Settings infrastructure + Settings screen

**Goal:** A persisted settings model backing the output-directory, resolution, and relay
features below, plus a dedicated screen to edit them.

**New files:**

- `lib/models/camera_resolution.dart` — `enum CameraResolutionPreset { p480, p720, p1080,
p4k, square720, square1080 }` with:
  - `size` → `Size`: `640x480`, `1280x720` (default), `1920x1080`, `3840x2160`, `720x720`,
    `1080x1080`
  - `label` → `String`: `'480p (640×480)'`, `'720p (1280×720)'`, `'1080p (1920×1080)'`,
    `'4K (3840×2160)'`, `'Square (720×720)'`, `'Square (1080×1080)'` — matching
    `web/index.html`'s `#resolution-select` options.
- `lib/providers/settings_provider.dart` — `SettingsProvider extends ChangeNotifier`:
  - `String? outputDirectory` — `null` means default (`~/Downloads` via
    `path_provider.getDownloadsDirectory()`).
  - `CameraResolutionPreset cameraResolution` — default `p720`.
  - `String relayUrl` — default `''` (empty = relay disabled).
  - `String? selectedCameraId` — moved here from `scanning_screen.dart`.
  - Constructor calls `_load()` (async), which reads `SharedPreferences` and
    `notifyListeners()` once loaded.
  - Setters (`setOutputDirectory`, `setCameraResolution`, `setRelayUrl`,
    `setSelectedCameraId`) persist immediately and `notifyListeners()`.
- `lib/screens/settings_screen.dart` — `StatefulWidget` with:
  - **Output directory** row: shows current path (or "Default (~/Downloads)"), "Change"
    button → `FilePicker.platform.getDirectoryPath()`, "Reset to default" button.
  - **Camera resolution** row: `DropdownButton<CameraResolutionPreset>` over all enum
    values, showing `.label`.
  - **Relay URL** row: `TextField` (URL keyboard type) + explanatory text
    ("Leave empty to disable. Point at a `porter serve` instance, e.g.
    `http://192.168.1.10:8080`").
  - **Camera** row (macOS only, when >1 camera): `DropdownButton<String>` — moved from
    `scanning_screen.dart`, same enumeration via `controller.getAvailableCameras()`.

**Persistence keys (SharedPreferences):**
| Key | Type | Default |
|-----|------|---------|
| `porter.outputDirectory` | String | absent → `null` (use `~/Downloads`) |
| `porter.cameraResolution` | String (enum name) | absent → `p720` |
| `porter.relayUrl` | String | absent → `''` |
| `porter.selectedCameraId` | String | absent → `null` (first camera) |

**Wiring:**

- `lib/main.dart`: add `ChangeNotifierProvider(create: (_) => SettingsProvider())` to the
  existing `MultiProvider`.
- `scanning_screen.dart`: add a settings `IconButton` (gear icon) to the `AppBar` that
  pushes `SettingsScreen`. Remove the inline macOS camera dropdown and its
  `_initCamera`/`_onCameraSelected` persistence (superseded by `SettingsProvider` +
  `SettingsScreen`).

---

## 2. Output-directory picker

**Goal:** Let the user choose where received files are saved, defaulting to `~/Downloads`.

**Changes:**

- `lib/services/file_handler.dart`: `saveFile(Transfer transfer, {String? outputDirectory})`.
  - If `outputDirectory` is non-null and non-empty: ensure the directory exists
    (`Directory(outputDirectory).create(recursive: true)`) and write the file there.
  - Else: existing behavior — `getDownloadsDirectory()` (≈ `~/Downloads` on macOS), falling
    back to `getApplicationDocumentsDirectory()`.
- Save actions (transfer card, §5) call
  `FileHandler.saveFile(transfer, outputDirectory: context.read<SettingsProvider>().outputDirectory)`.
- On success, show a `SnackBar` with the full saved path — this is the first piece of
  "metadata about the download".

---

## 3. Camera resolution picker, including square presets

**Goal:** Apply the resolution chosen in Settings (§1) to the live camera, including
square 720×720 / 1080×1080 presets for square-cropped QR sources.

**Dart side (`scanning_screen.dart`):**

- Listen to `SettingsProvider.cameraResolution`. When it changes:
  1. `await controller.stop(); controller.dispose();`
  2. Construct a new `MobileScannerController(autoStart: false, cameraResolution:
preset.size, ...)`, reusing the persisted `cameraId` (macOS).
  3. `await controller.start()`.
  4. Rebuild the `MobileScanner` widget with a new `ValueKey` (same pattern used for the
     existing macOS camera-switch flow).

**Android:** works without further changes — `cameraResolution` is already serialized by
`StartOptions.toMap()` as `'cameraResolution': [width, height]` and consumed by the
upstream Android implementation.

**macOS (fork — `third_party/mobile_scanner/darwin/mobile_scanner/Sources/mobile_scanner/MobileScannerPlugin.swift`):**

Today `start()` always sets `captureSession!.sessionPreset = AVCaptureSession.Preset.high`
and ignores any requested resolution. Extend it:

1. Add `intArray(key:)` to `MapArgumentReader` (next to `stringArray`):
   ```swift
   func intArray(key: String) -> [Int]? {
       return (args?[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
   }
   ```
2. In `start()`, after `device` is selected, read `cameraResolution` (`[width, height]`).
   If present:
   - `captureSession!.sessionPreset = .inputPriority`
   - Iterate `device.formats`, compute each format's dimensions via
     `CMVideoFormatDescriptionGetDimensions(format.formatDescription)`, and pick the
     smallest format whose `width >= requested.width && height >= requested.height`
     (falling back to the largest available format if none qualify).
   - `device.lockForConfiguration(); device.activeFormat = bestFormat;
device.unlockForConfiguration()`.
   - If no `cameraResolution` is present, keep today's `captureSession!.sessionPreset =
.high`.

---

## 4. Live scan-rate statistics

**Goal:** Show how many QR codes are being processed per second, live.

**Changes:**

- `lib/providers/scanner_provider.dart`:
  - Track `final List<DateTime> _recentScans = []` — append `DateTime.now()` on every
    `ingestQR` call (new chunks _and_ duplicates both count as "processed").
  - Trim entries older than 3 seconds on each append.
  - `double get scansPerSecond => _recentScans.length / 3.0` (entries already trimmed to
    the 3s window).
- `scanning_screen.dart`:
  - `Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {}))` started in
    `initState`, cancelled in `dispose`, so the displayed rate decays toward 0 between
    scans (not just on new scans).
  - HUD bar text: `'scanned $totalScanned · new ... · dupes ... · ${rate.toStringAsFixed(1)}/s'`.

---

## 5. Multi-transfer metadata UI (transfer cards)

**Goal:** Replace the single-active-transfer `ResultScreen` with a list of all transfers
(matching the web app's transfer-card list), each showing mode/status/checksum badges,
progress, size, preview, and save/remove actions.

**New files:**

- `lib/utils/format.dart` — `String formatBytes(int bytes)` (B/KB/MB/GB, 1 decimal place).
- `lib/widgets/transfer_card.dart` — `TransferCard extends StatelessWidget` taking a
  `Transfer`:
  - **Header row:** short id (`transfer.id.substring(0, 8)`), mode badge
    (`T`→"Text", `B`→"Binary", `C`→"Compressed"), status badge (`Scanning…` /
    `Complete` / `Error`), checksum badge (`✓ Verified` / `✗ Failed` / `— Unverified`,
    based on `transfer.verified`).
  - **Progress bar:** `LinearProgressIndicator(value: transfer.progress / 100)` +
    `'${transfer.seenIndices.length} / ${transfer.total} chunks'`.
  - **Size:** `formatBytes(transfer.assembled?.length ?? 0)` once available.
  - **Preview:** if `transfer.mode == 'T'` and assembled, show a text snippet
    (`String.fromCharCodes(...).substring(0, ...)`, truncated); if assembled bytes are
    PNG/JPG (via `FileHandler.guessExtension`), show an `Image.memory` thumbnail.
  - **Actions:** "Save" (enabled when `transfer.isComplete`, calls
    `FileHandler.saveFile` per §2 and shows the SnackBar path), "Remove" (calls
    `provider.reset(transfer.id)`).
  - **Error:** if `transfer.error != null`, show it in the card body.
  - **Relay row:** placeholder `SizedBox.shrink()` until §6 fills it in.
- `lib/screens/transfers_screen.dart` — `ListView.builder` over
  `provider.allTransfers.values.toList()..sort((a, b) =>
b.createdAt.compareTo(a.createdAt))`, each rendered as a `TransferCard`; empty state:
  "No transfers yet — scan a QR code to begin."

**Changed files:**

- `lib/services/file_handler.dart` — promote `_guessExtension` to public
  `static String guessExtension(Transfer transfer)` (used by both filename generation and
  the card's image-preview check).
- `scanning_screen.dart` — add an `AppBar` action: an icon button with a badge showing
  `provider.allTransfers.length`, pushing `TransfersScreen`. Remove the
  `if (transfer != null && transfer.isComplete...) return ResultScreen(...)` branch.
- Delete `lib/screens/result_screen.dart` (superseded by `TransferCard`).

---

## 6. HTTP relay to `porter serve`

**Goal:** POST each scanned QR payload to a configured `porter serve` instance (e.g.
`porter serve --port=8080 --output-dir=$HOME/Projects/received`), mirroring
`web/src/main.ts`'s relay logic and `nodejs/src/lib/receiver.ts`'s `/upload` contract.

**New files:**

- `lib/models/relay_state.dart` — `RelayState { int sent; int failed; bool complete; bool?
verified; String? joinedPath; String? lastError; }` (mirrors the web app's
  `RelayState`).
- `lib/services/relay_service.dart`:
  - `RelayResult` — mirrors `UploadResult` from `nodejs/src/lib/receiver.ts`: `fileName,
path, size, duplicate, sha256, transferId, manifestPath, complete, verified,
joinedPath`, plus `error` (String?, set on network/parse failure).
  - `Future<RelayResult> upload(String relayUrl, String content)`:
    - `POST '${relayUrl.replaceAll(RegExp(r"/$"), "")}/upload'`
    - body: `jsonEncode({'content': content, 'format': 'QR_CODE'})`,
      `headers: {'Content-Type': 'application/json'}`
    - parse JSON response into `RelayResult`; catch exceptions into
      `RelayResult(error: ...)`.

**Changed files:**

- `pubspec.yaml`: add `http: ^1.2.0`.
- `lib/providers/scanner_provider.dart`:
  - `Map<String, RelayState> relayStates = {}`, `bool? relayLastOk`.
  - `ingestQR(String raw, {String? relayUrl})`: after local ingest, if `relayUrl != null &&
relayUrl.isNotEmpty`, call `RelayService.upload(relayUrl, raw)` (fire-and-forget —
    don't await before returning), then on completion: - update `relayLastOk = result.error == null` - if `result.transferId != null`, update/create `relayStates[result.transferId]`:
    increment `sent` (or `failed` on error), set `complete`/`verified`/`joinedPath`/
    `lastError` from the result - `notifyListeners()`
- `scanning_screen.dart`:
  - Pass `context.read<SettingsProvider>().relayUrl` into `ingestQR`.
  - HUD shows a relay status dot: hidden if `relayUrl.isEmpty`, else green (●) if
    `relayLastOk == true`, red (●) if `relayLastOk == false`.
- `lib/widgets/transfer_card.dart`:
  - Fill in the relay row using `provider.relayStates[transfer.id]`, matching the web
    app's states:
    - no `relayUrl` configured → nothing
    - no state yet → `○ Relay: waiting for first chunk…`
    - `lastError != null` → `✕ Relay: error — <lastError>`
    - `joinedPath != null` → `✓ Relay: joined → <joinedPath>`
    - `complete == true` → `✓ Relay: complete`
    - else → `⇡ Relay: <sent> chunk(s) saved`

---

## Verification checklist

- `flutter analyze` clean after every step.
- §3: `flutter run -d macos`, switch resolution presets (incl. a square one) in Settings,
  confirm the preview restarts without error.
- §6: run `porter serve --port=8080 --output-dir=$HOME/Projects/received` (from `nodejs/`),
  set that URL in Settings, scan a multi-chunk transfer, confirm the relay row reaches
  "joined"/"complete" and the file appears under `~/Projects/received`.
- §5: scan two independent transfers without resetting; confirm both show as separate
  cards with correct badges/progress, and Save writes to the directory configured in §2.
