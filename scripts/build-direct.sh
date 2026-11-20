#!/bin/bash
# Builds Pocket XR without SwiftPM, for a Mac whose Command Line Tools cannot read Package.swift
# ("Invalid manifest ... Undefined symbols ... PackageDescription", seen with Swift 6.0.3 tools on macOS 14.8).
# The same three modules as Package.swift: CVirtualDisplay (Objective-C), PocketXRCore, PocketXR.
#
#   scripts/build-direct.sh            this Mac's architecture
#   scripts/build-direct.sh universal  Intel and Apple Silicon in one binary (the Command Line Tools' SDK has both)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "universal" ]; then
    for arch in x86_64 arm64; do
        ARCH="$arch" OUT=".build/direct-$arch" bash "$0"
    done
    mkdir -p .build/direct
    lipo -create .build/direct-x86_64/PocketXR .build/direct-arm64/PocketXR -output .build/direct/PocketXR
    lipo -info .build/direct/PocketXR
    echo "built .build/direct/PocketXR (universal)"
    exit 0
fi

OUT="${OUT:-.build/direct}"
mkdir -p "$OUT"
SDK=$(xcrun --show-sdk-path)
TARGET="${ARCH:-$(uname -m)}-apple-macosx14.0"

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

# The host's native pieces (Host*.swift): moonlight-common-c's ENet and nanors' Reed-Solomon, as SwiftPM's CHostNet.
HN=Sources/CHostNet
HOSTNET=()
for c in $HN/enet/*.c $HN/nanors/rs.c $HN/nanors/obl/oblas_common.c $HN/nanors/obl/oblas_lite.c $HN/pxr_host.c; do
    o="$OUT/hostnet-$(basename "${c%.c}").o"
    clang -c -O2 -w -target "$TARGET" -isysroot "$SDK" -DNDEBUG -DHAS_SOCKLEN_T=1 -DHAS_FCNTL=1 -DHAS_IOCTL=1 -DHAS_POLL=1 \
        -DHAS_GETADDRINFO=1 -DHAS_GETNAMEINFO=1 -DHAS_INET_PTON=1 -DHAS_INET_NTOP=1 -DHAS_MSGHDR_FLAGS=1 \
        -I $HN/include -I $HN/enet/include -I $HN/nanors -I $HN/nanors/obl "$c" -o "$o"
    HOSTNET+=("$o")
done

cat > "$OUT/module.modulemap" <<'EOF'
module CVirtualDisplay {
    header "CVirtualDisplay.h"
    export *
}
module CHostNet {
    header "CHostNet.h"
    export *
}
EOF
cp Sources/CVirtualDisplay/include/CVirtualDisplay.h "$OUT/CVirtualDisplay.h"
cp $HN/include/CHostNet.h "$OUT/CHostNet.h"

swiftc ${VFS[@]+"${VFS[@]}"} -swift-version 5 -target "$TARGET" -sdk "$SDK" -O -parse-as-library -emit-module -emit-object -wmo \
    -module-name PocketXRCore -emit-module-path "$OUT/PocketXRCore.swiftmodule" \
    Sources/PocketXRCore/*.swift -o "$OUT/PocketXRCore.o"

swiftc ${VFS[@]+"${VFS[@]}"} -swift-version 5 -target "$TARGET" -sdk "$SDK" -O -wmo -module-name PocketXR -I "$OUT" \
    Sources/PocketXR/*.swift "$OUT/PocketXRCore.o" "$OUT/CVirtualDisplay.o" "${HOSTNET[@]}" \
    -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework ScreenCaptureKit \
    -framework IOKit -framework CoreVideo -framework VideoToolbox -framework CoreMedia \
    -framework AudioToolbox -framework Security -framework Network -o "$OUT/PocketXR"
echo "built $OUT/PocketXR"
