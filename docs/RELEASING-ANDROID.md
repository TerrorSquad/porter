# Releasing the Android receiver

Porter's receiver ships as a **self-signed APK on GitHub Releases**. There is
no Play Store listing and no Apple-style notarization step — the only thing
required is a keystore you generate yourself and keep.

Anyone can build the app without any of this: `flutter build apk --release`
falls back to the debug keystore when `android/key.properties` is absent. That
fallback is fine for building for yourself and **not** fine for publishing —
see [Why not the debug key](#why-not-the-debug-key).

## Prerequisite: JDK 17

Gradle 8.12 cannot parse a Java 25 version string and fails with a bare
`IllegalArgumentException: 25.0.2`, which Flutter surfaces as a build error
reading only `25.0.2`. If Flutter picks up Android Studio's bundled JDK 25,
point it at a 17 instead:

```sh
flutter config --jdk-dir="$(/usr/libexec/java_home -v 17)"
```

This is per-machine config, not a repo setting. `flutter doctor -v` shows
which JDK is in use.

## One-time: create the keystore

```sh
keytool -genkey -v \
  -keystore ~/porter-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias porter
```

Then create `flutter/android/key.properties` (gitignored, never commit it):

```properties
storePassword=<the store password>
keyPassword=<the key password>
keyAlias=porter
storeFile=/absolute/path/to/porter-upload.jks
```

<!-- ponytail: file-based key config, the standard Flutter pattern. Move to
     env vars only if this ever builds on CI. -->

> **Back up `porter-upload.jks` and its passwords.** Losing the keystore means
> no existing install can ever be upgraded — every user has to uninstall and
> reinstall, losing app data. There is no recovery path.

## Build

```sh
mise run flutter-apk       # universal APK  → build/app/outputs/flutter-apk/
mise run flutter-apk-split # per-ABI APKs, ~1/3 the size each
```

Split APKs are what you attach to a release: a universal APK carries arm64,
armeabi and x86_64 native code, and virtually every real phone is
`arm64-v8a`. Attach the universal one too, as the no-guesswork fallback.

Verify what you built:

```sh
# Confirm it is NOT the debug key. Should print your CN, not "Android Debug".
keytool -printcert -jarfile build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

## Publish

Attach the APKs to the GitHub Release. In the release notes, tell people what
Android will show them:

> Android will warn that this APK is from an unknown developer, because it is
> signed with our own key rather than distributed through the Play Store. You
> will need to allow installation from your browser or file manager. The
> SHA-256 fingerprint of the signing key is `<paste from keytool>` — it will
> not change between releases.

Publishing the fingerprint is what makes self-signing trustworthy: it lets
anyone confirm a later APK came from the same key.

## Why not the debug key

Flutter's template signs release builds with the debug keystore. That build
runs, which is why it is a usable fallback, but it must never be published:

- The debug keystore is generated per machine, so builds from two machines are
  mutually un-upgradable.
- It expires after 365 days.
- Android refuses to install an update signed with a different key than the
  installed version.

An APK published with a debug key strands every person who installs it.

## Why no Play Store

Play requires a Google Play Developer account ($25), and since August 2023 new
personal developer accounts must complete a 14-day closed test with 12 testers
before production access. For a tool aimed at people transferring files across
an air gap, a directly downloadable APK is the better distribution channel
anyway. F-Droid is a reasonable future option — it needs a reproducible build
and a metadata submission, and it is not a blocker for launch.
