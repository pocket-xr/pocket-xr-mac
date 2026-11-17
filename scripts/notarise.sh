#!/bin/bash
# Sends build/Pocket XR.app (signed with Developer ID by scripts/make-app.sh) to Apple to be notarised, staples the
# ticket to it, and zips it as build/PocketXR-Mac-<version>.zip for download. Run in Terminal on the Mac.
#
# Credentials, either:
#   - an App Store Connect API key: ~/pocket-xr-signing/notary.env with KEY_PATH=<the .p8 file>, KEY_ID=..., ISSUER=...
#     (works over ssh too: no keychain), or
#   - a keychain profile made once with
#       xcrun notarytool store-credentials pocket-xr --apple-id <your Apple ID> --team-id N9A4U4NP67
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Pocket XR.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="build/PocketXR-Mac-$VERSION.zip"

codesign --verify --strict --verbose=2 "$APP"
SIGNED="$(codesign -dvv "$APP" 2>&1)"
case "$SIGNED" in
  *"Authority=Developer ID Application"*) ;;
  *) echo "Not signed with Developer ID: run scripts/make-app.sh first."; exit 1 ;;
esac

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
ENV="$HOME/pocket-xr-signing/notary.env"
if [ -f "$ENV" ]; then
  # shellcheck disable=SC1090
  source "$ENV"
  AUTH=(--key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER")
else
  AUTH=(--keychain-profile pocket-xr)
fi
xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
shasum -a 256 "$ZIP"
echo "Ready: $ZIP"
