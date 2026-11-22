---
id: m3-05c-import-signals
title: Recordings import app cues for recordings without a menu bar, and start times from container creation dates or a stable per-file order
milestone: M3
status: in_progress
depends_on: [m3-05-recordings-import]
parallel_safe: true
human_gated: false
model_tier: opus
size: M
parallel_group: M3-C
owns: [apps/mac/Tests/OffloadMacTests/M305C/**, packages/contracts/rules/**, packages/contracts/src/app-cues.ts, packages/contracts/tests/m3-05c-import-signals/**]
verify: bash slices/m3-05c-import-signals/verify.sh
min_tests: 30
paths_in_scope: [apps/mac/Sources/OffloadImport/**, apps/mac/Tests/OffloadMacTests/M305C/**, packages/contracts/rules/**, packages/contracts/src/app-cues.ts, packages/contracts/tests/m3-05c-import-signals/**, docs/ARCHITECTURE.md, docs/ONBOARDING.md, docs/GLOSSARY.md, docs/ROADMAP.md, docs/DATA_MODEL.md, slices/m3-05c-import-signals/**]
paths_out_of_scope: [ee/**, services/**, apps/web/**, .github/**, docs/adr/**, NOTICE, apps/mac/Package.swift, apps/mac/Packaging/**, apps/mac/Sources/OffloadMac/**, apps/mac/Sources/OffloadUploader/**, apps/mac/Sources/OffloadObserver/**, apps/mac/Sources/OffloadMasker/**, apps/mac/Sources/OffloadStore/**, apps/mac/Tests/OffloadMacTests/M305/**, apps/mac/Tests/OffloadMacTests/M304/**, packages/contracts/src/index.ts, packages/contracts/schemas/**]
red_tests: [CUES, SIGNALS, TABLE, START]
---

# m3-05c-import-signals

## Summary
Item 3 of the "recordings in, fixes out" chain (owner, 2026-11-22), after the end-to-end run on stand-in data
(`/workspace/offload-e2e/REPORT.md`, stage 1 and "Where the chain stops" items 4 and 10). Two signals of the Mac
recordings import ([ARCHITECTURE section 1](../../docs/ARCHITECTURE.md#1-mac-client), "Recordings import";
[ONBOARDING section 8](../../docs/ONBOARDING.md#screen-11-recordings-optional)) were too weak to tell work apart:

1. **App.** The app name came only from a macOS menu bar. A window recording, an export or a full-screen app has none,
   so every frame became "Screen" (`recording.unknown`) and unrelated recordings fell into one bucket. This slice
   adds **app cues**: a pure, table-driven classifier that reads the window chrome (the top band of the frame) for a
   URL-bar host (`mail.google.com` → Gmail) or a known window title (`Gmail`, `QuickBooks`, `HubSpot`, `Slack`,
   `Excel`, `Google Sheets`, …). It is used only when the menu bar reader gives nothing.
2. **Start time.** A recording without a name time started at its modified time minus its length. Copied or synced
   files share one modified time, so all of them landed on the same minute. The start is now the container's
   creation date (AVFoundation metadata, behind a protocol), else the name's time, else the modified time minus
   the length with a **stable per-file order**: files whose times would overlap are laid end to end in
   (modified time, file name) order with a gap longer than the idle threshold.

The classifier's table is also published as JSON for the cloud (`packages/contracts/rules/app-cues.json`), so m5-01
can apply the same rules to masked text (decision below).

## Contract
- **No new dependency, no Package.swift change.** Swift uses Foundation and AVFoundation only (already linked by
  `OffloadImport`). TypeScript uses `zod` (already a dependency of `@offload/contracts`).
- **Additive only** in `apps/mac/Sources/OffloadImport/**`: every existing public type, initializer and signature
  keeps working (the app shell's builders call them).
- **`AppCues`** (new, `OffloadImport/AppCues.swift`):
  - `AppCueRule { id, appName, appBundleID, hosts: [String], titles: [String] }`; `AppCue { appName, appBundleID,
    host: String?, ruleID }`.
  - `AppCues.rules` (the table), `AppCues.browser` (`Browser`, `recording.browser`), `AppCues.notTLDs` (file
    extensions that are never a top-level domain), `AppCues.chromeFraction` 0.18 and `AppCues.chromeMinPixels` 96;
    `AppCues.chromeBandHeight(frameHeight:)` = max(96, 18 % of the frame height).
  - `AppCues.classify(_ lines: [OCRLine], frameHeight: Int, masker: any ImportTextMasker) -> AppCue?`. Only lines
    whose box starts inside the chrome band count. Order:
    1. **Host**: the first URL-bar host in reading order (top to bottom, then left to right). A host is a token of
       2 or more labels, each `[a-z0-9]` with inner `-`, last label letters only and not in `notTLDs`, the token
       holds no `@` (an email address is never a host); without a scheme it must already be lowercase (a URL bar's
       host is; "Okafor.Contract" is a name); a scheme, path, query and fragment are cut off. It is kept only when
       the masker leaves it unchanged, both as shown and lowercased. A host the table does not know must have a
       URL's shape: a scheme, a path, or a last label in `AppCues.tlds` ("amara.okafor" is not a host). The app is the table entry with the longest matching host pattern
       (`host` or `host/path-prefix`; a pattern matches the host itself or any subdomain; the path prefix is used
       for matching only and is never kept), else `Browser`.
    2. **Title**: else, a table title found as a whole word (case-insensitive, bounded by a non-letter, non-digit)
       on a chrome-band line. The topmost line wins, then the leftmost; on one line the longest title, then table
       order. No host is kept.
    3. Else nil (the app stays "Screen").
  - Names and bundle ids come only from the table, never from frame text; the only frame text a cue keeps is a host
    the masker left unchanged.
- **`RecordingIngestor`** (behaviour): when `MenuBarApp.name` gives nothing (or the masker would change it), the
  frame's app is the cue's app. A `focus` is written when the app name or the host changes, and carries the cue's
  host; a frame of the same app where no host was read (OCR missed the URL bar) keeps the span, unless the frame's
  exclusion state changed. A frame the exclusions exclude keeps a `focus` with the app name only (no host), and no text or keyframe, as
  before. The menu bar band is still left out of the body text.
- **Start times** (new, `OffloadImport/RecordingStart.swift`):
  - `protocol RecordingCreationDates: Sendable { func creationDate(of url: URL) -> Date? }`;
    `NoRecordingCreationDates` (always nil, the default) and `AVRecordingCreationDates` (`AVURLAsset.creationDate`,
    its date value, else its ISO 8601 string).
  - `RecordingStartSource`: `container_creation`, `name`, `modified_ordered`. `RecordingTimes { name, created,
    nameDate, modified, duration }`; `RecordingStart { start, source }`.
  - `RecordingStartTime.plan(_ files: [RecordingTimes], now: Date, futureSlack: TimeInterval = 600,
    gap: TimeInterval = RecordingStartTime.sharedTimeGap) -> [RecordingStart?]` (same order as the input; nil = the
    file would end more than `futureSlack` in the future and is skipped). `sharedTimeGap` = 180 s (longer than the
    120 s idle threshold, so each recording is its own span).
    1. `container_creation`: the creation date, when it is between 2000-01-01 and 2100-01-01 (QuickTime's zero date
       1904 and the Unix zero are not times) and the recording would not end in the future.
    2. `name`: else the name's time (`RecordingName.date(fromName:)`), on the same future rule.
    3. `modified_ordered`: else, over all files of this kind in the run, sorted by (modified time, file path), from
       the last: end = min(modified, next start − gap), start = end − duration; then, while the span comes within
       `gap` of an `occupied` span (a video of the same folder read in an earlier import, at its ledger start and
       its length), end = that span's start − gap. A file whose modified time is far
       from the others keeps modified minus duration; files sharing a modified time are laid end to end, the
       name-order last one ending at the modified time. An unknown duration counts as 0.
  - `RecordingImporter.Readers` gains `creationDates: any RecordingCreationDates` (default
    `NoRecordingCreationDates()`) and `duration: (@Sendable (URL) -> TimeInterval?)?` (default nil, or nil for a file: the importer
    opens the video to read its length). `Readers.live` uses `AVRecordingCreationDates()` and
    `AVRecordingFrameSource.duration(of:)`. The two-argument initializer keeps working.
  - `RecordingImporter.run` plans every new video's start before reading (after the import space is open) and reads
    each video at its planned start; a video with no usable start is skipped with the existing `futureTime` warning.
    Screenshots and screenwatch rows keep their times as before.
- **JSON table for the cloud** (new): `packages/contracts/rules/app-cues.json`
  `{ version: 1, about, chrome_band: { fraction, min_px }, browser: { app_name, app_bundle_id }, not_tlds: [...],
  tlds: [...], apps: [{ id, app_name, app_bundle_id, hosts, titles }] }`, and `packages/contracts/src/app-cues.ts` with the zod
  schema `AppCueTable` and `appCueTable` (the parsed file). Not exported from `src/index.ts` (other chain slices
  edit that file); import it as `@offload/contracts/src/app-cues.ts`. The Swift table must equal the JSON (TABLE
  test reads the file from the repo).

## Design note
- **Where the classifier runs**: on the Mac, inside the existing ingest path, on raw OCR lines in memory, like
  `MenuBarApp`. Its outputs are table constants plus at most a host that passed the masker unchanged, so no
  unmasked text leaves (review 1 finding 2 of m3-05 still holds: window text never becomes `app_name`).
- **Why the window chrome band only**: a body line that mentions "Slack" or `acme.com` is content, not the app in
  front. 18 % of the height (at least 96 px) covers a title bar, a tab strip and a toolbar with the URL bar on a
  1280 px frame; the menu bar band (4 %) is inside it, which is fine because the cue is read only when that band was
  not a menu bar.
- **Host before title**: the URL bar shows the active tab, while a tab strip shows every tab's title, so a host is
  the stronger cue. Unknown hosts give `Browser` plus the host, so two different sites stay apart.
- **Excel, Slack, Outlook keep their native bundle ids** (`com.microsoft.Excel`, `com.tinyspeck.slackmacgap`, ...)
  so a window recording and a menu-bar recording of the same app give the same app key. Web-only apps get
  `web.<id>` (`web.gmail`, `web.quickbooks`, `web.hubspot`, `web.google-sheets`).
- **Start time order** follows the brief: container creation date, then name, then the ordered modified time. The
  per-file order is a pure function of the run's files, so the same folder gives the same times. The gap is longer
  than the idle threshold so the sessionizer does not join unrelated copied recordings into one span.
- **Decision: m5-01 should reuse the table (recorded here, not built here).** Imports read before this slice, rows
  from older Mac builds and screenwatch archives still say "Screen", and the cloud sees only masked text. m5-01 may
  load `appCueTable` and apply the host patterns to `focus.host` and to hosts in the masked `observation_texts`, and
  the titles to the first lines of a text snapshot, when `app_bundle_id` is `recording.unknown` or
  `screenwatch.screen`. The rules are one file, so both sides drift together; `services/**` is not edited here.
- **Known limits**: a tab strip that names several table apps and shows no URL bar picks the topmost, leftmost
  title; a document titled with an app's name in a window recording takes that app; a recording whose creation date
  is its end rather than its start is shifted by its length; screenshots sharing a modified time are not reordered
  (they are single moments, not spans).

## Red tests (write these first, run them, see them fail)
Swift: folder `apps/mac/Tests/OffloadMacTests/M305C/` (the test target's path is `Tests/OffloadMacTests`, so a new
folder needs no Package.swift change), `@Suite struct M305C`, every test `@Test("TAG: ...")`. It reuses the M305
fakes (`FakeMasker`, `FakeRecording`, `M305Files`, `M305Importer`). TypeScript: `packages/contracts/tests/m3-05c-import-signals/`.

| Tag | Tests (short) |
|---|---|
| CUES | a URL-bar host names a known web app (Gmail, Google Sheets by path, QuickBooks, HubSpot); an unknown host is Browser with the host; window titles name the app (Gmail, QuickBooks, HubSpot, Slack, Excel, Google Sheets); a host wins over a title, the topmost title wins; body lines are not cues; email domains, file names and numbers are not hosts; a host the masker would change is dropped and names come from the table only; no cue is nil |
| SIGNALS | a window recording gets app and host from the chrome, one focus per change; the menu bar wins; an excluded host keeps the focus without host, text or keyframe; nothing unmasked leaves in any focus field; two unrelated window recordings get different app keys; a missed URL bar does not split the span (self-review) |
| TABLE | Swift: the table equals `packages/contracts/rules/app-cues.json`. TS: the JSON parses with `AppCueTable`; hosts are bare lowercase hosts with an optional path prefix; ids and titles are unique; bundle ids and names fit the observation contract |
| START | creation date first; name next; QuickTime zero, pre-2000 and future creation dates are ignored; files sharing a modified time are laid end to end in name order with the gap; the plan does not depend on input order; far-apart files keep modified minus length; a future file is nil; the importer uses the injected creation date; three copied recordings with one modified time do not overlap after import |

## Out of scope
`services/**` (m5-01 applies the table in the cloud); `apps/mac/Sources/OffloadMac/**` and the uploader; OCR, the
masker and the hasher (m3-02); exporting `app-cues.ts` from the contracts index; JSON Schema generation for the
table (it is a rules file, not a wire shape); app cues for frames that have a menu bar (a browser's host when the
menu bar says "Google Chrome").

## Verify
`bash slices/m3-05c-import-signals/verify.sh`: scope (commits whose subject starts with `m3-05c-import-signals: `,
plus uncommitted changes) and the TypeScript TABLE tests on every platform; on macOS with Swift 6 (CI job `mac`) also
`swift build`, the `M305C` suite (≥ `min_tests` passed, every tag passing) and the full `swift test`. On Linux the
Swift part prints SKIPPED; `REQUIRE_MAC=1` turns that into a failure.

## Scope changes
- `depends_on: [m3-05-recordings-import]`, which is still `in_progress`: its code is on `main` (W1-H), and this slice
  only adds to it. m3-05 `owns` `apps/mac/Sources/OffloadImport/**`; the chain brief allows m3-05c additive changes
  there, so this slice does not own it and keeps every public signature.
- `model_tier: opus`: no Swift toolchain on this box; the Swift is written compile-blind and checked in CI, as m3-04
  and m3-05 were.
- The JSON table lives under `packages/contracts/rules/` (a new folder) and its zod schema in
  `packages/contracts/src/app-cues.ts`, not in `src/index.ts` and not in `schemas/` (both shared with other slices).

- The TS TABLE red test imported `@offload/contracts/src/app-cues.ts` by the package's own name, which a package
  cannot resolve from inside itself; it uses the relative path now (assertions unchanged). Other packages (m5-01)
  import `@offload/contracts/src/app-cues.ts` (checked from `services/brain`).
- Self-review added one SIGNALS test (a missed URL bar must not split a span), red first, then the fix.
- Review 1 (independent Opus read of the diff, VERDICT: CHANGES), red tests first (`d10c0ae`), every finding fixed:
  1 (high) dotted names in a title line ("Okafor.Contract", "amara.okafor", "plan.psd") were read as hosts and
  could leave in `focus.host`: a host without a scheme must be lowercase as shown, the masker sees it as shown and
  lowercased, and an unknown host needs a scheme, a path or a known top-level domain (`tlds`, new in the JSON);
  2 (medium) the order was per run, so a copy imported later landed on an earlier import's span: the planner keeps
  clear of the folder's already-imported videos (ledger start plus length); 3 (low) an unknown length was planned as
  0: the importer opens the video to read it; 4 (low) the QuickTime creation date is read before the common key;
  5 (nit) the order key is the file path (SPEC wording fixed); 6 (nit, accepted) the longest title wins on a line.

## Verification without a Mac
This box has no macOS. The Swift was checked two ways before CI:
- A throwaway Linux harness (outside the repo) compiled every `OffloadImport` file except `FrameReaders.swift` with
  the Swift 6.1.2 Linux toolchain in Swift 6 language mode, with stubs for `CGImage`, `autoreleasepool` and CryptoKit
  and the AVFoundation parts of `RecordingStart.swift` and `Readers.live` replaced. It ran every M305C test except
  the one that writes a real `.mov` (29 of 30) plus the 64 existing M305 tests that need no UI or AVFoundation
  (ingest, importer, names, ledger and sink): 93 passed. Mutating the ingestor's cue call or the importer's planned
  start made the SIGNALS and START tests fail.
- `AVRecordingCreationDates` and the START test with a generated `.mov` are compile-blind: the CI `mac` job is the
  first real check.

## Progress
- [x] SPEC, verify.sh, ROADMAP row (`3e6385f`)
- [x] red tests (Swift M305C, TS TABLE) (`19db9cc`)
- [x] JSON table + TS schema (`faec8b8`); AppCues + ingestor wiring (`af9d316`)
- [x] start time planner + importer wiring (`f4dd3a0`)
- [x] docs (ARCHITECTURE, ONBOARDING, GLOSSARY, DATA_MODEL) (`5cefa6c`)
- [x] self-review fix: missed URL bar keeps the span (red `m3-05c-import-signals: red test`, green `2cc53d7`)
- [x] independent review 1 and its fixes (`d10c0ae` red, then green)
- [x] verify.sh (Linux: scope + TS TABLE, Swift SKIPPED) and `SLICE_UPSTREAM=<merge-base> scripts/verify-all.sh` green
- [ ] CI `mac` job runs M305C (30 tests); status stays `in_progress` until it has
