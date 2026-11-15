# apps/mac

Swift 6 / SwiftUI thin client for macOS 14+. SwiftPM package (see Package.swift) with one test target.

It captures, masks on device, uploads masked observation batches, and shows the UI. It holds no brain.

Targets (slice m3-02-mac-capture-upload):

| Target | What it holds |
|---|---|
| `OffloadContracts` | Types generated from `packages/contracts/schemas` (`bun packages/contracts/scripts/gen-swift.ts`, committed in `Generated/`), JCS (RFC 8785), time and ULID helpers |
| `OffloadStore` | AES-256-GCM day files and egress ledger with Keychain-wrapped day keys, 7-day purge, reveal map, upload queue state |
| `OffloadMasker` | Structured-secret detectors, stable keyed pseudonyms, the device leak scan, scrypt key wrap |
| `OffloadObserver` | Focus, bounded Accessibility walk, OCR fallback, exclusions, pause, permissions. No networking (test enforced). `Live/` has the macOS glue |
| `OffloadUploader` | The egress guard: one host, closed types, detectors again, signed batches, local egress ledger, device key, enrollment client |
| `OffloadMac` | App wiring (`CaptureRuntime`). Onboarding and the other screens are the M3 follow-up slice |
| `OffloadImport`, `OffloadActuator` | Markers until their slices |

Tests live in `Tests/OffloadMacTests/M302` (one `@Suite struct M302`). The freshness test runs `bun`, so install Bun first.
See [ARCHITECTURE section 1](../../docs/ARCHITECTURE.md#1-mac-client) and [ADR 0007](../../docs/adr/0007-cloud-brain-thin-mac-client.md).

Build and test (macOS only): `swift build && swift test`. CI runs this in the `mac` job. It cannot build on Linux.
