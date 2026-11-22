---
id: m3-10-mac-recordings-analysis
title: Recordings read and analysed on this Mac (Vision OCR, interim masker, local import sink, local insights with things you repeat), default recordings folders, the navigation shell, backend mode and the brain and builds clients
milestone: M3
status: in_progress
depends_on: [m3-04-mac-onboarding, m3-05-recordings-import]
parallel_safe: false
human_gated: true
model_tier: opus
size: L
parallel_group: M3-D
owns: [apps/mac/Sources/OffloadMac/Analysis/**, apps/mac/Sources/OffloadMac/OnDevice/**, apps/mac/Sources/OffloadMac/Backend/**, apps/mac/Sources/OffloadMac/Navigation/**, apps/mac/Tests/OffloadMacTests/M310/**]
verify: bash slices/m3-10-mac-recordings-analysis/verify.sh
min_tests: 95
paths_in_scope: [apps/mac/Sources/OffloadMac/Analysis/**, apps/mac/Sources/OffloadMac/OnDevice/**, apps/mac/Sources/OffloadMac/Backend/**, apps/mac/Sources/OffloadMac/Navigation/**, apps/mac/Sources/OffloadMac/TodayLive/TodayLiveScreen.swift, apps/mac/Sources/OffloadMac/WeeklyReview/WeeklyReviewScreen.swift, apps/mac/Sources/OffloadMac/WeeklyReview/WeeklyReviewSettings.swift, apps/mac/Sources/OffloadMac/BuildProgress/BuildProgressScreen.swift, apps/mac/Sources/OffloadMac/Shell/AppModel.swift, apps/mac/Sources/OffloadMac/App/**, apps/mac/Sources/OffloadMacApp/**, apps/mac/Tests/OffloadMacTests/M310/**, apps/mac/README.md, docs/ARCHITECTURE.md, docs/GLOSSARY.md, docs/ONBOARDING.md, docs/SECURITY_PRIVACY.md, docs/adr/**, slices/m3-10-mac-recordings-analysis/**]
paths_out_of_scope: [ee/**, services/**, packages/**, apps/web/**, .github/**, NOTICE, apps/mac/Package.swift, apps/mac/Packaging/**, apps/mac/TestBuild/**, apps/mac/Sources/OffloadMac/OffloadMac.swift, apps/mac/Sources/OffloadMac/Updates/**, apps/mac/Sources/OffloadMac/SelfCheck/**, apps/mac/Sources/OffloadMac/Version/**, apps/mac/Sources/OffloadObserver/**, apps/mac/Sources/OffloadMasker/**, apps/mac/Sources/OffloadStore/**, apps/mac/Sources/OffloadUploader/**, apps/mac/Sources/OffloadImport/**, apps/mac/Sources/OffloadMac/Recordings/**, apps/mac/Sources/OffloadMac/Today/**, apps/mac/Sources/OffloadMac/Onboarding/**, apps/mac/Sources/OffloadMac/Permissions/**, apps/mac/Sources/OffloadMac/LocalNow/**, apps/mac/Sources/OffloadMac/NeverWatch/**, apps/mac/Sources/OffloadMac/Design/**, apps/mac/Sources/OffloadMac/Shell/Launch.swift, apps/mac/Sources/OffloadMac/Shell/AppMover.swift, apps/mac/Sources/OffloadMac/Shell/MenuBar.swift, apps/mac/Sources/OffloadMac/Shell/RootView.swift, apps/mac/Sources/OffloadMac/Shell/LiveServices.swift, apps/mac/Tests/OffloadMacTests/SmokeTests.swift, apps/mac/Tests/OffloadMacTests/M304/**, apps/mac/Tests/OffloadMacTests/M305/**, apps/mac/Tests/OffloadMacTests/M309/**]
red_tests: [OCR, MASK, SINK, WIRING, FOLDERS, INSIGHTS, SESSIONS, REPEAT, RANK, ANSWERS, INCREMENTAL, EXCLUDE, PROGRESS, NAV, BACKEND, BRAIN, BUILDS, HOST, SAMPLE, NONET, COPY]
---

# m3-10-mac-recordings-analysis

## Summary
The owner's goal for the test build (2026-11-22): pick a recordings folder, and Offload reads it **and analyses it on
this Mac**. Today m3-05's importer is complete but unwired (`AppModel.live()` passes `importer: nil`, because there is
no on-device OCR or masker until m3-02, PR #13, lands), and nothing analyses what an import read. This slice makes it
real in the test build: a Vision `TextRecognizer`, an interim on-device masker behind m3-05's `ImportTextMasker`, a
local `ImportSink` that keeps masked observations on this Mac only, and **local insights**: a deterministic engine
that counts active time per day and per app, sessions, top apps and sites (host only) and the **things you repeat**
(multi-step app and title-shape sequences repeated across days) with minutes per week computed by code
([ADR 0003](../../docs/adr/0003-numbers-come-from-code.md)), a confidence label and evidence counts.

It also lays the ground the three screen slices build on, so m3-11, m3-12 and m3-13 only edit their own folders: the
navigation shell (sidebar with Today, Weekly review, Builds, Recordings, Settings, each later screen a placeholder
owned by its slice), **backend mode** (`.local` by default, `.cloud` only with an API base URL and a member token),
small `BrainClient` and `BuildsClient` shaped exactly like the brain ([API.md "Today, records and review"](../../docs/API.md#today-records-and-review-core-m5-unless-noted),
port branch `port/brain-user-model`) and builds APIs ([API.md "Opportunities, fixes and builds"](../../docs/API.md#opportunities-fixes-and-builds-core),
port branch `port/build-loop`), and the rule for the **Sample data** label.

Implements [ARCHITECTURE section 1](../../docs/ARCHITECTURE.md#1-mac-client) "Recordings import" end to end on the
Mac and [ONBOARDING screen 11](../../docs/ONBOARDING.md#screen-11-recordings-optional) "done · 1,284 moments read ·
9 things you repeat". `human_gated: true`: reading the owner's real `~/screenwatch` and `.mov` folders needs the owner
on a Mac with the m3-09 test build.

## Contract
- **No new dependency, no Package.swift change.** Everything lives in the `OffloadMac` library target in four new
  folders. System frameworks only: Foundation, CoreGraphics, CoreText (tests render text), Vision, CryptoKit, SwiftUI,
  AppKit. `OffloadImport` (m3-05) is used through its public API only and is not edited.
- **`OnDevice/`** (no networking API, test enforced):
  - `VisionTextRecognizer: TextRecognizer` (m3-05's protocol): `VNRecognizeTextRequest`, `recognitionLevel =
    .accurate`, `usesLanguageCorrection = true`, `recognitionLanguages = ["en-US", "de-DE", "fr-FR", "es-ES"]` (the
    menu bar languages m3-05 reads), `revision` left at the SDK default; runs `VNImageRequestHandler(cgImage:)`
    synchronously on the caller's (detached) task; a frame with `image == nil` returns `[]`. Each observation's top
    candidate becomes an `OCRLine` with `OCRLine(text:box:)`; boxes go through the pure
    `VisionBoxes.topLeft(_ normalized: CGRect, width: Int, height: Int) -> OCRBox` (Vision's origin is bottom left,
    normalized; `OCRBox` is top left, pixels: `x = minX·W`, `y = (1 − maxY)·H`, `width = w·W`, `height = h·H`). Lines
    are returned top to bottom, then left to right. Nothing is kept.
  - `InterimTextMasker: ImportTextMasker`, **interim**, clearly named, to be replaced by m3-02's
    `OffloadMasker.TextMasker` when PR #13 lands (see Scope changes). Order, each case test-driven:
    1. URLs `scheme://host/path?query#fragment` keep the host, the path becomes `<doc:h_…>`, query and fragment are
       dropped (`https://host/<doc:h_…>`, or `https://host` with no path); bare `host.tld/path` the same.
    2. Tokens become `[SECRET]`: `sk-`/`sk-ant-` keys, `ghp_`/`gho_`/`github_pat_`, `xox[abpr]-`, `AKIA` + 16,
       JWTs (three base64url parts joined by dots, starting `eyJ`), `-----BEGIN … PRIVATE KEY-----` blocks, and any run of 32 or more characters of
       `[A-Za-z0-9_+/=-]` that mixes letters and digits.
    3. Card-like numbers: 13 to 19 digits with optional single spaces or dashes that pass Luhn become `[CARD NO.]`.
    4. Long digit runs: 8 or more digits (spaces or dashes allowed inside) become `[ACCT NO.]`; a standalone 6 or 7
       digit run becomes `[OTP]`. Times, dates and amounts with separators (`4:00`, `2026-11-22`, `1,284`) stay.
    5. Emails become `<email:h_…>`; phone numbers (E.164 `+` and 8 to 15 digits, or national forms with 10 digits
       and separators) become `<phone:h_…>`.
    Pseudonyms use the glossary format: first 16 hex of HMAC-SHA256 over the normalised value (email and doc
    lowercased, phone digits only) under a **local pseudonym key** (`LocalPseudonymKey`: 32 random bytes in
    `Application Support/Offload/OnDevice/pseudonym.key`, file 0600, folder 0700, created once; tests inject a fixed
    key). Output is truncated to 8000 characters after masking. The labels match `OffloadMasker.MaskCategory` so the
    swap changes no stored shape.
  - `LocalImportSink: ImportSink` (m3-05's protocol), the on-device sink: `openImport` makes a local import id (uuid,
    lowercased) and an empty file; `write` appends `StoredObservation` lines (`id`, `ts` RFC 3339, `kind`,
    `import_id`, `app_bundle_id`, `app_name`, `title`, `host`, `text_hash`): **the masked text itself is not kept**
    (insights need only that text changed), no pixels, no file names or paths; `forget` deletes the import's file. A
    write to a space it did not open throws `UnknownImportSpace`. Files live in
    `Application Support/Offload/OnDevice/imports/<import_id>.jsonl` (folder 0700, files 0600, written with
    `.completeFileProtectionUntilFirstUserAuthentication` since review 1, excluded from backups). It sends nothing (it is not the uploader); see Design note.
  - `LocalObservationStore` reads every stored import back as `InsightEvent`s (`events(in: DateInterval)`,
    `importIDs()`), skipping lines it cannot decode.
  - `DefaultRecordingFolders.candidates(home:screencaptureLocation:exists:) -> [RecordingFolderCandidate]`, in this
    order, only those that exist: `~/screenwatch` (kind `screenwatch` when it holds `days/`), the `screencapture`
    `location` (macOS Screen Recording and Screenshot), `~/Desktop` (where macOS saves recordings unless moved),
    `~/Movies` (QuickTime). `preferred` is the first candidate; Offload's own data folder is never a candidate.
    Existence is checked with `FileManager.fileExists` only (no folder is listed before the screen appears, as m3-05
    rules).
  - `OnDeviceRecordings.make(neverWatch:store:folders:)` builds m3-05's `RecordingsImportModel` through its public
    init with a real `RecordingImporter` (`VisionTextRecognizer`, `InterimTextMasker`, no hasher, keyframes off,
    `LocalImportSink`, `FileRecordingLedger` in `Application Support/Offload/OnDevice/ledger.json`), the
    `DefaultRecordingFolders.preferred` folder when none was chosen, and `AnalysedImportPanel` (an
    `ImportPanelPresenter` that shows m3-05's `ImportPanelView` plus the local insights done line).
- **`Analysis/`** (pure, no networking API, test enforced):
  - `InsightEvent` (`id`, `ts`, `kind` `focus` `idle_start` `idle_end` `text_snapshot` `pause` `resume`,
    `appBundleID`, `appName`, `title`, `host`, `origin` `.live` or `.imported(importID)`), adapters from
    `StoredObservation` and from m3-04's `LocalEvent` (`LocalEventInsightSource` over any `LocalEventSource`, so live
    capture feeds the same engine once m3-02 fills the source).
  - `Figure` (`id`, `value`, `unit`, `arithmetic`, `evidence: [EvidenceRef]`, `sourcePurgedAt`), the API.md shape,
    Codable with the snake case keys; local figures use evidence kind `observation` with local ids and `id` = `fig_` +
    first 16 hex of SHA-256 over the JCS of the figure without `id` (API.md section 1).
  - `LocalInsights.day(_:day:timeZone:exclusions:) -> DayInsights`: active seconds, per-app seconds, sessions, top
    apps (top 5 by seconds), top sites (host only, top 5), switches, focus blocks, longest focus, each a `Figure`.
  - `LocalInsights.repeats(days:now:timeZone:adjustments:goals:) -> [RepeatPattern]`: the things you repeat, ranked.
  - `RankingAdjustments` built from `LocalAnswerStore` (the weekly review answers on this Mac, m3-12 writes them
    through it): per subject key the latest `answer` (`keep`, `not_now`, `build`, `never`, `leave_alone`,
    `other_goal`, the brain's enum), `goal_id`, `answered_at` and the minutes per week at answer time.
  - `LocalAnswerStore` protocol, `FileLocalAnswerStore` (`Application Support/Offload/OnDevice/answers.json`, 0600,
    atomic) and `MemoryLocalAnswerStore`. Latest answer per `(iso_week, subject_key)` wins, as DATA_MODEL
    `review_answers`.
  - `InsightsStore` (an actor): caches `DayInsights` per day, `recompute(days:)`, `refreshAll()`, `snapshot()` →
    `InsightsSnapshot` (days, repeats, `observedDays`, `lastUpdated`); `@MainActor InsightsModel` publishes snapshots
    and `isAnalysing` for the screens.
  - `InsightsCoordinator`: observes m3-05's `RecordingsImportModel.phase` and `imports`; on `.done(report)` it
    recomputes the days from `report.firstDay` to `report.lastDay`; when an import is removed it recomputes that
    import's days; at launch it runs `refreshAll()` off the main actor.
- **`Backend/`**:
  - `BackendMode` `.local` (default) or `.cloud(BackendConfig)`; `BackendMode.resolve(baseURL:tokens:)` is `.cloud`
    only when an `https` API base URL is configured (`UserDefaults` key `ai.offload.api.baseURL`) **and**
    `MemberTokenProvider.currentToken()` returns a token; otherwise `.local`. No token exists until enrollment
    (m1-04, m3-02), so the test build is `.local`.
  - `HTTPTransport` protocol (`send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)`),
    `URLSessionTransport` (ephemeral session, no cookies, no cache). Tests use `RecordingTransport` and never touch
    the network.
  - `APIClientCore`: builds every request from the configured base URL only (a path that would resolve to another
    host is refused before sending), adds `Authorization: Bearer <member token>`, `Accept: application/json`,
    `Content-Type: application/json; charset=utf-8` on bodies, `Idempotency-Key` (ULID) on creating POSTs; decodes the
    error envelope `{ error: { code, message, request_id, rule_id? } }` into `APIError` with the closed code list of
    API.md section 1 (unknown codes become `.other(code)`).
  - `RequestSigner` protocol (`signature(for body: Data) throws -> String`, the `Offload-Signature: keyid=<device_id>,
    sig=<base64url r‖s>` value) for Mac approvals; nil signer means approvals are refused locally with
    `APIError.signingUnavailable` (the device key comes with enrollment). `JCS.encode` for the small flat bodies the
    Mac posts: keys sorted, no whitespace, integers without a fraction, strings with JSON escapes only.
  - `BrainClient` protocol and `HTTPBrainClient`, exactly the brain port's routes and shapes:
    `profile()` `GET /v1/profile` → `BrainProfile`; `updateProfile(_:)` `PATCH /v1/profile` (only `role`,
    `industry`, `goals`, `drains`, `schedule`, `timezone`, `review_slot`, `autonomy`, `own_name_to_models`,
    `keyframes_to_cloud`); `dayRecord(day:)` `GET /v1/records/days/{date}` → `DayRecord` (`day`, `generated_at`,
    `totals` {`active_minutes`, `switches`, `switches_per_active_hour`, `focus_blocks`, `focus_minutes`,
    `meeting_minutes`}, `by_kind`, `by_app`, `by_task` {`task_key`, `name`, `minutes`, `instances`,
    `median_minutes`}, `episode_ids`, `source_purged_at`); `weekRecord(isoWeek:)` `GET /v1/records/weeks/{iso_week}`
    → `WeekRecord` (`iso_week`, `from`, `to`, `days_recorded`, `hours` {`total`, `by_kind`, `by_app`}, `focus`
    {`blocks`, `minutes`, `switches_per_active_hour`, `meeting_hours`}, `tasks` [`WeekTask`: `task_key`, `name`,
    `minutes`, `instances`, `median_minutes`, `baseline_minutes`, `vs_baseline`, `status` `new` `recurring` `gone`],
    `fixes` {`estimated`, `measured`}, `weeks_observed`, `narrative`, `generated_at`); `weekReview(isoWeek:)`
    `GET /v1/review/week?w=YYYY-Www` → `WeekReview` (`iso_week`, `sentence`, `tiles` (4 Figures), `goals` [{`id`,
    `text`}], `questions` [{`subject_key`, `question_kind` `opportunity`, `name`, `answers`, `answered`}]);
    `answer(_:)` `POST /v1/review/answers` body exactly `{ iso_week, subject_key, question_kind, answer, goal_id? }`
    → `ReviewAnswer` (`iso_week`, `subject_key`, `question_kind`, `answer`, `goal_id`, `answered_at`). A 404 on a
    record or review is `.notFound` (a future week), not an error screen.
  - `BuildsClient` protocol and `HTTPBuildsClient`, exactly API.md and the build-loop port: `openOpportunities()`
    `GET /v1/opportunities?state=open` → `[Opportunity]`; `answerOpportunity(id:answer:optionID:)`
    `POST /v1/opportunities/{id}/answer` `{ answer, option_id? }`; `fix(id:)` `GET /v1/fixes/{id}` → `Fix` (`brief`,
    `brief_hash`, `check_set_hash`, `held_out_hash`, `fixture_set_hash`, `estimate`, `cap_usd`); `okBuild(fixID:hashes:)`
    `POST /v1/fixes/{id}/build-approvals` body `{ brief_hash, check_set_hash, held_out_hash, fixture_set_hash,
    cap_usd: 4 }`, signed, → 202 `{ build_id }`; `build(id:)` `GET /v1/builds/{id}` → `Build` (`id`, `state`
    `queued` `building` `verifying` `fanning_out` `repairing` `ready` `failed` `capped` `tampered` `cancelled`
    `infra_failed`, `cap_usd`, `spent_usd` (USD numbers), `fanout_workers`, `stages` [{`name`, `state` `running`
    `done` `failed`, `started_at`, `ended_at`, `note`}], `attempts` [{`id`, `ordinal`, `outcome` `running` `pass`
    `fail` `cap` `tamper` `error`, `spent_usd`, `tries`, `turns`, `frozen_pass`, `held_out_pass`, `check_groups`
    [{`name` `frozen` `held_out`, `passed`, `failed`}], `artifact_sha256`, `artifact_bytes`, `artifact_files`,
    `note`}], `winner_attempt_id`, `artifact_sha256`, `receipt_hash`, `definition_hash`, `deployed`, `started_at`,
    `ended_at`); `cancel(id:)` `POST /v1/builds/{id}/cancel`; `definition(id:)` `GET /v1/builds/{id}/definition` →
    `{ definition, definition_hash, words }`; `deploy(id:hashes:)` `POST /v1/builds/{id}/deploy` body `{
    artifact_sha256, receipt_hash, definition_hash }`, signed, → 201 `{ routine_id, version }`; `outcomes(month:)`
    `GET /v1/outcomes?month=YYYY-MM` → `[FixOutcome]`. Unknown fields are ignored; unknown enum values decode to
    `.unknown(raw)` and are shown as such, never mapped to success.
  - `Backends` (what the screens get): `mode`, `brain: (any BrainClient)?`, `builds: (any BuildsClient)?`,
    `provenance` (`.onDevice` in `.local`, `.cloud` in `.cloud`). In `.local` both clients are nil, so no request can
    be built.
- **`Navigation/`**:
  - `Screen` enum, sidebar order: `today` "Today", `weeklyReview` "Weekly review", `builds` "Builds", `recordings`
    "Recordings", `settings` "Settings". `NavigationModel` (@MainActor): `selection`, `pendingBuild: BuildRequest?`,
    `startBuild(_:)` (sets the request and selects Builds). `BuildRequest`: `.localRepeat(key:name:minutesPerWeek:)`
    or `.opportunity(id:optionID:)`, the hand-off from Today and Weekly review to Build progress.
  - `AppWindowView(app:)`: while `app.route == .today` it shows `ShellView` (a `NavigationSplitView` with the sidebar
    and the selected screen), otherwise m3-04's `MainWindowView` (onboarding, move, Start fresh), so onboarding is
    unchanged. `ShellView` presents the Never watch sheet itself (the menu bar entry works on every screen).
  - Screens: `TodayLiveScreen(app:)` (placeholder in `TodayLive/`, shows m3-04's `TodayView` as today; m3-11 owns it),
    `WeeklyReviewScreen(app:)` and `WeeklyReviewSettings(app:)` (placeholders in `WeeklyReview/`; m3-12 owns them),
    `BuildProgressScreen(app:)` (placeholder in `BuildProgress/`; m3-13 owns it), `RecordingsShellScreen(app:)` (m3-05's
    `RecordingsSettingsView`, the default folder candidates and the local insights done line) and
    `SettingsScreen(app:)` (backend mode in words, the Recordings section, `WeeklyReviewSettings`).
  - `DataProvenance` and `SampleDataLabel`: a screen whose data is `.sample` shows the label **"Sample data: cloud
    not connected"** at the top of its content, always visible (not only on hover) and announced first by
    VoiceOver; `.onDevice` shows the caption "counted on this Mac"; `.cloud` shows nothing extra. Sample data is only
    ever built behind `BackendMode.local` and never mixed into on-device or cloud figures.
- **Hooks** (shared files, additive only):
  - `Shell/AppModel.swift`: three stored properties with defaulted init parameters so m3-04's and m3-05's tests
    compile unchanged: `navigation: NavigationModel`, `backends: Backends` (default `.local`), `insights:
    InsightsModel`. `AppModel.live()` builds the recordings model with `OnDeviceRecordings.make` instead of
    `RecordingsImportModel.live`, starts the `InsightsCoordinator`, and sets the recordings model's `offerCheck` to
    "backend mode is `.local`, or signed in and sending" (see Design note).
  - `App/OffloadApp.swift` (`OffloadMacApp/OffloadApp.swift` before the 2026-11-22 rebase): the main window shows
    `AppWindowView(app:)`; the menu bar "Recordings…" entry follows the same `isOffered`.

## Design note
- **Why the import is offered in Local mode now.** ONBOARDING section 8 hides the import until "Start sending"
  because, in the cloud design, an import uploads. In `.local` backend mode the sink is `LocalImportSink`: nothing
  leaves the Mac, the same as the local now summary, so the consent gate it protected does not apply. In `.cloud`
  mode the rule stays exactly as m3-05 built it (signed in and sending). Onboarding still skips screens 5 to 12 in
  Local mode (m3-04's flow is not changed), so a Local-mode person imports from the Recordings screen, Settings or
  the menu bar "Recordings…". ONBOARDING section 8 is updated in this slice.
- **Structure**: value types and pure functions in `Analysis/` carry every rule; `InsightsStore` is an actor;
  `InsightsModel` and `NavigationModel` are `@MainActor` and only publish; Vision and AppKit sit in `OnDevice/` and
  `Navigation/` types the logic tests do not need. All new types are `Sendable` or `@MainActor`.
- **Local insights rules** (all in code, every number a `Figure` with its arithmetic):
  - *Active time*: a focus event opens a span on its app (title and host as given); any event is activity; the span
    ends at the next focus, `idle_start`, `pause`, or, when the next event is more than 300 s later, at the last
    activity + 120 s (the idle threshold, as m3-04's local now summary). `idle_start` is written the idle threshold
    after the last activity (m3-05's readers, the observer), so it is moved back by 120 s when read, as m3-04's local
    now summary does: a span opened after that point is dropped and one running past it is cut there (corrected in
    review 2; this line first said the readers had already moved it back). An import holds several runs (each file
    writes idle_end … idle_start), and the next file can start within the 120 s before a run's idle_start: each
    idle_start closes the oldest open run and, when a later run has begun, cuts only what started before it (review
    3). Spans cross midnight by splitting at the day boundary in the person's time zone.
  - *Sessions*: a maximal run of spans with no idle gap of 300 s or more; sessions under 60 s are dropped. *Focus
    block*: a session of 25 minutes or more with at most 2 app switches per 10 minutes. *Switches*: focus changes to a
    different app.
  - *Steps*: spans under 10 s are folded into the span before them (ROADMAP M5 `SPAN` rule); a step is the app's
    bundle id, the **title shape** (the masked title, lowercased, pseudonyms `<kind:h_…>` → `<kind>`, digit runs →
    `#`, first 6 words) and the host. Recordings have no title or host, so their steps are apps.
  - *Things you repeat*: sequences of 2 to 4 consecutive steps (consecutive equal steps collapsed, at least two
    different apps or hosts) inside one session, seen on at least 2 different days and at least 3 times in total. A
    sequence contained in a longer one with the same occurrences is dropped. `key` = `k_` + first 12 hex of SHA-256
    of the step keys (the brain's task key shape). `name` is built from the steps' app names and hosts ("Xcode, then
    github.com in Safari, then Slack"), never from text.
  - *Minutes per week*: total minutes of all occurrences × 7 ÷ max(7, days from the first to the last observed day
    inclusive), rounded to whole minutes; arithmetic "6 times · 31 min median · 186 min over 9 days × 7 ÷ 9 = 145
    min/week". *Confidence* label: `high` with 4 or more days and 6 or more times; `medium` with 3 or more days or 4
    or more times; else `low` (weights 1.0, 0.7, 0.4). *Evidence*: occurrences, days, and the first observation id
    of each occurrence.
  - *Ranking* (ARCHITECTURE section 6's factors, done locally): `score = (minutesPerWeek ÷ 60) × persistence ×
    goalWeight × confidence × declinePenalty`; persistence = ISO weeks present ÷ ISO weeks observed (last 8);
    goalWeight 1.5 when a review answer linked the pattern to a goal (`keep`, `build` or `other_goal` with a
    `goal_id`), else 1; declinePenalty 0 after `never` or `leave_alone`, or `not_now` within 4 weeks, unless minutes
    per week rose 50% or more over the value at the answer; else 1. Ties by key. Top 5 are "things you repeat". It
    ranks time spent, not a saving: no saving is estimated on the Mac.
- **Exclusions** are applied when insights are read, not only when imported: an app, host or title in Never watch
  now (m3-04's `ExclusionSource`, built-ins included) keeps its time as "Never watch app" (no name), loses its title
  and host, and is never part of a repeat. Adding an entry updates Today without re-importing.
- **Incremental**: an import recomputes only the days it touched; removing an import recomputes its days; live
  events (when m3-02 fills `LocalEventSource`) are read for today on each refresh. Imports and live data are counted
  together on this Mac but stay apart in storage (import files vs the live buffer), so "Remove imported data" removes
  exactly an import's share.
- **Done line**: the floating panel, the Recordings screen and Settings show m3-05's "done · 1,284 moments read"
  plus "· 9 things you repeat" from the recomputed snapshot (`AnalysedImportPanel`); "No new recordings." stays as
  is. Screen 11 moves on to screen 12 when Import starts (m3-05), so its line is the panel's.
- **Egress**: `LocalImportSink` and the insights files never leave the Mac. The brain and builds clients are a second
  path to the configured API host only (ARCHITECTURE section 1, "the UI talks to the API with a device token of
  audience member"); in `.local` they do not exist. Nothing in `Analysis/` or `OnDevice/` can open a connection
  (test greps for `URLSession`, `NWConnection`, `CFStream`, `Network`, `socket(`).
- **Faked in tests**: Vision runs for real in one test on a CoreText-rendered image (no TCC needed); every other test
  injects recognizers, clocks, stores and transports. No test touches the network, the real Application Support
  folder, Keychain or TCC.
- **Known limits**: the interim masker finds person names with m3-02's "Name <email>" and signature-block rules and
  NaturalLanguage's tagger, which misses rare names and names written in lower case; it has no IBAN or
  bank routing checks beyond digit runs; titles from screenwatch rows are masked by it before they are stored. Files
  are protected by POSIX modes and macOS file protection, not by the AES-GCM day-file sealing m3-02 brings; they move
  into the sealed store with m3-02. Vision accuracy on small menu bar text varies by display scale.

### Implementation notes (build, 2026-11-22)
- **Shapes as built.** `OnDeviceRecordings.make(neverWatch:store:folders:panel:picker:recognizer:pseudonymKey:readers:clock:timeZone:durations:appNames:)`
  returns an `OnDeviceRecordings` value (`model`, `sink`, `ledger`, `observations`, `picker`, `paths`, `candidates`)
  rather than the bare model, so the Recordings screen can offer **Use this folder** (an `OnDeviceFolderPicker` that
  answers the next pick without the open panel) and tests can reach the sink and ledger; everything after `folders`
  is injectable and defaults to the live piece. `LocalAnalysis.live(neverWatch:events:)` builds the insights store
  (`LocalObservationStore` reader, the live `LocalEventSource`, `FileLocalAnswerStore`, Never watch rules through an
  `ExclusionRulesBox` refreshed on the main actor with installed apps' names) and the panel; `AppModel.startLocalAnalysis`
  wires the offer rule, the coordinator, the Never watch recount and the launch refresh.
- **`InsightsModel.schedule`** marks the model analysing synchronously and runs the store call, so the done line says
  "counting on this Mac" from the moment an import finishes until its days are counted, then "9 things you repeat".
- **The idle-gap rule is for live capture only.** Imports write a focus only when it changes and carry their
  idleness as explicit `idle_start`/`idle_end` (screenwatch rows more than 120 s apart, a recording's end), so a quiet
  stretch inside an import is not idle; applying the 300 s rule to them would undercount any long stay in one window.
  Live events (one per input) keep the rule. INSIGHTS tests pin both.
- **Snapshot repeats** keep every repeat ranked, declined ones with score 0 (`isDeclined`); `thingsYouRepeat` (what
  "9 things you repeat" counts) leaves declined ones out and `topRepeats` is its first 5.
- **Local Figures** use the brain's units plus `seconds` for durations counted on the Mac (local only, never sent).
  Figure ids match the brain port's `figure()` byte for byte (golden test).
- **Masker order.** Outputs are the SPEC's; emails are recognised before the card rule and phones before the
  long-digit rule, so an address's or a phone's digits are never read as an account number or a code. A date
  (`2026-11-22`) is never an account number; a sentence's full stop may follow a code.

## Red tests (write these first, run them, see them fail)
Folder `apps/mac/Tests/OffloadMacTests/M310/`, Swift Testing, every test `@Test("TAG: ...")` inside
`@Suite struct M310` (tests in extensions of `M310` across files).

| Tag | Tests (short) |
|---|---|
| OCR | Vision box to top-left pixel box (corners, full frame, a centred box); a CoreText-rendered "INVOICE 2041 READY" image is read by `VisionTextRecognizer` with the words in order and boxes inside the frame; a frame without an image gives no lines; lines come top to bottom then left to right; the request is accurate with the four languages |
| MASK | one test per rule: URL keeps host, path to `<doc:h_…>`, query and fragment dropped; bare host/path; each token family to `[SECRET]`; Luhn card with spaces and dashes to `[CARD NO.]`, a non-Luhn 16-digit run to `[ACCT NO.]`; 6-digit code to `[OTP]`; times, dates and `1,284` unchanged; email and phone to stable pseudonyms (same value same pseudonym, different key different pseudonym, case-insensitive email); 8000-character cap after masking; a menu bar app name ("Xcode", "Google Chrome") is unchanged so m3-05 keeps it; the pseudonym key file is 0600 in a 0700 folder and reused |
| SINK | observations round-trip through the file as `StoredObservation` with snake case keys; the masked text is not written (only `text_hash`); no key holds a path or file name; files 0600 and folder 0700; write to an unopened space throws; forget deletes only that import; two imports stay in two files; a corrupt line is skipped on read |
| WIRING | `OnDeviceRecordings.make` gives a model with `canImport == true`, the local sink and a file ledger under the injected folder; an import of a fixture folder (scripted frame readers, fake recognizer returning lines with an email) writes masked observations that the store reads back; offered in `.local` mode without sign-in, not offered in `.cloud` mode before sending, offered in `.cloud` while sending; Import in `.local` does not touch `ConsentService` or `Uploader` |
| FOLDERS | candidates in order (`~/screenwatch` first and kind screenwatch when it has `days/`, then the screencapture location with `~/` expanded, Desktop, Movies); missing folders left out; Offload's own data folder never a candidate; the preferred folder is used only when no folder was chosen; nothing is listed when candidates are computed |
| INSIGHTS | golden fixture day: active seconds, per-app seconds, top 5 apps, top sites by host only (no path ever), switches, longest focus, each a Figure with arithmetic and evidence; idle gap over 300 s ends a span at last activity + 120 s; a span across midnight splits; a day in another time zone; empty input gives zero figures and no invented numbers |
| SESSIONS | sessions split on a 300 s idle gap; under 60 s dropped; focus blocks (25 min, switch rule); spans under 10 s folded into the previous step |
| REPEAT | a 3-step sequence on 3 days found once with 3 occurrences; a sequence on one day only is not a repeat; a contained shorter sequence with the same occurrences dropped; single-app runs never a repeat; key is `k_` + 12 hex and stable across runs; name built from app names and hosts, never text; minutes per week and arithmetic exact for the fixture; confidence labels at each threshold |
| RANK | golden factors give the exact score; ties by key; top 5 only; persistence over the last 8 ISO weeks; goal-linked answer gives goalWeight 1.5 |
| ANSWERS | file store round-trip 0600; latest answer per week and subject wins; `never` and `leave_alone` drop a repeat; `not_now` hides it for 4 weeks then it returns (fake clock); a dropped repeat returns when its minutes per week rise 50% over the value at the answer |
| INCREMENTAL | a finished import recomputes only the days from its first to last day; removing an import recomputes its days and its repeats disappear; a second import of other days leaves cached days untouched (recompute count); live events from a `LocalEventSource` fake are counted for today with imported days; nothing is recomputed while no import finished |
| EXCLUDE | an app added to Never watch after import is shown as "Never watch app" with its time and leaves every repeat; an excluded host drops from top sites; a `title_contains` entry drops matching titles from steps; built-in exclusions apply |
| PROGRESS | the done items are "done", "1,284 moments read", "9 things you repeat" after a finished import with 9 repeats; one repeat reads "1 thing you repeat"; none leaves the count out; "No new recordings." unchanged; the Recordings screen model shows the same line |
| NAV | sidebar order and titles; the shell shows only when the route is Today and onboarding routes still show `MainWindowView`; `startBuild` selects Builds with the request; each placeholder screen exists with its `(app:)` initialiser; the Never watch sheet opens from the shell |
| BACKEND | `.local` by default; `.cloud` only with an https base URL and a token; http, missing URL or missing token stay `.local`; `.local` builds no clients; provenance follows the mode |
| BRAIN | each route's method, path, query and body bytes (`GET /v1/profile`, `PATCH /v1/profile` with only patchable keys, `GET /v1/records/days/2026-11-20`, `GET /v1/records/weeks/2026-W47`, `GET /v1/review/week?w=2026-W47`, `POST /v1/review/answers` with `goal_id` omitted when nil); fixtures from the brain port decode (DayRecord, WeekRecord, WeekReview, ReviewAnswer, Profile defaults); 404 is `.notFound`; error envelope codes decode, unknown code is `.other` |
| BUILDS | each route's method, path and body bytes; OK, build body is exactly the JCS bytes with `"cap_usd":4` and carries `Offload-Signature` and `Idempotency-Key`; deploy body exactly three hashes and signed; no signer refuses locally with nothing sent; a fixture `Build` from the build-loop port decodes every field; an unknown `state` decodes as unknown; 403 `hash_mismatch`, 409 `already_running` and `state_conflict` decode |
| HOST | every request goes to the configured host and `/v1` path; an id containing `/`, `..` or `//other.host` is rejected before sending; the bearer token is never written to logs or errors |
| SAMPLE | `.sample` provenance shows "Sample data: cloud not connected" first; `.onDevice` shows "counted on this Mac"; `.cloud` shows neither; sample provenance cannot be produced in `.cloud` mode |
| NONET | `Analysis/` and `OnDevice/` sources contain no networking API |
| COPY | new strings have no em dash, banned word or ADR 0016 term; captions lowercase with `·` items as separate items |

## Out of scope
m3-02's real masker, observer, sealed store and uploader (this slice adds an interim masker and a local sink behind
m3-05's protocols); the server half of imports (`POST /v1/imports`, forget scope `import`); any change in
`OffloadImport/**`, `Recordings/**`, `Today/**` or `Onboarding/**`; the Today, Weekly review and Build progress screen
contents (m3-11, m3-12, m3-13); keyframes; `services/**` and `packages/**`.

## Verify
`bash slices/m3-10-mac-recordings-analysis/verify.sh`. On Linux it checks scope and prints
`m3-10-mac-recordings-analysis: SKIPPED (needs macOS)`; with `REQUIRE_MAC=1` (CI `mac` job) a skip fails.

## Test plan (owner, on the m3-09 test build)
What this slice lets the owner see: the import and its done line ("done · N moments read · N things you repeat") in
the floating panel, on the Recordings screen and in Settings. Today still shows m3-04's skeleton and Weekly review and
Builds are placeholders, so the day figures and the things you repeat appear on screen only when m3-11 (Today) and
m3-12 (Weekly review) land. In Local mode onboarding skips screens 5 to 12, so the onboarding Recordings step (screen
11) is not seen on the test build; the import starts from the Recordings screen.

1. Install the test build from the CI artifact, finish onboarding with **Not now** on screen 4 (Local mode).
2. The window opens on Today with the sidebar (Today, Weekly review, Builds, Recordings, Settings). Settings says
   "on this Mac only" for the backend mode.
3. Open **Recordings**: the folder is `~/screenwatch` if it exists, else the screen recording location (Desktop by
   default), with "12 files · .mov · 6 h 10 m · Nov 5 to 11" style counts. **Choose folder…** picks another.
4. Press **Import**: the floating panel shows "reading file n of N" and ends with "done · N moments read · N things
   you repeat". The menu bar "Recordings…" entry is visible in Local mode.
5. In Finder, `~/Library/Application Support/Offload/OnDevice/imports/` holds one `.jsonl` per import: open one and
   check there is no screen text, no email address, no file name (only app names, hosts, masked titles and hashes).
   Masked window titles (from a screenwatch archive) are kept, with person names the masker recognised as
   `<person:h_…>`; a rare name the tagger misses can stay in a title.
6. Add an app you saw in the recordings to Never watch from the menu bar: its name leaves the repeats without a new
   import.
7. **Remove imported data** in Recordings: the file is gone and the repeats from it disappear.
8. Turn off Wi-Fi and repeat 4: everything works; nothing on these screens needs the network.

## Scope changes
- **Divergence from ARCHITECTURE section 1 and ADR 0007** ("It does no understanding, ranking or building"): the
  owner asked on 2026-11-22 for recordings to be analysed on the Mac in the test build. Local insights count and rank
  time on the Mac in code only (no model call, no upload), and only in `.local` backend mode; in `.cloud` mode the
  screens read the brain. ARCHITECTURE section 1 gains a "Local insights" paragraph in this slice; ADR 0007 is amended by [ADR 0039](../../docs/adr/0039-local-analysis-on-the-mac-in-local-mode.md) (proposed, needs the owner's sign-off; see the follow-up below).
- **ONBOARDING section 8**: "Only offered after screen 5 was accepted. In Local mode it is hidden" becomes "offered
  in Local mode when the import is kept on this Mac (backend mode local); in the cloud only while sending". Updated
  here; `RecordingsImportModel.offerCheck` is set by `AppModel.live()` after m3-04's `OnboardingModel` sets it.
- **Interim masker**: `OnDevice/InterimTextMasker.swift` is replaced by m3-02's `OffloadMasker.TextMasker` (an
  adapter `TextMaskerImportAdapter: ImportTextMasker` calling `mask(_:).text`) and the local pseudonym key by the
  tenant pseudonym key in the Keychain when PR #13 lands; the MASK tests stay as the adapter's tests. Needs a
  security review against SECURITY_PRIVACY section 13 before `done`.
- **Not editing m3-04 or m3-05 files**: `RootView.swift` is m3-04's, so the shell wraps `MainWindowView` from
  `OffloadApp.swift` instead of adding a case to it; `Recordings/**` is m3-05's, so the analysed done line comes from a
  new panel presenter passed to `RecordingsImportModel`'s public init, not from `RecordingsCopy`.
- **Placeholders owned by later slices**: this slice writes exactly one file in each of `TodayLive/`,
  `BuildProgress/` and two in `WeeklyReview/`; m3-11, m3-12 and m3-13 own those folders and set their `BASE` after
  this slice is `done`, so their owns check does not see these commits.
- **API gaps found** (for the API owners; `services/**` and `docs/API.md` are not edited here): the brain port has no
  `GET /v1/today` or `GET /v1/opportunities` yet; the build-loop port implements only build-approvals, `GET` build and
  deploy; there is no `GET /v1/builds` list route in API.md. The clients follow API.md and return `.notFound` for
  routes the server does not have.
- `model_tier: opus`: compile-blind Swift (no toolchain on the Linux box) and a security-sensitive masker.
- `parallel_safe: false`: m3-11, m3-12 and m3-13 depend on it.
- Glossary gains **Local insights**, **Backend mode**, **Sample data** and **Interim masker** (in this slice).
- The owner's install guide (`apps/mac/TestBuild/INSTALL_AND_TEST.md`, m3-09's file) should gain the Test plan
  above; m3-09 owns it.
- **Build divergences** (2026-11-22, see Implementation notes): the 300 s idle-gap rule applies to live capture only;
  emails and phones are masked before the digit rules; `LocalImportSink` throws its own `LocalImportSink.UnknownSpace`
  because OffloadImport's `UnknownImportSpace` has no public initialiser (m3-05's file is out of scope; a public init
  there would let the sink throw the shared type); `OnDeviceRecordings.make` returns a value holding the model, sink,
  ledger and folders found; `AppModel` gains a fourth defaulted stored property, `onDeviceRecordings`, for the
  Recordings screen's folders (still additive); local Figures add the unit `seconds`.
- **API addition for m3-13**: `BuildsClient.opportunity(id:)` (`GET /v1/opportunities/{id}`, API.md) so Build progress
  can poll an opportunity until its fix exists without editing `Backend/`.
- **Red tests seen failing**: the red commit adds the M310 suite before any `Analysis/`, `OnDevice/`, `Backend/` or
  `Navigation/` source exists, so the suite does not compile at that commit (every tag red). No Swift toolchain on the
  Linux box: the green run is the macOS CI `mac` job, which is the done gate.
- **Credits** (for NOTICE, which this slice may not edit): `LocalDays.fastUTC` uses Howard Hinnant's
  `days_from_civil` (from "chrono-Compatible Low-Level Date Algorithms", public domain); the floating panel reuses
  m3-05's `KeyablePanel` (after farzaa/clicky, MIT, already credited by m3-05). No other code was ported: the brain
  and build-loop ports were read for shapes and their JSON fixtures generated with their own builders.
- **Review 1** (2026-11-22, `logs/m3-10-mac-recordings-analysis.review1.md`), changes made:
  - *Overlapping origins* (finding 1): `LocalInsights.mergedSpans` counts each instant once. Where origins overlap,
    live capture wins, then imports with titles or hosts (screenwatch), then the rest (recordings); ties by import id;
    a losing span keeps the time no winner covers. A day can no longer exceed wall-clock time.
  - *Launch wiring and the Never watch recount* (finding 2): tested end to end through `AppModel.startLocalAnalysis`.
    The menu bar's **Don't watch** (`AppModel.dontWatch`, an additive line) and the Never watch sheet closing call
    `InsightsModel.exclusionsChanged()` directly; onboarding's `objectWillChange` stays as a second, later look.
    `InsightsModel.idle()` waits for every recount asked for.
  - *Cost* (finding 3): spans are built, merged and filtered by Never watch once per recompute and clipped into each
    day; `refreshAll` reads the imports once and takes the days from that read.
  - *Old archives* (finding 4): the 8 ranking weeks count back from the last observed day when that is before now
    (a divergence from "the last 8 ISO weeks" read literally), so an archive older than 8 weeks still ranks.
  - *No folder check at launch* (finding 5): `OnDeviceRecordings.make` checks only `~/screenwatch/days`; the default
    folders are `RecordingFolderCandidates`, checked when the Recordings screen shows them. Without screenwatch the
    suggestion is the screen recording location, named without looking (m3-05's `RecordingFolder.suggested`).
  - *File protection* (finding 6): files are written with protection until first unlock instead of complete
    protection, so an import running while the screen locks can still write and its counting can still read.
  - *Hardening* (finding 10): a lone `.` is refused as an id; `Backends.make` builds no `URLSession` in `.local`;
    in `.local` Import is offered only when the on-device import exists, and the Recordings screen says so when it
    could not be set up.
  - Not changed: the Vision test keeps its real request (finding 7; if a virtualised runner cannot run it, set the
    request's compute device to the CPU for tests, never weaken the assertion); masked titles are kept (finding 8,
    now said in the test plan and SECURITY_PRIVACY); the `.cloud` clients write nothing to the egress ledger yet
    (finding 9): they are a second path out of the Mac (ADR 0035 makes the uploader the egress guard), dormant in the
    test build (`NoMemberToken`, so `.local`), and need a ledger hook before `.cloud` is turned on.
- **Review 2** (2026-11-22, `logs/m3-10-mac-recordings-analysis.review2.md`), changes made:
  - *idle_start* (finding 1, a real error in this SPEC's Design note): it is now moved back by the idle threshold.
    The test fixtures were in the wrong shape (`idle_start` at the exact end of activity); they now follow the
    readers (`idle_start` = last activity + 120 s), so their expected figures are unchanged. The live day test now
    expects 480 s, the local now summary's figure for the same events, instead of 600 s. New tests: an importer of a
    60 s recording through the local sink and store counts 60 s, and insights agree with `LocalNowSummary`. The 300 s
    gap rule for live streams without an `idle_start` stays as this SPEC says.
  - *Unfinished imports* (finding 2): at launch `OnDeviceRecordings.make` deletes the files and ledger entries of
    imports that are not listed (an import is listed only once it finished), so nothing is counted that cannot be
    removed, and the next import reads those recordings again.
  - *Restored Settings window* (finding 3): it shows a "Show recordings settings" button until the person asks for it
    (the menu bar's Recordings… asks), so no folder is read at launch by that path either.
  - *`.cloud`* (finding 4): only `.local` builds the on-device import; `.cloud` keeps m3-05's import as it was built,
    and the Recordings screen's caption follows the backend's provenance.
  - *Protection class* (finding 5): `OnDeviceFiles.writeOptions` is pinned by a SINK test. It was changed in review 1
    without a red test first; the test came after (the protection class itself is not readable on every CI volume,
    so the test checks the options the files are written with).
  - *Owner expectations* (finding 6): the Test plan now says where the analysis can be seen in this slice.
- **Review 3** (2026-11-22, `logs/m3-10-mac-recordings-analysis.review3.md`), changes made:
  - *Runs inside one import* (finding 1): review 2's backdating let one file's idle_start cut the next file's run
    (back-to-back recordings, a screenwatch day continuing past midnight). Each idle_start now closes the oldest open
    run of its import and leaves a later run's spans alone; a run left open by a lost idle_start is forgotten once a
    later run's idle_start passes it. Live capture is one stream and keeps review 2's rule. Tests: two recordings 30 s
    and 0 s apart, two screenwatch days across midnight, a live stream, and the real importer over two recordings 90 s
    apart.
  - *Unreadable list of imports* (finding 2): when m3-05's stored list exists but does not decode, nothing is
    discarded at launch (`importsListReadable`), so an unreadable list never deletes analysed history.
  - *Tests that pinned a predicate* (finding 3): `LocalAnalysis.live` takes the folders and defaults, and a test now
    checks that it builds the on-device import in `.local` and none in `.cloud`. The protection test still pins
    `OnDeviceFiles.writeOptions`: reading `FileAttributeKey.protectionKey` back depends on the CI volume supporting
    data protection, and `writeProtected` is the only writer, so the constant is the reliable check.
  - *Restored Settings window* (finding 4): one line says why it waits.
- **ADR for the local analysis** (follow-up 2026-11-22): [ADR 0039](../../docs/adr/0039-local-analysis-on-the-mac-in-local-mode.md)
  (status `proposed, needs Muhammad's sign-off`) amends ADR 0007 for `.local` mode: counts and ranking in code only, no
  model call, no upload, masked data only, and what changes in `.cloud` mode. ADR 0007 gains one "Amended by" line and
  the ADR index one row. `docs/adr/**` moves from `paths_out_of_scope` to `paths_in_scope` for this, the only ADR
  files this slice changes.
- **Person names in the interim masker** (follow-up 2026-11-22): `InterimTextMasker` now masks person names before
  anything is stored, as `<person:h_…>` with m3-02's normalisation (NFKC, trimmed, lowercased, single spaces): m3-02's
  `OffloadMasker.TextMasker` "Name <email>" and signature-block patterns and name check (2 to 4 words, no company or
  team word), then names NaturalLanguage's tagger finds (`NLTagger`, `.nameType`, `.personalName`, names joined;
  system framework, no Package.swift change). App names, months, weekdays and common title words are never names. The
  name finder is injectable (`PersonNameFinder`); most tests inject one so the rules give the same result on every Mac,
  two use the real tagger. **The m3-14 integration (branch `w1/mac-integration`) replaces this interim masker with
  `OffloadMasker.TextMasker` once both land**; m3-02's masker has no tagger pass today, so m3-14 decides whether the
  tagger pass moves into it.
- **Security review needed** before `done` (SECURITY_PRIVACY section 13): the interim masker, the local sink and the
  local pseudonym key.
- **Rebase onto the rewritten `w1/h-shell-onboarding`** (2026-11-22, after its rebase onto main): m3-03 made
  `OffloadMac` the executable target, so the SwiftUI `App` moved from `Sources/OffloadMacApp/OffloadApp.swift` to
  `Sources/OffloadMac/App/OffloadApp.swift` (no `@main`, no `import OffloadMac`). One conflict, in that file's
  `MenuBarOpener`: the parent's `MenuBarContent(app:openWindow:updates:checkForUpdates:)` call (the updater's lines,
  `AppUpdates`) is kept, with this slice's comment and "Recordings…" routing below it. `paths_in_scope` adds
  `apps/mac/Sources/OffloadMac/App/**` and keeps `apps/mac/Sources/OffloadMacApp/**` for the earlier commits;
  `BASE` moves to the rewritten "m3-13-mac-build-progress: SPEC and verify.sh" commit.
