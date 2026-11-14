# apps/mac

Swift 6 / SwiftUI thin client for macOS 14+. SwiftPM package with empty targets (see Package.swift) and one test target.

It captures, masks on device, uploads masked observation batches, and shows the UI. It holds no brain.
See [ARCHITECTURE section 1](../../docs/ARCHITECTURE.md#1-mac-client) and [ADR 0007](../../docs/adr/0007-cloud-brain-thin-mac-client.md).

Build and test (macOS only): `swift build && swift test`. CI runs this in the `mac` job. It cannot build on Linux.
