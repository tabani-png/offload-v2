// swift-tools-version: 6.0
// Offload Mac client (thin client: capture, on-device masking and pseudonyms, egress-guarded upload, actuator, UI).
// Capture half (slice m3-02): contracts + JCS, store, masker, observer, uploader (egress guard).
// OffloadImport holds the recordings import (m3-05); OffloadActuator is still a marker. See docs/ARCHITECTURE.md#1-mac-client.
// The app target OffloadMac is an executable: product "Offload", which bundle.sh copies to
// Offload.app/Contents/MacOS/Offload (docs/DEPLOYMENT.md section 3.1). Its one composition root is Composition/
// (slice m3-14-mac-app-integration).
// Sparkle 2 is the one third-party dependency, linked only into the app target (ADR 0024, DEPLOYMENT section 4).
// Builds only on macOS 14+ with Swift 6 (CI job "mac"). Not buildable on Linux.
// `swift build` output is not an app bundle: TCC grants bind to bundle id + Team ID, so daily use needs the
// bundled, signed app (operator items O1 to O3 in docs/ROADMAP.md).
import PackageDescription

let v6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "OffloadMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Offload", targets: ["OffloadMac"])
    ],
    dependencies: [
        // Updates (docs/DEPLOYMENT.md section 4). Exact pin; Package.resolved is committed.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
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
        // The app: UI, enrollment, device key, supervision of the observer, updates, `Offload --self-check`.
        .executableTarget(
            name: "OffloadMac",
            dependencies: [
                "OffloadContracts", "OffloadStore", "OffloadMasker", "OffloadObserver",
                "OffloadUploader", "OffloadImport", "OffloadActuator",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/OffloadMac",
            swiftSettings: v6,
            // Inside Offload.app the executable sits in Contents/MacOS and Sparkle.framework in Contents/Frameworks.
            // SwiftPM's own rpaths only cover .build/<config>, so the bundled app needs this one to load Sparkle.
            // unsafeFlags are allowed because this is the root package.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
