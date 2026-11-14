# 0024. Client stacks: Swift 6 SwiftPM Mac client, React 19 + Vite web

Status: accepted · Date: 2026-11-14 · Supersedes old ADR 0002 (plain swiftc) for v2

## Context
Old ADR 0002 used plain `swiftc` because SwiftPM linking was broken on one machine. CI runs on GitHub macOS runners.

## Decision
- **Mac client**: Swift 6 language mode, SwiftUI + AppKit where needed, SwiftPM package at `apps/mac/Package.swift`,
  macOS 14+. ScreenCaptureKit for window images, Accessibility for titles and focus, Vision for OCR, all on device.
  Keychain for the master key and device key. Build and test with `swift build` / `swift test` on the CI `mac` job.
  Signed with Developer ID and notarized for distribution ([OQ-16](../OPEN_QUESTIONS.md#oq-16-mac-distribution-and-signing)).
- If SwiftPM linking breaks on a dev Mac again, the fallback is the old `build.sh` approach for that Mac only; CI stays
  on SwiftPM.
- **Web app**: React 19 + Vite, TanStack Router and Query, strict CSP, design tokens shared with the Mac
  (`packages/contracts` exports token values; Swift tokens are generated from them).
- UI direction: light paper field `#f4f5f2`, dark floating chrome, Geist / Geist Mono, dusk gradient brand colour,
  calm copy, motion that shows product state only ([PRODUCT.md](../PRODUCT.md#6-ui-direction)).

## Consequences
- The Swift package cannot build on the Linux dev box; the `mac` CI job is the gate.

## Alternatives considered
- Electron/Tauri for the Mac: loses ScreenCaptureKit/Vision ergonomics and native feel.

## Sources
Old ADR 0002, 0110; approved mockups; `/workspace/offload-pricing/LEARNINGS.md`.
