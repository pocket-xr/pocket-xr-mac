#!/bin/bash
# Builds Pocket XR without SwiftPM, for a Mac whose Command Line Tools cannot read Package.swift
# ("Invalid manifest ... Undefined symbols ... PackageDescription", seen with Swift 6.0.3 tools on macOS 14.8).
# The same three modules as Package.swift: CVirtualDisplay (Objective-C), PocketXRCore, PocketXR.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=.build/direct
mkdir -p "$OUT"
SDK=$(xcrun --show-sdk-path)
TARGET="$(uname -m)-apple-macosx14.0"

# Command Line Tools installed over an older set keep a 2023 usr/include/swift/module.modulemap beside the new
# bridging.modulemap, and every Swift compile then stops at "redefinition of module 'SwiftBridging'". The old file is
# shown to the compiler as an empty one here, so nothing under /Library has to change.
VFS=()
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [ -f "$STALE" ] && [ -f "${STALE%module.modulemap}bridging.modulemap" ]; then
    : > "$OUT/empty.modulemap"
    cat > "$OUT/vfs.yaml" <<EOF
{ "version": 0, "roots": [ { "name": "$STALE", "type": "file", "external-contents": "$PWD/$OUT/empty.modulemap" } ] }
EOF
    VFS=(-vfsoverlay "$OUT/vfs.yaml")
fi

clang -c -fobjc-arc -fmodules -target "$TARGET" -isysroot "$SDK" -I Sources/CVirtualDisplay/include \
    Sources/CVirtualDisplay/CVirtualDisplay.m -o "$OUT/CVirtualDisplay.o"

cat > "$OUT/module.modulemap" <<'EOF'
module CVirtualDisplay {
    header "CVirtualDisplay.h"
    export *
}
EOF
cp Sources/CVirtualDisplay/include/CVirtualDisplay.h "$OUT/CVirtualDisplay.h"

swiftc ${VFS[@]+"${VFS[@]}"} -swift-version 5 -target "$TARGET" -sdk "$SDK" -parse-as-library -emit-module -emit-object -wmo \
    -module-name PocketXRCore -emit-module-path "$OUT/PocketXRCore.swiftmodule" \
    Sources/PocketXRCore/*.swift -o "$OUT/PocketXRCore.o"

swiftc ${VFS[@]+"${VFS[@]}"} -swift-version 5 -target "$TARGET" -sdk "$SDK" -wmo -module-name PocketXR -I "$OUT" \
    Sources/PocketXR/*.swift "$OUT/PocketXRCore.o" "$OUT/CVirtualDisplay.o" \
    -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework ScreenCaptureKit \
    -framework IOKit -framework CoreVideo -o "$OUT/PocketXR"
echo "built $OUT/PocketXR"
