// swift-tools-version:5.10
// Pocket XR for Mac. Built with `swift build`, bundled into Pocket XR.app by scripts/make-app.sh.
import PackageDescription

let package = Package(
    name: "PocketXR",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PocketXR", targets: ["PocketXR"]),
    ],
    targets: [
        // CoreGraphics' private virtual display classes, declared for Swift (no code of Apple's is copied).
        .target(name: "CVirtualDisplay", path: "Sources/CVirtualDisplay"),
        // The streaming host's native pieces: moonlight-common-c's ENet fork (control stream) and nanors'
        // Reed-Solomon (error correction), both MIT, with Pocket XR's small C layer over them (GPLv3).
        .target(
            name: "CHostNet",
            path: "Sources/CHostNet",
            exclude: ["enet/LICENSE", "nanors/LICENSE"],
            sources: ["enet", "nanors/rs.c", "nanors/obl/oblas_common.c", "nanors/obl/oblas_lite.c", "pxr_host.c"],
            cSettings: [
                .headerSearchPath("enet/include"), .headerSearchPath("nanors"), .headerSearchPath("nanors/obl"),
                .define("NDEBUG"), .define("HAS_SOCKLEN_T", to: "1"), .define("HAS_FCNTL", to: "1"),
                .define("HAS_IOCTL", to: "1"), .define("HAS_POLL", to: "1"), .define("HAS_GETADDRINFO", to: "1"),
                .define("HAS_GETNAMEINFO", to: "1"), .define("HAS_INET_PTON", to: "1"), .define("HAS_INET_NTOP", to: "1"),
                .define("HAS_MSGHDR_FLAGS", to: "1"), .unsafeFlags(["-w"]),
            ]
        ),
        // Everything that runs without a window: glasses, head tracking, the control link, the Space's maths.
        // Pure Swift and Foundation, so its tests run on any Mac with `swift test`.
        .target(name: "PocketXRCore", path: "Sources/PocketXRCore"),
        .executableTarget(
            name: "PocketXR",
            dependencies: ["PocketXRCore", "CVirtualDisplay", "CHostNet"],
            path: "Sources/PocketXR",
            // The Metal shaders are compiled at start from source (Renderer.shaderSource): `swift build` on its own
            // does not compile .metal files, only Xcode does.
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(name: "PocketXRCoreTests", dependencies: ["PocketXRCore"], path: "Tests/PocketXRCoreTests"),
    ]
)
