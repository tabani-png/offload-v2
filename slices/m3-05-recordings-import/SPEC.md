---
id: m3-05-recordings-import
title: Recordings import on the Mac into an import space (screen 11 and Settings, Recordings), with the stable file gate, recording names, fingerprint ledger and the masked import pipeline
milestone: M3
status: in_progress
depends_on: [m3-02-mac-capture-upload]
parallel_safe: true
human_gated: true
model_tier: opus
size: M
parallel_group: M3-C
owns: [apps/mac/Sources/OffloadImport/**, apps/mac/Sources/OffloadMac/Recordings/**, apps/mac/Tests/OffloadMacTests/M305/**]
verify: bash slices/m3-05-recordings-import/verify.sh
min_tests: 60
paths_in_scope: [apps/mac/Sources/OffloadImport/**, apps/mac/Sources/OffloadMac/Recordings/**, apps/mac/Sources/OffloadMac/Onboarding/Services.swift, apps/mac/Sources/OffloadMac/Onboarding/OnboardingModel.swift, apps/mac/Sources/OffloadMac/Onboarding/OnboardingView.swift, apps/mac/Sources/OffloadMac/Shell/AppModel.swift, apps/mac/Sources/OffloadMac/App/**, apps/mac/Sources/OffloadMacApp/**, apps/mac/Tests/OffloadMacTests/M305/**, apps/mac/README.md, docs/ONBOARDING.md, docs/ARCHITECTURE.md, docs/GLOSSARY.md, docs/SECURITY_PRIVACY.md, slices/m3-04-mac-onboarding/SPEC.md, slices/m3-05-recordings-import/**]
paths_out_of_scope: [ee/**, services/**, packages/**, apps/web/**, docs/adr/**, .github/**, NOTICE, apps/mac/Package.swift, apps/mac/Packaging/**, apps/mac/Sources/OffloadMac/OffloadMac.swift, apps/mac/Sources/OffloadMac/Updates/**, apps/mac/Sources/OffloadMac/SelfCheck/**, apps/mac/Sources/OffloadObserver/**, apps/mac/Sources/OffloadMasker/**, apps/mac/Sources/OffloadStore/**, apps/mac/Sources/OffloadUploader/**, apps/mac/Tests/OffloadMacTests/SmokeTests.swift, apps/mac/Tests/OffloadMacTests/M304/**]
red_tests: [NAMES, GATE, LEDGER, FRAMES, MENUBAR, INGEST, MASK, EXCLUDE, APART, SCREENWATCH, SCREENSHOTS, FOLDER, REFUSE, PROGRESS, SINK, SCREEN, COPY]
---

# m3-05-recordings-import

## Summary
The Mac half of the recordings import ([M3](../../docs/ROADMAP.md#m3-capture-to-cloud), ROADMAP row m3-05;
[ONBOARDING screen 11](../../docs/ONBOARDING.md#screen-11-recordings-optional); [ARCHITECTURE section 1](../../docs/ARCHITECTURE.md#1-mac-client)
"Recordings import"). A person picks a folder of screen recordings (or screenshots, or an old screenwatch archive) on
onboarding screen 11 or in Settings, Recordings. The Mac reads it: a file only once its size has stopped changing for
3 s, each file version once (SHA-256 fingerprint ledger, no names or paths), frames at most every 5 s, at most 720 per
file, at most 1280 px, through on-device OCR, the masker, the person's exclusions and the keyframe throttle. What comes
out is masked observations with `source = "import"` and an `import_id`, handed to an `ImportSink` shaped like the
m1-02 contracts. Pixels never leave the Mac and imports never mix with live data. Ported from PR #44 and the s34
import branches per [MIGRATION 5.5 and 5.7](../../docs/MIGRATION.md#55-pr-44-featcapture-from-clicky-s34-recordings-ingest).
`human_gated: true`: choosing a real folder and reading real recordings needs the owner on a Mac with the m3-09 build.

## Contract
- **No new dependency, no Package.swift change.** The `OffloadImport` target already exists (depends on
  `OffloadContracts`, `OffloadStore`, `OffloadMasker`, all still empty). It uses only system frameworks: Foundation,
  CoreGraphics, ImageIO, AVFoundation, CryptoKit. Delete `Sources/OffloadImport/OffloadImport.swift` (the TODO
  marker is replaced; nothing references `OffloadImportTodo`).
- **`OffloadImport`** (pure logic plus two AV/ImageIO readers; no networking API, test enforced):
  - `RecordingName`: `isVideo` (`mov`, `mp4`, `m4v`, not hidden), `isImage` (`png`, `jpg`, `jpeg`, `heic`, `webp`),
    `date(fromName:timeZone:)` (macOS "Screen Recording/Screenshot/Screen Shot DATE at H.MM.SS" with AM/PM after a
    plain, no-break or narrow no-break space (U+202F), 24-hour names, `(2)` copies, CleanShot with `@2x`, QuickTime
    and other ISO-ish, compact and unix-time names; an impossible date is nil, never rolled over). `SamplePlan.times`
    (every 5 s from 0, at most 720, spread evenly when longer).
  - `StableFileGate` (settle 3 s, injected time): ready only when the size is non-zero and unchanged for 3 s; a file
    whose modification time is already 3 s old counts as unchanged since then.
  - `MenuBarApp`: the app name from the menu bar band (top 4 % of the frame, at least 24 px), its bundle id or a
    stable `recording.<slug>`.
  - `RecordingLedger` protocol, `FileRecordingLedger` (JSON, file 0600, folder 0700, atomic replace) and
    `MemoryRecordingLedger`. An entry is `fingerprint` (SHA-256 hex of path, size and modification time in ms),
    `import_id`, times and counts only. `removeEntries(importID:)` for "Remove imported data".
  - `RecordingFolder.scan(_:protected:)` → `FolderScan` (source kind `screenwatch`, `screenshots` or `videos` as
    DATA_MODEL `imports.source_kind`; files depth ≤ 3, hidden files and bundles skipped) or `ImportRefusal`
    (`folder_missing`, `offload_data`, `offload_home`, `no_recordings`, each with a plain sentence).
    `RecordingFolder.suggested(home:screencaptureLocation:)` (where macOS saves recordings, else Desktop).
    `FolderSummary` (files, extensions, total seconds, first and last day).
  - `RecordingFrameSource` protocol, `ImportFrame`, `AVRecordingFrameSource` (AVAssetImageGenerator, long edge ≤
    1280, track transform applied, frames in memory only) and `ImageFileFrameSource` (ImageIO thumbnail ≤ 1280).
  - Injected protocols for m3-02's parts, with fakes in tests: `TextRecognizer` (OCR lines with top-left boxes),
    `ImportTextMasker` (the m3-02 masker), `FrameHasher` (64-bit perceptual hash), `ImportKeyframeSink` (m3-02
    renders, masks and seals keyframes; nil turns keyframes off). `ImportExclusionSource` returns
    `ImportExclusionRule`s (`bundle_id`, `host`, `title_contains`, as DATA_MODEL `exclusions`); `ImportBuiltins` adds
    the password-manager, banking and private-window rules ported from s34 `folder.ts`.
  - `KeyframeThrottle`: at most one keyframe per 20 s of recording time, and only when the picture changed (Hamming
    distance ≥ 10 on the 64-bit hash).
  - `RecordingIngestor` (one recording or one run of screenshots), `ScreenwatchReader` (one `days/DATE/log.jsonl`)
    and `RecordingImporter` (a folder: scan, gate, ledger, open the import space, read, write, record, progress).
  - Wire shapes from m1-02 (`packages/contracts/src/ingest.ts`, PR #1, read only): `ImportObservation` kinds
    `idle_end`, `focus` (`app_bundle_id` ≤ 255, `app_name` ≤ 256, `title` ≤ 512, `host`), `text_snapshot` (`text` ≤
    8000, `text_hash` = SHA-256 hex of the text, `text_source` `ocr`), `idle_start`; every one has a ULID `id`, an RFC
    3339 `ts`, `source: "import"` and `import_id`. `CreateImportRequest { source_kind }` → `{ import_id }`
    (`POST /v1/imports`); `ForgetImportRequest { scope: "import", import_id }` (`POST /v1/me/forget`).
  - **`ImportSink`**: `openImport(sourceKind:) async throws -> ImportSpace`, `write(_:to:) throws` (masked
    observations for the uploader to send with the import's id), `forget(_:) async throws`. Only fake:
    `InMemoryImportSink`. The server half is out of scope (see Scope changes).
  - `ImportProgress`: `started`, `reading(file:of:)`, `warning`, `finished(ImportReport)`, `refused(ImportRefusal)`.
- **`OffloadMac/Recordings/`** (UI): `RecordingsImportModel` (@MainActor; folder, summary, phase, import spaces,
  Choose folder…, Import, Remove imported data), `RecordingsCopy` (every string), `RecordingsFolderStore`
  (UserDefaults, in-memory fake), `FolderPicker` and `ImportPanelPresenter` protocols with AppKit `Live*` types
  (`NSOpenPanel`, a floating non-activating `NSPanel` on every Space), `NeverWatchImportExclusions` (m3-04's
  `ExclusionSource` as import rules, read before every file), `RecordingsScreenBody` and `RecordingsSettingsView`.
- **Hooks into m3-04's files** (additive): `OnboardingServices.recordings: RecordingsImportModel?` (default nil);
  `OnboardingModel` runs `.startRecordingsImport` through it (started → screen 12; not ready → the notice);
  `RecordingsScreen` shows the folder summary and Choose folder…; `AppModel.live()` builds the model; `OnboardingModel`
  sets the model's `offerCheck` to "signed in and sending". The app adds a `Window` scene with id `settings`, not a
  SwiftUI `Settings` scene, so the "Recordings…" menu bar entry can open it in front (`openWindow` plus
  `NSApp.activate()`; a `Settings` scene opens only through `SettingsLink`, which cannot activate a menu bar app).
  The entry and Settings' Import show only while the import is offered.

## Design note
- **Structure**: everything that decides is a value type or a small final class in `OffloadImport`; `RecordingImporter`
  is `Sendable` and runs off the main actor in a detached task; the @MainActor `RecordingsImportModel` only applies
  `ImportProgress` values. AppKit sits in `Live*` types the tests never build.
- **Time**: real timestamps, never rebased (MIGRATION 5.5 drops the rebasing). A recording starts at its name's time;
  otherwise at its modification time minus its length (a recorder writes until the end). A screenshot is at its
  name's time, else its modification time. A file whose time would end more than 10 minutes in the future (ADR 0020
  rejects that as `schema_invalid`) is skipped with a `future_time` warning.
- **Observations**: per recording, `idle_end` at the start, a `focus` whenever the menu bar app changes, a
  `text_snapshot` when the masked body text changes (menu bar band left out), `idle_start` at the end plus 120 s
  (readers backdate `idle_start` by the idle threshold, as m3-04's local now summary does). An excluded app keeps its
  `focus` (time counts, like live) but gets no title, no host, no text and no keyframe. Screenshots form runs (gap ≤
  120 s) with the same brackets. A screenwatch row with app, window and URL becomes a masked `focus` (title masked,
  URL reduced to its host); rows without app fields get one synthetic app `screenwatch.screen` "Screen".
- **Exclusions** are read again before each file, so a Never watch entry added during an import applies from the next
  file (the "within one check" rule of MIGRATION 5.5). A recording or screenshot has no window title or URL, so host,
  `title_contains` and private-window rules (the person's and the built-ins) are matched against the frame's OCR
  lines: a host token (`secure.chase.com`, `mail.example.org/inbox`) or the rule's words anywhere on the frame
  excludes it. This errs on the side of excluding (review 1 finding 3).
- **App names from pixels**: the top band is a menu bar only when the app name (at most 3 words) is followed by two
  menu titles; the name is used only when the masker leaves it unchanged. Otherwise the app is "Screen"
  (`recording.unknown`), so window text never leaves as `app_name` or `app_bundle_id` (review 1 finding 2).
- **Offered only while sending**: `RecordingsImportModel.offerCheck` defaults to false (fails closed); OnboardingModel
  wires it to `OnboardingState.sending`. Not offered, `startImport()` returns false with a notice and opens no import
  space (review 1 finding 4).
- **No folder read at launch**: building the model reads nothing. Screen 11 and Settings, Recordings call `refresh()`
  when they appear; it scans and reads recording lengths in a detached task (review 1 finding 1).
- **Streaming**: a run of screenshots is one span, but each screenshot is opened, read, written and recorded in the
  ledger before the next is opened (review 1 finding 5). Picking one `days/DATE/` folder of a screenwatch archive
  reads its rows.
- **Moments read** = frames read plus screenwatch rows. The ledger records a file only after its observations were
  written, so a crash re-reads the file instead of losing it.
- **Faked / deferred**: OCR, masker, perceptual hash and keyframe rendering are m3-02's; the uploader and the server
  half (`POST /v1/imports`, `import_id` ingest, forget scope `import`) are later. In this build the app has no
  `TextRecognizer` or masker, so `AppModel.live()` builds the model without an importer: screen 11 and Settings,
  Recordings show the real folder summary and Choose folder…, and Import says reading needs on-device text reading,
  which comes with capture, and reads nothing. The importer is complete and tested against fakes; m3-02 passes its
  OCR, masker and uploader-backed sink to `RecordingImporter` and the button works.
- **Known limits** (for review): when screen 11 shows the Desktop (where macOS saves recordings unless moved), macOS
  asks once for Desktop access at that moment, because the screen shows the folder's summary (ONBOARDING section 8);
  declining shows "No screen recordings found in Desktop", and Choose folder… still works. The import space is
  opened before the first file is read, so a run whose every new file fails or is in the future leaves an empty
  import space (listed in Settings, so it can be removed). The fingerprint includes the path, so a renamed recording
  is read again (as in PR #44). A frame that merely shows an excluded word or host gets no text. The menu bar entry's
  visibility is read when the menu is drawn. An excluded app recorded without its menu bar (a window-only recording)
  is "Screen" and is not excluded by app; host, title and private-window rules still apply to its text. The names of
  the Never watch apps (and of the built-in password and banking apps) are looked up when each import starts
  (`RecordingsImportModel.startImport`, `LiveAppNames.resolver(for:)`, wired in `RecordingsImportModel.live`), from
  the list as it is then; an app added during a running import is matched by bundle id only until the next import.
  Menu bars are read in English, German, French and Spanish; in other languages the app is "Screen" (not excluded by
  app, text rules still apply). Code lines in the slice may pass 120 columns; comments keep to 120.
- **Self-review**: an independent compile-blind read (Opus) of every file found one failing test (the fixed clock's
  epoch was Sat 21 Nov, not Thu 19 Nov, so the future-time file was not in the future); fixed. Its open risks: the
  AVFoundation calls used are deprecated on the macOS 15 SDK (warnings, not errors); the generated test video now
  uses BGRA buffers and an exact end. The first CI `mac` run is the real red-then-green check.

## Red tests (write these first, run them, see them fail)
Folder `apps/mac/Tests/OffloadMacTests/M305/`, Swift Testing, every test `@Test("TAG: ...")` inside
`@Suite struct M305` (tests in extensions of `M305` across files). Ported names keep the old name in the sentence.

| Tag | Tests (short) |
|---|---|
| NAMES | every `S34RecordingNameTests` case (macOSDefaultNameWithNarrowNoBreakSpace, plain space and PM, 24-hour and `(2)`, CleanShot and QuickTime exports, otherNamesHaveNoDate, candidatesAreVideosOnly / videosOnly); s34 `timestamps.test.ts` NAMES (screenshots, ISO-ish, compact, unix, impossible is nil); sample plan (every 5 s, short clip one frame, long clip 720 spread) |
| GATE | aFileIsReadyOnlyWhenItStoppedGrowing; an old modification time is ready at once; a recent one waits; empty never |
| LEDGER | aFileIsIngestedOnceAndTheLedgerHoldsNoNames (0600, folder 0700); fingerprintChangesWhenTheFileChanges; removing an import's entries lets its files be read again; memory ledger |
| FRAMES | a generated video gives frames with the long edge ≤ 1280 at the planned times (S34ExtractFrames); a missing or non-video file fails; an image file is read at ≤ 1280 |
| MENUBAR | app name is the words before the first menu; no File menu takes the first word; nothing in the band is nil; known apps map to bundle ids; unknown apps get a stable recording id |
| INGEST | idle_end, focus, text and idle_start brackets at recording time; same text is not repeated; keyframes throttled by recording time and change; keyframes off writes none; a recording's real start is kept (no rebasing); a future time is skipped |
| MASK | ocrTextIsMaskedBeforeItIsWritten; screenwatch titles masked and URLs reduced to host; text and title clipped to the contract limits |
| EXCLUDE | excludedAppsGetNoText; theUsersExclusionsApplyToRecordings (Never watch store through the adapter); an entry added during an import applies from the next file; built-ins (password managers, banking hosts, private windows) |
| APART | imports never mix with live data (every object `source: "import"` and the import's id; Offload's own data folder is refused, the sink is never opened; theCLIRefusesTheLiveHome re-stated); OffloadImport has no networking API; frames never reach the sink |
| SCREENWATCH | rows with app/window/url become masked focus events; rows without app fields get one synthetic screen app; the days/ folder works as the source; bad and duplicate rows |
| SCREENSHOTS | names give the time, else mtime; depth ≤ 3; nothing copied |
| FOLDER | suggested folder is where macOS saves recordings; scan picks videos oldest first; summary items `12 files`, `.mov`, `6 h 10 m`, `Nov 5 to 11` |
| REFUSE | an Offload home (or its days/ folder) is refused; EMPTY: nothing readable is no_recordings with its sentence; a missing folder |
| PROGRESS | started, reading file n of N, warning, finished; a file still being written waits for the gate; a file read once is skipped next time; a failing file does not stop the others |
| SINK | request bodies match API.md (`source_kind`; `scope: "import"`, `import_id`); observation JSON matches the m1-02 keys (snake case, no `url`, RFC 3339, ULID, hash); forget calls the sink and clears the ledger |
| SCREEN | screen 11 Import starts the import and goes to screen 12; not ready says so and stays; Choose folder… saves the folder; Settings shows the import (PILL: "Recordings from <folder>", the days); Remove imported data |
| COPY | copyNeverMentions…OrMiddleDots (renamed: the copy lint refuses the ADR 0016 term even in a test name); no em dash or banned word; progress lines in plain words |

## Out of scope
OCR, masker, perceptual hash, keyframe rendering, the sealed store and the uploader (m3-02); `services/**` (the server
half: `POST /v1/imports`, ingest of `source = "import"` objects that skip `too_old` with the ingest date as `day`,
forget scope `import`); the analysis anchored to an import's last day (cloud); `packages/contracts`; NOTICE (m3-03).

## Verify
`bash slices/m3-05-recordings-import/verify.sh`. On Linux it checks scope and prints
`m3-05-recordings-import: SKIPPED (needs macOS)`; with `REQUIRE_MAC=1` (CI `mac` job) a skip fails.

## Scope changes
- **Server half is a follow-up** (ROADMAP m3-05 lists `services/api/**` too): `POST /v1/imports` / `GET /v1/imports`,
  ingest accepting `source = "import"` with an open `import_id` past `too_old` and `day` = ingest date (ADR 0020), and
  `POST /v1/me/forget` scope `import`, with the acceptance tests `IMPORT: forget import wipes every row with that
  import_id` and `IMPORT: an imported object older than 7 days is accepted and its day is the ingest date`. It needs
  W1-E's m1-02 contracts (PR #1) merged first. This slice ships the Swift `ImportSink` shaped to match and a local
  fake only.
- `model_tier: opus` (ROADMAP says Sonnet): this box has no Swift toolchain, so the code is written compile-blind and
  checked only in CI, as m3-04 was.
- **m3-04's `owns` is narrowed** (same worker, m3-04 still `in_progress`): `Shell/AppModel.swift`,
  `Onboarding/Services.swift`, `Onboarding/OnboardingModel.swift` and `Onboarding/OnboardingView.swift` become shared
  so this slice can hook screen 11 in; m3-04 keeps every other file of those folders. Its SPEC records the same.
- `apps/mac/**` is in m3-02's `owns`; m3-02 has not started (as m3-04 recorded). m3-02 plugs its OCR, masker,
  hasher, keyframe renderer and uploader into the protocols above.
- **MIGRATION 5.7 screenwatch and screenshots are kept** (the docs say port them; DATA_MODEL `imports.source_kind`
  lists `screenwatch`, `screenshots`, `videos`). A folder with videos and screenshots is one import of kind `videos`
  (there is no `mixed` kind). Screenwatch `.webp` screenshots are not read: rows give the focus, as 5.7 says.
- Dropped per MIGRATION 5.5 and 5.7: rebasing (`oldRecordingsAreRebasedIntoTheRetentionWindow`,
  `futureStampsAreRebasedToo`; a future time is skipped instead), the "Offload Import" home and `ingest-folder` /
  `extract-frames` CLIs (the S34ExtractFrames CLI and manifest tests go; the frame tests stay, in memory), captioning,
  `--max-usd`, resume of a captions cache, the JSONL `LINES` protocol (the import runs in the app, so progress is the
  typed `ImportProgress`; PROGRESS carries the three `PROGRESS:` cases), "Switch to live" (Today stays live; the
  import space is analysed in the cloud), and `ANCHOR` (cloud analysis, server follow-up). The `PILL` test is part of
  SCREEN.
- Screen 11's done line is "done · 1,284 moments read" without "9 things you repeat" until the cloud analysis of an
  import exists; ONBOARDING section 8 says so.
- NOTICE (m3-03's file): the import panel is written fresh after clicky's `MenuBarPanelManager.swift` KeyablePanel idea
  (a non-activating `NSPanel` that can become key, floating, on every Space); NOTICE's clicky entry should name
  `apps/mac/Sources/OffloadMac/Recordings/LiveRecordings.swift` (`KeyablePanel`, `LiveImportPanel`) as adapted from it.
- Tags are letters only (verify.sh counts `Test "[A-Z]+: ..."`), so MIGRATION's `OFFLOAD HOME` and `EMPTY` cases live
  under `REFUSE:`, and `PILL` under `SCREEN:`.
- Review 1 (logs/m3-05-recordings-import.review1.md), every finding fixed, red tests first (`fe90ab9`):
  1 no folder read at launch, scan off the main actor; 2 app names from pixels only with a real menu bar and only
  when the masker leaves them; 3 host, title and private-window rules matched on OCR lines; 4 offered only while
  sending, failing closed, menu entry and Settings' Import hidden otherwise; 5 screenshots streamed one at a time,
  `.reading` per file as it opens, `RecordingIngestor.ingestScreenshots` (which held a run in memory) removed; 6
  `isImporting` follows the phase; 7 tests for `openImport` failing, `forget` failing, the UserDefaults store,
  bundles, `node_modules` and the file cap (now a `scan` parameter); 8 the notice is drawn once (screen 11's body no
  longer repeats it); 9 the `no_recordings` sentence lists m4v and drops the file-system path, Settings' title is a
  header, each Remove button's label names its import, the panel announces its line; 10 this Contract records the
  `Window` scene; 11 `ImportKeyframeSink` says raw frames and lines must be masked before storing.
- `OnboardingState.recordingsImportStarted` stays unused: setting it needs a flow action in `OnboardingFlow.swift`,
  which m3-04 owns, and nothing reads the flag (the import record lives in `RecordingsImportModel.imports`). m3-04 can
  drop the flag and the comment at `OnboardingFlow.swift` "(.recordings, .importRecordings)" (review 1 finding 10).
- Review 2 (logs/m3-05-recordings-import.review2.md), red tests first (`e6f9ae8`):
  1 (major) `ImportExclusionRule` carries the app's display name for `bundle_id` rules; `NeverWatchImportExclusions`
  takes a name resolver (`LiveAppNames.resolver(for:)` in the app, NSWorkspace on the main actor, frozen into a
  Sendable table), and `isExcluded` matches the menu bar name case-insensitively. The built-in banking and
  authenticator apps are excluded by name too, and Photos and the banking apps are in the menu bar table. Window-only
  recordings are a known limit (above).
  2 Import advances to screen 12 only while still on screen 11.
  3 `refresh()` reads nothing while not offered, and the Settings window is left out of the Window menu
  (`.commandsRemoved()`); a window macOS restores at launch then reads no folder in Local mode.
  4 the review-1 `consumerID` guard is replaced by keeping the latest import's task (no clearing at all, so no race
  to test); tests now cover back-to-back imports, the redraw on every onboarding action, and Never watch changes
  inside one run of screenshots. The removal of Settings' second `.task` is view-only and has no test.
  5 a refusal is said once on screen 11 (its body), and Choose folder… clears the old line
  (`OnboardingModel.chooseRecordingsFolder`).
  6 `autoreleasepool` around every frame and screenshot read; VoiceOver hears the start, about every tenth of the
  files, warnings and the end (`announcement`, `announcements`).
  7 `ImportSink` says the uploader is the only egress for `openImport`, `write` and `forget` (ADR 0035).
  8 done gate: this slice stays `in_progress` until m3-03 adds the clicky credit for
  `Recordings/LiveRecordings.swift` to NOTICE (AGENTS Definition of done item 5) and the CI `mac` job has run M305.
- Review 3 (logs/m3-05-recordings-import.review3.md), red tests first (`1c73241`):
  1 (major) app names are looked up when each import starts: `RecordingsImportModel` takes the Never watch store
  and a `@MainActor` name lookup, builds `NeverWatchImportExclusions` with a frozen table from the list as it is at
  that moment, and passes it to `RecordingImporter.run(folder:exclusions:)`. `AppModel.live()` shares one
  `NeverWatchStore` between onboarding and the import. An app named on screen 9 after launch is excluded from the
  next import by its name.
  2 a `bundle_id` rule carries every name its app is shown by (`appNames`); `LiveAppNames` returns the localized
  `CFBundleName` first, then the display names and the file name; with a lookup, the built-in bundle ids are looked
  up too (Keychain Access reads "Schlüsselbundverwaltung" on a German Mac); German, French and Spanish menu titles.
  3 the refresh when the import becomes offered is `RecordingsImportModel.offerChanged()`, tested; the views call it
  from `onChange(of: isOffered)`.
  4 the adapter's comment is re-wrapped; no comment in the slice passes 120 columns.
- **Rebase onto main (2026-11-22, m3-03 merged)**: m3-03 made `OffloadMac` the executable target (product
  `Offload`, Sparkle linked, `@main` in `OffloadMac.swift` with `--self-check`). Main's `Package.swift` is kept as
  is, so the target `OffloadMacApp` and the `OffloadMac` library product are gone. The SwiftUI `App` moved from
  `Sources/OffloadMacApp/OffloadApp.swift` to `Sources/OffloadMac/App/OffloadApp.swift` (no `@main`); m3-03's entry
  answers `--self-check`, then `--version` (m3-09), then starts it. m3-03's placeholder AppKit menu became
  `App/AppUpdates.swift` (`UpdateMenu`: a line per permission lost in an update, then "Check for Updates…" or the
  status line, shown before Quit by `MenuBarContent`; tests `M304` `ShellUpdatesTests.swift`). `paths_in_scope` adds
  `apps/mac/Sources/OffloadMac/App/**` and keeps `apps/mac/Sources/OffloadMacApp/**` for the earlier commits.
