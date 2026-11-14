// swift-tools-version: 6.0
// Offload Mac client (thin client: capture, on-device masking and pseudonyms, egress-guarded upload, actuator, UI).
// Architecture only: empty targets. See docs/ARCHITECTURE.md#1-mac-client.
// Builds only on macOS 14+ with Swift 6 (CI job "mac"). Not buildable on Linux.
// `swift build` output is not an app bundle: TCC grants bind to bundle id + Team ID, so daily use needs the
// bundled, signed app (operator items O1 to O3 in docs/ROADMAP.md).
import PackageDescription

let v6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "OffloadMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OffloadMac", targets: ["OffloadMac"]),
        // m3-04: the launchable app (menu bar item and main window). Logic and views stay in the OffloadMac library.
        .executable(name: "Offload", targets: ["OffloadMacApp"]),
    ],
    targets: [
        // Generated wire types (from packages/contracts/schemas) and the RFC 8785 JCS canonicaliser.
        .target(name: "OffloadContracts", path: "Sources/OffloadContracts", swiftSettings: v6),
        // Encrypted 7-day day-file store (AES-256-GCM, Keychain-wrapped keys) and the local egress ledger.
        .target(name: "OffloadStore", dependencies: ["OffloadContracts"], path: "Sources/OffloadStore", swiftSettings: v6),
        // On-device detectors, structured-secret masking and stable keyed pseudonyms.
        .target(name: "OffloadMasker", dependencies: ["OffloadContracts"], path: "Sources/OffloadMasker", swiftSettings: v6),
        // Accessibility-first capture. No networking code (test enforced).
        .target(
            name: "OffloadObserver",
            dependencies: ["OffloadContracts", "OffloadStore", "OffloadMasker"],
            path: "Sources/OffloadObserver",
            swiftSettings: v6
        ),
        // Uploader = the Mac egress guard: one host, closed schemas, signed batches, fail closed.
        .target(
            name: "OffloadUploader",
            dependencies: ["OffloadContracts", "OffloadStore", "OffloadMasker"],
            path: "Sources/OffloadUploader",
            swiftSettings: v6
        ),
        // Optional recordings import into a separate import space (M3).
        .target(
            name: "OffloadImport",
            dependencies: ["OffloadContracts", "OffloadStore", "OffloadMasker"],
            path: "Sources/OffloadImport",
            swiftSettings: v6
        ),
        // Typed device commands only (shortcut.run, appleevent.template, ax.action, browser.step). M6.
        .target(name: "OffloadActuator", dependencies: ["OffloadContracts"], path: "Sources/OffloadActuator", swiftSettings: v6),
        // The app: UI, enrollment, device key, supervision of the observer.
        .target(
            name: "OffloadMac",
            dependencies: [
                "OffloadContracts", "OffloadStore", "OffloadMasker", "OffloadObserver",
                "OffloadUploader", "OffloadImport", "OffloadActuator",
            ],
            path: "Sources/OffloadMac",
            swiftSettings: v6
        ),
        // m3-04: the @main SwiftUI App only.
        .executableTarget(
            name: "OffloadMacApp",
            dependencies: ["OffloadMac"],
            path: "Sources/OffloadMacApp",
            swiftSettings: v6
        ),
        .testTarget(
            name: "OffloadMacTests",
            dependencies: [
                "OffloadContracts", "OffloadStore", "OffloadMasker", "OffloadObserver",
                "OffloadUploader", "OffloadImport", "OffloadActuator", "OffloadMac",
            ],
            path: "Tests/OffloadMacTests",
            swiftSettings: v6
        ),
    ]
)
