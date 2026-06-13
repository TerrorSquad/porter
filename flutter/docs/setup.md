# Porter Android App — Setup & Build

## Prerequisites

- Flutter SDK 3.0+
- Android SDK (API 21+) for Android builds
- Xcode 13+ (optional, for macOS builds)
- Git

## Installation

### 1. Install Flutter

```bash
# Download from https://flutter.dev/docs/get-started/install
# Add to PATH
export PATH="$PATH:$HOME/flutter/bin"

# Verify
flutter doctor
```

### 2. Clone & Setup

```bash
cd /home/gninkovic/Projects/sturdy-eureka/flutter

# Get dependencies
flutter pub get

# Check setup
flutter doctor -v
```

### 3. Configure Android (for physical device or emulator)

```bash
# Connect Android device via USB (enable USB debugging)
# OR start Android emulator:
flutter emulators --launch <emulator_name>

# List devices
flutter devices
```

## Building

### Android APK (unsigned)

```bash
flutter build apk --release
# Output: build/app/outputs/flutter-app/release/app-release.apk
```

### Android App Bundle (for Google Play)

```bash
flutter build appbundle --release
# Output: build/app/outputs/bundle/release/app-release.aab
```

### macOS App (same codebase)

```bash
flutter build macos --release
# Output: build/macos/Build/Release/porter_receiver.app
```

## Running During Development

```bash
# Connect device or start emulator
flutter run

# With hot reload enabled (default)
# Press 'r' to hot reload, 'R' to hot restart
```

## Debugging

### View logs

```bash
flutter logs
```

### Debug mode (with full debugging info)

```bash
flutter run -v
```

### Android Studio integration

```bash
flutter create . --platforms=android
# Then open in Android Studio: File > Open > select project
```

## Known Issues & Workarounds

### Issue: `mobile_scanner` permission errors

**Workaround**: Ensure `android/AndroidManifest.xml` includes:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

### Issue: `path_provider` fails to get Downloads folder

**Workaround**: App falls back to app Documents folder. User can manually move files via file manager.

### Issue: Gzip decompression hangs on large files

**Workaround**: Consider streaming decompression or running on isolate (future optimization).

## Testing

### Unit tests (chunk parsing, assembly)

```bash
flutter test test/assembler_test.dart
```

### Integration tests (camera, file I/O)

```bash
flutter test integration_test/
```

### Manual QR testing

Generate test QR codes with Node.js sender:

```bash
cd ../nodejs
./dist/porter.mjs testfile.txt --slideshow
# Scan with Flutter app on device
```

## Environment Variables (optional)

Create `.env` file if needed for build variants:

```
FLUTTER_RELEASE_MODE=true
TARGET_API_LEVEL=31
```

## Deployment Checklist

- [ ] Test on real Android device (Pixel 7 or similar)
- [ ] Test on macOS
- [ ] Verify SHA-256 checksums
- [ ] Test file save to Downloads
- [ ] Test error cases (corrupt QR, missing chunks)
- [ ] Sign APK with keystore
- [ ] Update app version in `pubspec.yaml`
- [ ] Generate release notes
- [ ] Upload to Google Play or distribute APK directly

## Useful Commands

```bash
# Clean build
flutter clean

# Get latest dependencies
flutter pub upgrade

# Analyze code
flutter analyze

# Format code
flutter format lib/

# Generate build files
flutter pub get

# Run specific test file
flutter test test/models/transfer_test.dart
```
