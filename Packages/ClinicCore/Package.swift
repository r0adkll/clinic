// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClinicCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ClinicCore", targets: ["ClinicCore"])],
    targets: [
        .target(name: "ClinicCore", resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ClinicCoreTests", dependencies: ["ClinicCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
