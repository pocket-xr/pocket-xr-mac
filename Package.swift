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
        // Everything that runs without a window: glasses, head tracking, the control link, the Space's maths.
        // Pure Swift and Foundation, so its tests run on any Mac with `swift test`.
        .target(name: "PocketXRCore", path: "Sources/PocketXRCore"),
        .executableTarget(
            name: "PocketXR",
            dependencies: ["PocketXRCore", "CVirtualDisplay"],
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
            ]
        ),
        .testTarget(name: "PocketXRCoreTests", dependencies: ["PocketXRCore"], path: "Tests/PocketXRCoreTests"),
    ]
)
