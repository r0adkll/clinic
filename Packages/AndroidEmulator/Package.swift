// swift-tools-version: 6.0
import PackageDescription

// The Android emulator's gRPC control service (EmulatorController), for the Device pane. The client in
// `Sources/AndroidEmulator/Generated` is generated from `Proto/emulator_controller.proto`, copied from
// the SDK's `emulator/lib`, by `scripts/generate-emulator-grpc.sh`; it is checked in so a build needs
// no protoc.
let package = Package(
    name: "AndroidEmulator",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AndroidEmulator", targets: ["AndroidEmulator"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.11.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.5.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
    ],
    targets: [
        .target(
            name: "AndroidEmulator",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "AndroidEmulatorTests", dependencies: ["AndroidEmulator"]),
    ]
)
