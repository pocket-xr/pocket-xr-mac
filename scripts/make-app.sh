#!/bin/bash
# Builds Pocket XR.app in build/. Signs it with a Developer ID Application certificate when the keychain has one (for
# downloads; then scripts/notarise.sh), else the "Pocket XR Dev" certificate (scripts/make-cert.sh, this Mac only), so
# Screen Recording permission survives rebuilds; otherwise ad hoc, which macOS asks about again after each build.
#
#   scripts/make-app.sh            this Mac's architecture, release
#   scripts/make-app.sh universal  Apple Silicon and Intel in one app (needs Xcode, not only the command line tools)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "direct" ]; then
  # Without SwiftPM (scripts/build-direct.sh), for a Mac whose command line tools cannot read Package.swift.
  bash scripts/build-direct.sh
  BIN=".build/direct/PocketXR"
elif [ "${1:-}" = "universal" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/PocketXR"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/PocketXR"
fi

APP="build/Pocket XR.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PocketXR"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

IDS="$(security find-identity -v -p codesigning)"
DEVID="$(printf '%s\n' "$IDS" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
if [ -n "$DEVID" ]; then
  # For downloads: Apple's Developer ID, with a secure timestamp, which notarisation needs (scripts/notarise.sh).
  # The hardened runtime refuses the camera (hand tracking) without the entitlement.
  codesign --force --deep --timestamp --options runtime --entitlements Resources/PocketXR.entitlements --sign "$DEVID" "$APP"
  echo "Signed with $DEVID."
elif printf '%s\n' "$IDS" | grep -q "Pocket XR Dev"; then
  codesign --force --deep --options runtime --entitlements Resources/PocketXR.entitlements --sign "Pocket XR Dev" "$APP"
  echo "Signed with Pocket XR Dev (this Mac only)."
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad hoc (run scripts/make-cert.sh once so Screen Recording permission survives rebuilds)."
fi
echo "Built $APP"
