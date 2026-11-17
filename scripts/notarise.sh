#!/bin/bash
# Sends build/Pocket XR.app (signed with Developer ID by scripts/make-app.sh) to Apple to be notarised, staples the
# ticket to it, and zips it as build/PocketXR-Mac-<version>.zip for download. Run in Terminal on the Mac.
#
# Once, first: make an app-specific password at account.apple.com (Sign-In and Security), then
#   xcrun notarytool store-credentials pocket-xr --apple-id <your Apple ID> --team-id N9A4U4NP67
# which asks for that password and keeps it in the keychain as "pocket-xr".
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Pocket XR.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="build/PocketXR-Mac-$VERSION.zip"

codesign --verify --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "Not signed with Developer ID: run scripts/make-app.sh first."; exit 1; }

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile pocket-xr --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
shasum -a 256 "$ZIP"
echo "Ready: $ZIP"
