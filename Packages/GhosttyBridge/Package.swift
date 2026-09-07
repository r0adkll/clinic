// swift-tools-version: 6.0
import PackageDescription

// The only place GhosttyKit (ghostty.h) is imported (ADR-008, ADR-020).
// GhosttyKit.xcframework is produced by scripts/build-ghostty.sh and is gitignored.
let package = Package(
    name: "GhosttyBridge",
    platforms: [.macOS(.v15)],
    products: [.library(name: "GhosttyBridge", targets: ["GhosttyBridge"])],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "GhosttyKit.xcframework"),
        .target(name: "GhosttyBridge", dependencies: ["GhosttyKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "GhosttyBridgeTests", dependencies: ["GhosttyBridge"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
