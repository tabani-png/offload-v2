# 0006. Metadata-first, Accessibility-first capture, fail closed

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Carries over old ADR 0003

## Context
Watching a screen is sensitive. Most of the signal Offload needs is metadata. Text matters too, and the Accessibility
tree gives it structured, cheaply, and without the screen-recording permission that macOS keeps re-asking for
(PR #42 A§4.1, A§4.6).

## Decision
- The observer records app, window title, URL host (path as a pseudonym, [ADR 0028](0028-stable-keyed-pseudonyms.md)),
  idle state (120 s threshold, `CGEventSource`, no permission needed) and pause/resume with a reason (`user`, `lock`,
  `sleep`, `permission`).
- **Text is Accessibility-first**: a bounded breadth-first walk of the focused window's Accessibility tree (at most
  1,500 nodes, depth 12, 150 ms), collecting role, label and value of text-bearing elements, skipping secure text
  fields. It runs on focus change and at most every 30 s when the text hash changed. Observations carry
  `text_source: "ax"`.
- **OCR is the fallback**: a ScreenCaptureKit single-window frame plus Vision text recognition, only when the
  Accessibility snapshot yields fewer than 200 characters for a window with visible content, same throttle,
  `text_source: "ocr"`. Text is masked, truncated to 8000 characters and de-duplicated by hash.
- **Input counts are off by default** and Input Monitoring is **not** requested at setup. It is an optional setting.
- Capture **pauses on screen lock and sleep**. Permission changes are recorded as `permission_change` observations
  (`{screen_recording, accessibility}` booleans); losing Screen Recording degrades capture to Accessibility only, it does
  not stop.
- Built-in exclusions (password managers, authenticators, banking apps and domains, private windows, system
  authentication dialogs, Offload's own windows, screen sharing and remote desktop clients) and user exclusions
  ("Never watch") are applied before capture. An excluded window yields the app name only.
- Secure input (password fields) pauses text capture.
- Privacy fails closed: if masking fails or exclusions cannot be read, the observer records metadata only for that tick.
- The observer has no network code, enforced by a test that bans networking APIs in its sources. The uploader is a
  separate component that reads only the masked store and is itself the Mac egress guard ([ADR 0035](0035-mac-egress-guard-and-ledger.md)).
- The observer runs as a child of the signed app so macOS attributes permissions to the app's bundle id (spike S1),
  and the app starts at login through `SMAppService`.
- Resource budgets, enforced in tests and a soak run: observer CPU under 3% of one core averaged over an 8-hour day on
  an M1 Air; resident memory under 200 MB; OCR at most once per 30 s per window and none on battery below 20%.

## Consequences
- Understanding works from metadata plus masked, pseudonymised text. Images are optional ([OQ-04](../OPEN_QUESTIONS.md#oq-04-keyframes-to-the-cloud)).
- Onboarding asks for Accessibility and Screen Recording only ([ONBOARDING.md](../ONBOARDING.md)).
- Permission state must come from the preflight calls, never from reading the system's permission database.

## Alternatives considered
- OCR on every change as the primary text source (the previous version). Rejected: more CPU, unstructured text, and it
  stops when macOS re-asks for screen recording ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(8)).
- Continuous screenshots to the cloud (Kortix Capture, screenpipe style). Rejected: privacy and cost.

## Sources
Old ADR 0003, 0007; old `engine/` (no-network test `S02NoNetworkTests`); PR #42 A§4.1, A§4.5, A§4.6; PR #44
(exclusions reloaded within 2 s, permission polling).

## Revisions
- 2026-11-14: Accessibility-first text, OCR under 200 characters, input counts off by default and no Input Monitoring
  at setup, pause on lock and sleep, `permission_change`, observer as a child of the app, `SMAppService`, resource
  budgets ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(8), PR #42 A§4).
