# 0024. Client stacks: Swift 6 SwiftPM Mac client, React 19 + Vite web

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Supersedes old ADR 0002 (plain swiftc) for v2

## Context
Old ADR 0002 used plain `swiftc` because SwiftPM linking was broken on one machine. macOS permission grants (TCC) bind
to an app's bundle id and Team ID; `swift build` output is not an app bundle, so grants land on the terminal and reset
on every rebuild (PR #42 D§5.6). M3's exit (one full working day of capture) needs a signed app with a stable
identity, and every client fix needs a way to reach the Mac without a manual reinstall.

## Decision
- **Mac client**: Swift 6 language mode, SwiftUI + AppKit where needed, SwiftPM package at `apps/mac/Package.swift`,
  macOS 14+. Targets: `OffloadContracts` (generated types, JCS), `OffloadObserver` (no networking), `OffloadMasker`,
  `OffloadStore`, `OffloadUploader`, `OffloadImport` (recordings), `OffloadActuator` (M6), `OffloadMac` (app).
  Accessibility for text, titles and focus; ScreenCaptureKit + Vision OCR as fallback; Keychain and Secure Enclave for
  keys.
- **Signing and identity started in M0, needed by M3** (operator items O1 to O3): Apple Developer Program enrolment as the organisation
  consultance.ai (decided 2026-11-14; the owner enrols himself and is the Account Holder,
  [OQ-16](../OPEN_QUESTIONS.md#oq-16-mac-distribution-and-signing) (b)), bundle id locked (default `ai.offload.mac`, dev builds `ai.offload.mac.dev`, [OQ-16](../OPEN_QUESTIONS.md#oq-16-mac-distribution-and-signing)),
  Developer ID signing and notarization credentials in CI. The CI `mac` job runs on `macos-26` (as PR #41 did) and has
  a bundling step that produces a signed `.app` once the credentials exist.
- **Sparkle** auto-update (EdDSA-signed appcast) lands in M3, when the app becomes a daily install
  ([DEPLOYMENT.md](../DEPLOYMENT.md)).
- If SwiftPM linking breaks on a dev Mac again, the fallback is the old `build.sh` approach for that Mac only; CI stays
  on SwiftPM.
- **Web app**: React 19 + Vite, TanStack Router and Query, strict CSP with no inline style (old 0114), design tokens
  shared with the Mac (`packages/contracts` exports token values; Swift tokens are generated from them).
- UI direction: light paper field `#f4f5f2`, dark floating chrome, Geist / Geist Mono, dusk gradient brand colour,
  calm copy, motion that shows product state only ([PRODUCT.md](../PRODUCT.md#6-ui-direction)). UI taste references
  are design-review inputs only.

## Consequences
- The Swift package cannot build on the Linux dev box; the `mac` CI job is the gate.
- macOS CI is blocked until the GitHub token gets the `workflow` scope (operator item O4).

## Alternatives considered
- Electron/Tauri for the Mac: loses Accessibility/ScreenCaptureKit/Vision ergonomics and native feel.
- Signing at M8 (the previous version): TCC grants would not survive rebuilds before then (review-c P1(8)).

## Sources
Old ADR 0002, 0110, old 0114 (CSP); approved mockups; `/workspace/offload-pricing/LEARNINGS.md`; PR #41
(macos-26 runner, INSTALL_AND_TEST.md); PR #42 D§5.

## Revisions
- 2026-11-14: signing, bundle id and TCC moved to M0, Sparkle at M3, `macos-26` runner and bundling step, Mac targets
  named (review-c P1(8), review-b 21, PR #41).
- 2026-11-14 (final pass): signing and identity start in M0 and are needed by M3 (final-pass audit).
- 2026-11-14 (decision pass D): Apple Developer enrolment as the organisation consultance.ai decided by the owner, who
  enrols himself as Account Holder (OQ-16 (b)).
