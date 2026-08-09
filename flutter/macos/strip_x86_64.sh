#!/bin/sh
# Strips the x86_64 slice from the bundle's frameworks after a Release build.
#
# `ARCHS = arm64` (see Runner/Configs/AppInfo.xcconfig) only governs targets
# Xcode compiles. Flutter ships FlutterMacOS.framework and friends as
# prebuilt universal binaries and copies them in verbatim, so the bundle stays
# fat regardless — 43 MB installed, of which ~21 MB is x86_64 code that never
# runs on an Apple Silicon Mac. `flutter build macos` has no architecture flag
# to prevent this, so strip after the fact.
#
# Skipped unless ARCHS is exactly "arm64", so a deliberate universal build
# (drop the ARCHS line) still produces a working universal bundle.
set -eu

if [ "${ARCHS:-}" != "arm64" ]; then
  echo "strip_x86_64: ARCHS='${ARCHS:-}' is not arm64-only; leaving binaries alone."
  exit 0
fi

APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
[ -d "$APP" ] || { echo "strip_x86_64: no bundle at $APP"; exit 0; }

# Not `-perm +111`: App.framework's binary ships without the execute bit but
# is still a fat Mach-O that needs thinning.
find "$APP" -type f 2>/dev/null | while read -r bin; do
  # `file` is cheaper than lipo here and avoids erroring on scripts/resources.
  case "$(file -b "$bin" 2>/dev/null)" in
    *"universal binary"*)
      lipo "$bin" -remove x86_64 -output "$bin" 2>/dev/null \
        && echo "strip_x86_64: thinned $(basename "$bin")"
      # Removing a slice invalidates the signature; re-sign ad-hoc so the
      # bundle still launches. A real Developer ID re-sign should happen
      # after this phase, not before.
      codesign --force --sign - --preserve-metadata=entitlements "$bin" 2>/dev/null || true
      ;;
  esac
done
