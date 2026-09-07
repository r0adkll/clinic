// swift-tools-version: 6.0
import PackageDescription

// The only place GhosttyKit (ghostty.h) is imported (ADR-008, ADR-020).
// GhosttyKit.xcframework is produced by scripts/build-ghostty.sh and is gitignored.
//
// GhosttyKit is a *static* library (libghostty-fat.a). Its undefined symbols must be
// satisfied by whatever links this target, so the system frameworks and the C++
// runtime it depends on are declared here as linkerSettings (mirroring what
// vendor/ghostty/macos/Ghostty.xcodeproj links: Carbon.framework + "-lstdc++").
// SwiftPM propagates these to any executable/test/app that links GhosttyBridge.
let package = Package(
    name: "GhosttyBridge",
    platforms: [.macOS(.v15)],
    products: [.library(name: "GhosttyBridge", targets: ["GhosttyBridge"])],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "GhosttyKit.xcframework"),
        .target(
            name: "GhosttyBridge",
            dependencies: ["GhosttyKit"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // C++ runtime (harfbuzz/freetype/etc. inside libghostty are C++).
                .linkedLibrary("c++"),
                // Frameworks libghostty's Zig code resolves at link time.
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "GhosttyBridgeTests",
            dependencies: ["GhosttyBridge"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
