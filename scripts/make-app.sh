#!/bin/bash
# Builds Pocket XR.app in build/. Signs it with the "Pocket XR Dev" certificate when there is one (scripts/make-cert.sh),
# so Screen Recording permission survives rebuilds; otherwise ad hoc, which macOS asks about again after each build.
#
#   scripts/make-app.sh            this Mac's architecture, release
#   scripts/make-app.sh universal  Apple Silicon and Intel in one app (needs Xcode, not only the command line tools)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "universal" ]; then
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

if security find-identity -v -p codesigning | grep -q "Pocket XR Dev"; then
  codesign --force --deep --options runtime --sign "Pocket XR Dev" "$APP"
  echo "Signed with Pocket XR Dev."
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad hoc (run scripts/make-cert.sh once so Screen Recording permission survives rebuilds)."
fi
echo "Built $APP"
