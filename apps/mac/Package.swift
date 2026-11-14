// swift-tools-version: 6.0
// Offload Mac client (thin client: capture, on-device masking, upload, UI).
// Architecture only: empty targets. See docs/ARCHITECTURE.md#1-mac-client.
// Builds only on macOS 14+ with Swift 6 (CI job "mac"). Not buildable on Linux.
import PackageDescription

let package = Package(
    name: "OffloadMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OffloadMac", targets: ["OffloadMac"])
    ],
    targets: [
        .target(
            name: "OffloadMac",
            path: "Sources/OffloadMac",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OffloadMacTests",
            dependencies: ["OffloadMac"],
            path: "Tests/OffloadMacTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
