---
id: m3-14-mac-app-integration
title: One coherent Mac app: one entry point and one composition root that starts the updater, capture and the uploader from the consent state, with Never watch shared by live capture and the recordings import
milestone: M3
status: in_progress
depends_on: [m3-02-mac-capture-upload, m3-03-mac-signing-sparkle, m3-04-mac-onboarding, m3-05-recordings-import, m3-09-mac-test-build]
parallel_safe: false
human_gated: true
model_tier: opus
size: M
parallel_group: M3-D
owns: [apps/mac/Sources/OffloadMac/Composition/**, apps/mac/Tests/OffloadMacTests/M314/**]
verify: bash slices/m3-14-mac-app-integration/verify.sh
min_tests: 47
paths_in_scope: [apps/mac/Sources/OffloadMac/Composition/**, apps/mac/Sources/OffloadMac/CaptureRuntime.swift, apps/mac/Sources/OffloadMac/App/**, apps/mac/Sources/OffloadMac/OffloadMac.swift, apps/mac/Sources/OffloadMac/Shell/AppModel.swift, apps/mac/Sources/OffloadMac/Onboarding/Services.swift, apps/mac/Sources/OffloadMac/Updates/CaptureLifecycle.swift, apps/mac/Sources/OffloadUploader/Uploader.swift, apps/mac/Sources/OffloadUploader/DeviceKey.swift, apps/mac/Sources/OffloadUploader/ImportOutbox.swift, apps/mac/Sources/OffloadUploader/Tokens.swift, apps/mac/Package.swift, docs/ONBOARDING.md, apps/mac/Tests/OffloadMacTests/M314/**, apps/mac/README.md, docs/ARCHITECTURE.md, slices/m3-14-mac-app-integration/**]
paths_out_of_scope: [ee/**, services/**, packages/**, apps/web/**, docs/adr/**, .github/**, NOTICE, apps/mac/Packaging/**, apps/mac/TestBuild/**, apps/mac/Sources/OffloadImport/**, apps/mac/Sources/OffloadObserver/**, apps/mac/Sources/OffloadMasker/**, apps/mac/Sources/OffloadStore/**, apps/mac/Sources/OffloadContracts/**, apps/mac/Sources/OffloadMac/Recordings/**, apps/mac/Sources/OffloadMac/LocalNow/**, apps/mac/Sources/OffloadMac/NeverWatch/**, apps/mac/Sources/OffloadMac/Permissions/**, apps/mac/Sources/OffloadMac/Today/**, apps/mac/Sources/OffloadMac/Design/**, apps/mac/Sources/OffloadMac/Version/**, apps/mac/Sources/OffloadMac/Shell/Launch.swift, apps/mac/Sources/OffloadMac/Shell/AppMover.swift, apps/mac/Sources/OffloadMac/Shell/MenuBar.swift, apps/mac/Sources/OffloadMac/Shell/RootView.swift, apps/mac/Sources/OffloadMac/Shell/LiveServices.swift, apps/mac/Tests/OffloadMacTests/M302/**, apps/mac/Tests/OffloadMacTests/M303/**, apps/mac/Tests/OffloadMacTests/M304/**, apps/mac/Tests/OffloadMacTests/M305/**, apps/mac/Tests/OffloadMacTests/M309/**]
red_tests: [ENTRY, LAUNCH, CAPTURE, UPLOAD, EXCLUDE, NOW, IMPORT]
---

# m3-14-mac-app-integration

## Summary
Three branches each built part of the Mac app: m3-03 (signing, Sparkle, `Offload --self-check`, on `main`), m3-04,
m3-05 and m3-09 (shell, onboarding, permissions, Never watch, recordings import, test build; PR #7) and m3-02 (capture
and upload: observer, masker, encrypted store, uploader; PR #13, which replaced `OffloadMac.swift` with
`CaptureRuntime.swift` and conflicts with `main`). This slice merges PR #13 into PR #7's branch (history and authors
kept) and makes one app of the three ([ARCHITECTURE section 1](../../docs/ARCHITECTURE.md#1-mac-client),
[ONBOARDING sections 10 and 11](../../docs/ONBOARDING.md#10-skips-and-product-modes)): one `@main`, one composition
root, and the launch decisions (updater, capture, uploader, import sink) made in one tested function from the saved
consent state. It also wires what the W1-D audit found unwired and that belongs to the app: the local now summary
reads the observer's encrypted day store, the real `OffloadMasker` masks recordings imports, Never watch reaches the
running observer, and imports go through the uploader when this Mac is signed in and sending.
`human_gated: true`: capture and the uploader only really run on the owner's Mac with the signed bundle.

## Contract
- **One entry point.** `OffloadMac.swift` keeps the only `@main` (`OffloadEntry`). What it runs is decided by
  `EntryCommand.decide(arguments:info:)`: `--self-check` (m3-03, no UI, no Sparkle, fake permission source, capture
  not started), `--version` (m3-09), otherwise the SwiftUI app. `OffloadApp` builds everything once through
  `AppComposition.live()`; no other file constructs `AppModel`, `AppUpdates`, `CaptureRuntime` or `UploadRuntime`.
  `CaptureRuntime.swift` (PR #13) moves to `Composition/CaptureRuntime.swift` and is split in two.
- **`BackendMode`** (`Composition/BackendMode.swift`): `.local` (the test build's default: nothing leaves the Mac) or
  `.cloud(apiBase:deviceID:)`, chosen by `BackendMode.decide(apiBase:deviceID:deviceKeyStored:)`: an `https` API base
  (or `http` on a loopback host), a non-empty device id from enrollment and a stored device key, else `.local`. The
  live values: Info.plist `OffloadAPIBase`, `UserDefaults` `OffloadDeviceID` (written by enrollment, m1-04 client
  in PR #13), the device key in the Keychain. The test build sets none of them, so it runs in `.local`.
- **`LaunchPlan.decide(_ facts: LaunchFacts) -> LaunchPlan`** (`Composition/LaunchPlan.swift`), pure:
  - `startUpdater`: always (Sparkle sends no observation; it is how fixes reach the Mac).
  - `startCapture`: the person resolved screen 2 (`captureStarted`, which needs screen 1 and a permission on) and
    the local buffer is readable (row 11.6: no capture until "Start fresh" is chosen). The observer itself follows
    later permission changes (rows 11.1 to 11.4).
  - `startUploader`: `.cloud`, `sending` (signed in and upload consent), no re-consent pending (row 11.11: a notice
    version that differs from the accepted one pauses uploads), and the buffer readable. Never in `.local`.
  - `importSink`: `.uploader` exactly when `startUploader`, else `.onDevice` (the import space stays on the Mac).
  `AppModel` calls it after its launch-time permission read and notice check; `AppComposition` calls it with the
  same facts to pick the import sink. M304's launch tests keep passing unchanged (`uploadsAvailable` defaults to
  true for injected services).
- **`CaptureRuntime`** (live capture only, `@MainActor`, `CaptureControl` and m3-03's `CaptureLifecycle`): builds
  the observer, the encrypted day store, the key ring and the pseudonym key on the first `start()` and not before,
  so nothing is written or created on disk or in the Keychain before consent. Ticks the observer every second; on
  every tick it first syncs the Never watch list into `StoreLayout.exclusionsFile`, which the observer's
  `ExclusionReloader` re-reads every 2 s. `prepareForUpdate()` stops the timer (Sparkle install, m3-03).
- **`UploadRuntime`** (`Composition/UploadRuntime.swift`, `@MainActor`, m3-04's `Uploader`): exists only in
  `.cloud`; builds PR #13's `OffloadUploader.Uploader` (device key, `DeviceSession`, `GuardedTransport`, the egress
  ledger) on the first `start()`, offers it a turn every 30 s, `pause()` stops the turns (re-consent).
- **Never watch, one list** (`Composition/ExclusionBridge.swift`): `ExclusionBridge.rules(from:)` maps
  `NeverWatchStore` entries to the observer's `ExclusionRule` (same three kinds); `ExclusionsFile.sync()` writes them
  atomically only when they changed. The same `NeverWatchStore` instance feeds the onboarding screens, the menu bar
  "Don't watch", the observer (through the file) and the recordings import (`NeverWatchImportExclusions`).
- **Local now line** (`Composition/StoreEventSource.swift`): `StoreEventSource: LocalEventSource` reads the observer's
  day store (live observations only, never `source = "import"`): `focus` (bundle id and app name), `idle_start`,
  `idle_end`, `pause`, `resume`, `text_snapshot`, `input_counts` (as `input`); `permission_change` is skipped. It
  returns events with `from < ts <= to` plus the last focus before `from` (looked up at most one stored day back),
  and `captureStartedAt()` is the earliest stored observation. Before capture has started it reads nothing.
- **Recordings import** (`Composition/ImportComposition.swift`): `ImportMaskerAdapter: ImportTextMasker` over
  `OffloadMasker.TextMasker` (the same masker and pseudonym key as live capture, fail closed). `ImportComposition.
  importer(...)` returns a `RecordingImporter` only when a `TextRecognizer` and a sink exist, else nil.
  `UploaderImportSink: ImportSink` opens an import space through `ImportUploadQueue.openImport` (`POST /v1/imports`),
  converts every `ImportObservation` through the closed `Observation` schema, refuses any object that is not
  `source = "import"` with this space's `import_id`, and hands them to `ImportUploadQueue.stageImport`, which is
  synchronous and durable: the objects are checked (import objects only, device detectors) and sealed in
  `ImportOutbox` (`import-outbox.enc`, `OffloadUploader`) before `write` returns, or `write` throws and m3-05's
  importer leaves the file unrecorded. `OffloadUploader.Uploader(importOutbox:memberTokens:)` batches the outbox inside
  `flush()` in the synchronous step that saves its queue (next seqs, same retry and egress ledger as live batches; a
  detector hit stops that flush like a live one and sets the object aside), and offers `openImport(sourceKind:)` and
  `forgetImport(id:)`: signed POSTs to the one host with a **member**-audience token (`DeviceSession(audience:
  .member)`; API.md section 1, Auth) and JCS bodies, each written to the egress ledger. `UploadRuntime` refuses to open
  or stage while paused; forgetting (a delete request) is allowed. It builds the uploader through
  `UploadRuntime.Network` (`.live`: URLSession and one `DeviceSession` per audience; tests inject a scripted transport).
- **Offer rule** (`Composition/ModeLines.swift`, `ImportOffer`): the composition replaces m3-04's "while sending"
  `offerCheck`. Through the uploader: offered while the person is sending with no new notice waiting (ONBOARDING
  section 8). On this Mac: offered whenever m3-10's on-device sink exists, in Local mode too (see Scope changes).
- **Menu lines** (`ModeLines`, `AppComposition.modeLines`, read each time the menu draws): "Local mode: nothing leaves
  this Mac" whenever nothing is uploaded (GLOSSARY: signed out or without upload consent), then why the import is not
  offered ("Recordings import is coming: it needs on-device text reading" without an importer; "Recordings import
  starts after Start sending" otherwise). Plain text items.
- **Seams for m3-10** (on-device OCR, local analysis store, Today/Weekly/Builds navigation; sibling branch):
  `CompositionSeams { textRecognizer, onDeviceImportSink }` passed to `AppComposition.live(seams:)`. With both nil
  (this slice) there is no importer and Local mode offers no import. m3-10 plugs its recognizer and its local sink in
  there (the import is then offered in Local mode) and reads `BackendMode` from `AppComposition.backend`.
- No new dependency. `Package.swift` changes only in its header comment (merge commit and 7dfa249).

## Design note
The app has one composition root, `AppComposition`, so the order of launch is visible in one place:

1. `OffloadEntry.main` → `EntryCommand.decide`: self-check and version exit before any UI, Keychain or disk access.
2. `OffloadApp.init` → `AppComposition.live()`: reads `BackendMode`, makes the one `NeverWatchStore`, the
   `CaptureRuntime` (nothing built yet), the `UploadRuntime` only in `.cloud`, the import model with the sink the
   launch facts allow, then `AppModel` (which reads both permissions, checks the notice version, and starts capture
   and the uploader per `LaunchPlan`) and `AppUpdates` (Sparkle, with the same `CaptureRuntime` as its
   `CaptureLifecycle`, so an update stops real capture).
3. Onboarding keeps its own runtime gates (m3-04): screen 2 starts capture, "Start sending" starts the uploader,
   a changed notice pauses it.

Splitting PR #13's `CaptureRuntime` was required by the consent rules: it built the uploader (and so needed an API
base and an enrolled device) to capture at all, so Local mode could not capture and the local now line had no
source. Capture is now local-only; the uploader is a second runtime that exists only for a signed-in, enrolled Mac.

The Never watch list reaches the observer through `exclusions.json`, not a new observer API: PR #13's observer
already reloads that file every 2 s, and the store (m3-04's) has no change callback, so the capture tick compares
and rewrites it. The import reads the store directly before each file (m3-05).

## Red tests (write these first, run them, see them fail)
`@Suite struct M314` in `apps/mac/Tests/OffloadMacTests/M314/`. No TCC, Keychain, window, Sparkle or network:
fakes and temp folders only.

| Tag | Test name | Asserts |
|---|---|---|
| ENTRY | ENTRY: --self-check runs the self-check before anything else, --version prints the version, anything else starts the app | `EntryCommand.decide` |
| ENTRY | ENTRY: the Mac sources hold exactly one @main, and only the composition root builds the app model, the updater and the runtimes | source scan |
| LAUNCH | LAUNCH: before consent nothing starts but the updater | fresh state, every backend |
| LAUNCH | LAUNCH: after screen 2 capture starts in Local mode and the uploader does not | |
| LAUNCH | LAUNCH: a signed-in, consented person on an enrolled Mac gets capture, the uploader and the uploader-backed import sink | |
| LAUNCH | LAUNCH: a changed notice keeps capture local and the uploader paused, and imports stay on the Mac | |
| LAUNCH | LAUNCH: an unreadable buffer starts neither capture nor the uploader | |
| LAUNCH | LAUNCH: the backend is cloud only with an https API base, a device id and a stored device key | `BackendMode.decide` |
| LAUNCH | LAUNCH: the app model starts the uploader only when uploads are available | `AppModel(uploadsAvailable:)` with fakes |
| CAPTURE | CAPTURE: the capture runtime creates nothing on disk until it is started | temp home stays absent |
| CAPTURE | CAPTURE: the composition gives the updater and the app the same capture runtime | identity |
| UPLOAD | UPLOAD: Local mode has no upload runtime and Start sending starts nothing that sends | |
| UPLOAD | UPLOAD: the upload runtime pauses its turns when the notice changes | |
| EXCLUDE | EXCLUDE: Never watch entries become the observer's rules, kind for kind | |
| EXCLUDE | EXCLUDE: the exclusions file is written when the list changes and not rewritten when it did not | |
| EXCLUDE | EXCLUDE: one Never watch list feeds the observer file and the recordings import | |
| NOW | NOW: focus, idle, pause and content observations become local events with millisecond times | |
| NOW | NOW: the window holds events after from up to to, plus the last focus before from | |
| NOW | NOW: imported observations never reach the local now line | |
| NOW | NOW: capture start is the earliest stored observation, and nothing is read before capture | |
| NOW | NOW: the local now summary counts apps from the day store | end to end through `LocalNowSummary` |
| IMPORT | IMPORT: the import masker is the capture masker: secrets and emails are masked before anything is written | |
| IMPORT | IMPORT: without a text recognizer or a sink there is no importer | |
| IMPORT | IMPORT: the uploader-backed sink opens the space through the uploader and queues closed-schema import objects | |
| IMPORT | IMPORT: the uploader-backed sink refuses an unknown space and objects of another space | |
| IMPORT | IMPORT: forgetting an import goes through the uploader | |

## Out of scope
On-device OCR (`TextRecognizer`), the local analysis store, Today/Weekly/Builds navigation (m3-10, sibling branch).
Sign-in in the app (the enrollment UI; `UnavailableAccountService` stays). The server's `POST /v1/imports` and forget
scope `import` (the API half; until it lands, opening an import space in `.cloud` fails closed and Import says the
import space could not be opened). Reveals for imported text (the import masker keeps no reveal map yet). Flushing the upload queue on quit or before an
update (the queue is on disk; the next launch sends it). Switching the import sink mid-session: it is chosen at launch,
so after "Start sending" on an enrolled Mac the uploader-backed import starts with the next launch.

## Verify
`bash slices/m3-14-mac-app-integration/verify.sh`: scope on every platform (only commits whose subject starts with
`m3-14-mac-app-integration: `); on macOS `swift build`, suite `OffloadMacTests.M314` with at least `min_tests`
passing and every tag present, then the full `swift test`. On Linux it prints SKIPPED after the scope check.

## Scope changes
- **Supersedes PR #13.** PR #13 (`w1/m3-02-mac-capture-upload`, slice m3-02) is merged into this branch with
  `git merge` (its commits and authors kept), so it does not need to merge separately: close #13 when this branch
  merges. Conflict resolution: `OffloadMac.swift` is kept (main's single `@main`, which #13 deleted);
  `.github/workflows/ci.yml`, `NOTICE`, `bun.lock`, `packages/testkit/**` and `slices/m1-02-contracts-ingest/SPEC.md`
  are main's (they already hold the squashed W1-C/W1-E/W1-F work #13 carried in older form);
  `packages/contracts/package.json` gains #13's `gen:swift` script; `apps/mac/Package.swift` and
  `apps/mac/README.md` get merged header text. #13's `SmokeTests.swift` and target markers are deleted as #13 did.
- **`CaptureRuntime` split** (PR #13's file, slice m3-02, `done`): moved to `Composition/` and split into
  `CaptureRuntime` (local) and `UploadRuntime` (cloud), see Design note. `OffloadUploader.Uploader` is named with its
  module everywhere in `OffloadMac`, because m3-04 already has a public `Uploader` protocol there.
- **`Uploader.swift`** (slice m3-02, `done`): one additive extension for import spaces (Contract). It reuses the
  existing envelope, ledger and retry code; nothing in the live path changes. **`DeviceKey.swift`**: one read-only
  `DeviceKey.isStored(secrets:)` so `BackendMode` can tell an enrolled Mac without creating a key.
- **m3-04 and m3-05 files**: `Shell/AppModel.swift` (launch decisions now call `LaunchPlan`; `live()` delegates to the
  composition root), `Onboarding/Services.swift` (doc comments for the real conformers only) and `App/**`. Owned
  paths of m3-04, m3-05 and m3-09 are not touched; `RecordingsImportModel` is built through its public initialiser
  instead of changing `RecordingsImportModel.live`.
- **Audit items left open** (W1-D audit, `logs/w1d-audit.md`): the import is still not offered in Local mode and has
  no OCR (m3-10); NOTICE's clicky entry is still "Planned" (m3-04/m3-05 before `done`); `PERF:` is manual.

### Review 1 (2026-11-22)
- **Finding 1 (blocker, tests for the import egress code):** new UPLOAD tests on PR #13's real `Uploader` over a scripted
  transport and an encrypted temp store: open and forget are signed POSTs to the one host with the exact bodies and
  ledger lines; a 401 refreshes once; refusals throw and write no ledger line; the import outbox refuses live objects,
  missing `import_id`s and detector hits; staged objects survive a restart and go out with the next flush under the
  next seqs; staging while a flush waits on the network is not overwritten; `DeviceKey.isStored` never creates a key;
  `BackendMode.live` reads the Keychain only with an API base and a device id; a paused `UploadRuntime` refuses to
  open or stage.
- **Finding 2 (major, failed hand-offs lost):** the hand-off is now synchronous and durable. `ImportUploadQueue.
  stageImport` checks the objects and seals them in `ImportOutbox` (`import-outbox.enc`, new file in
  `OffloadUploader`, added to `paths_in_scope`) before `UploaderImportSink.write` returns; when it throws, `write`
  throws and m3-05's importer does not record the file. The uploader drains the outbox inside `flush()` in the same
  synchronous step that saves the queue, which also removes the in-memory outbox of 86d31c9: staging never touches
  the upload state, so no flush can overwrite it. Forgetting an import stays allowed while paused (a delete request,
  no observation).
- **Finding 3 (major, the test build cannot import and does not say why):** not built here: on-device OCR and the local
  store are m3-10's (orchestrator brief for this slice: "do not build those; expose clean seams"). Resolved by saying
  it: the menu bar item shows "Local mode: nothing leaves this Mac" and "Recordings import needs on-device text
  reading, not in this build yet" (`ModeLines`, `AppComposition.modeLines`) until m3-10 plugs a recognizer in. Today's
  existing Local-mode banner (m3-04) stays.
- **Finding 4 (row 11.6):** `StoreContext.bufferReadable()` (newest day key opens, or no day files) feeds the launch;
  "Start fresh" now deletes the unreadable buffer (`StoreContext.discard()`, through `AppModel.onStartFresh`). A
  capture whose appends fail still reads as running; the observer has no failure signal to read yet (m3-02 follow-up).
- **Finding 5:** one `StoreContext` (one `KeyRing`, one `DayStore`, one `ImportOutbox`) is shared by capture, the
  uploader and the sink.
- **Finding 6:** the updater drives `UpdatePreparation`: capture stops and the uploader pauses before an install.
- **Finding 7:** both runtime timers run in the common run-loop modes (not unit-tested: run-loop modes need a running
  app).
- **Finding 8:** `Package.swift` header corrected (now in `paths_in_scope`, comment only); the duplicate doc comment
  went with the rewrite. The merge's `packages/contracts/package.json` script line and
  `packages/contracts/scripts/gen-swift.ts` are PR #13's own m3-02 work (common.md forbids this slice editing
  `packages/**`); the owner needs to accept them as part of merging #13's history.

### Review 2 (2026-11-22)
- **Finding 1 (major, import calls used a device-audience token):** `DeviceSession` takes an audience
  (`Tokens.swift`, added to `paths_in_scope`); `UploadRuntime` makes one session per audience and the uploader signs
  `/v1/imports` and `/v1/me/forget` with the member one (no member provider: `ImportUploadError.noMemberToken`, nothing
  sent). Request bodies are `JCS.encode`d. Tests assert the bearer per route and that every body is its own JCS form.
- **Finding 2 (major, the m3-10 seam alone offered nothing):** the offer rule moved into the composition
  (`ImportOffer`, live), and the menu lines are computed from the live state, so they never go quiet while the import is
  hidden. **Divergence from ONBOARDING section 8** (the import shows only while signed in and sending): with an
  on-device sink the import is offered in Local mode, because the owner's goal for the test build (2026-11-22) is to
  read `~/screenwatch` and recordings on the Mac, and that import sends nothing. ONBOARDING section 8 now says so.
  The uploader-backed import keeps the section 8 rule.
- **Finding 3 (major, the runtime's own uploader untested):** `UploadRuntime.Network` is injectable; a test stages
  through the runtime, flushes the runtime's own uploader over a scripted transport, and sees the import objects in a
  batch (device token), the open with the member token, and the shared outbox empty.
- **Finding 4:** the Contract above describes the outbox, the member token and the menu; the `enqueueImport` and
  `Package.swift` sentences are gone.
- **Finding 5:** `exclusions.json` is written 0600. **Divergence from SECURITY_PRIVACY section 6** (the Never watch list
  moves into the sealed store with m3-02): the observer's reloader (PR #13) reads plain JSON, so a plain 0600 copy
  of bundle ids, hosts and title words sits next to the sealed store; moving the reloader onto a sealed file is an
  m3-02 follow-up. SECURITY_PRIVACY is outside this slice's paths; the owner or the m3-02 follow-up updates it.
- **Finding 6:** `bufferReadable()` reads the master key without creating one; a Keychain error counts as readable.
- **Finding 7:** "Start fresh" also deletes the import ledger (`StoreContext.importLedgerFile`).
- **Finding 8:** the lines say "coming", render as `Text`, and Local mode follows the GLOSSARY (an enrolled Mac before
  "Start sending" says Local mode).
- **Finding 9:** `CaptureRuntime.tickOnce()` holds the tick body and is tested. The 86d31c9 ordering (paused refusal
  before its test) is history; its test came in 3a6c895.
- **Finding 10:** an import detector hit now stops that flush like a live one (set aside, counted, nothing sent).
