#!/bin/bash
# Builds Pocket XR's core with the checks in Checks/ into one program and runs it. For a Mac with only the Command
# Line Tools, where `swift test` cannot run (no XCTest). Exit code 0 means every check passed.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=.build/checks
mkdir -p "$OUT"
SDK=$(xcrun --show-sdk-path)
TARGET="$(uname -m)-apple-macosx14.0"

# The same mask for a stale module map as scripts/build-direct.sh.
VFS=()
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [ -f "$STALE" ] && [ -f "${STALE%module.modulemap}bridging.modulemap" ]; then
    : > "$OUT/empty.modulemap"
    cat > "$OUT/vfs.yaml" <<EOF
{ "version": 0, "roots": [ { "name": "$STALE", "type": "file", "external-contents": "$PWD/$OUT/empty.modulemap" } ] }
EOF
    VFS=(-vfsoverlay "$OUT/vfs.yaml")
fi

swiftc ${VFS[@]+"${VFS[@]}"} -swift-version 5 -target "$TARGET" -sdk "$SDK" -module-name CoreChecks -wmo -Onone \
    Sources/PocketXRCore/*.swift Checks/*.swift -o "$OUT/core-checks"
"$OUT/core-checks"
