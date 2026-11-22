---
id: m3-12-mac-weekly-review
title: Weekly review on the Mac (one sentence, tiles against your usual week, goals, up to 4 questions whose answers tune next week's ranking), at the review slot with an optional notification, from local insights or the brain's weekly review
milestone: M3
status: ready
depends_on: [m3-10-mac-recordings-analysis]
parallel_safe: true
human_gated: true
model_tier: sonnet
size: M
parallel_group: M3-E
owns: [apps/mac/Sources/OffloadMac/WeeklyReview/**, apps/mac/Tests/OffloadMacTests/M312/**]
verify: bash slices/m3-12-mac-weekly-review/verify.sh
min_tests: 55
paths_in_scope: [apps/mac/Sources/OffloadMac/WeeklyReview/**, apps/mac/Sources/OffloadMac/Shell/AppModel.swift, apps/mac/Tests/OffloadMacTests/M312/**, apps/mac/README.md, docs/GLOSSARY.md, slices/m3-12-mac-weekly-review/**]
paths_out_of_scope: [ee/**, services/**, packages/**, apps/web/**, docs/adr/**, .github/**, NOTICE, apps/mac/Package.swift, apps/mac/Packaging/**, apps/mac/TestBuild/**, apps/mac/Sources/OffloadMacApp/**, apps/mac/Sources/OffloadMac/OffloadMac.swift, apps/mac/Sources/OffloadMac/Updates/**, apps/mac/Sources/OffloadMac/SelfCheck/**, apps/mac/Sources/OffloadMac/Version/**, apps/mac/Sources/OffloadObserver/**, apps/mac/Sources/OffloadMasker/**, apps/mac/Sources/OffloadStore/**, apps/mac/Sources/OffloadUploader/**, apps/mac/Sources/OffloadImport/**, apps/mac/Sources/OffloadMac/Recordings/**, apps/mac/Sources/OffloadMac/Today/**, apps/mac/Sources/OffloadMac/Onboarding/**, apps/mac/Sources/OffloadMac/Permissions/**, apps/mac/Sources/OffloadMac/LocalNow/**, apps/mac/Sources/OffloadMac/NeverWatch/**, apps/mac/Sources/OffloadMac/Design/**, apps/mac/Sources/OffloadMac/Shell/Launch.swift, apps/mac/Sources/OffloadMac/Shell/AppMover.swift, apps/mac/Sources/OffloadMac/Shell/MenuBar.swift, apps/mac/Sources/OffloadMac/Shell/RootView.swift, apps/mac/Sources/OffloadMac/Shell/LiveServices.swift, apps/mac/Sources/OffloadMac/Analysis/**, apps/mac/Sources/OffloadMac/OnDevice/**, apps/mac/Sources/OffloadMac/Backend/**, apps/mac/Sources/OffloadMac/Navigation/**, apps/mac/Sources/OffloadMac/TodayLive/**, apps/mac/Sources/OffloadMac/BuildProgress/**, apps/mac/Tests/OffloadMacTests/SmokeTests.swift, apps/mac/Tests/OffloadMacTests/M304/**, apps/mac/Tests/OffloadMacTests/M305/**, apps/mac/Tests/OffloadMacTests/M309/**, apps/mac/Tests/OffloadMacTests/M310/**, apps/mac/Tests/OffloadMacTests/M311/**, apps/mac/Tests/OffloadMacTests/M313/**]
red_tests: [WEEK, SLOT, SENTENCE, TILES, USUAL, GOALS, QUESTIONS, ANSWERS, NOTES, NOTIFY, SETTINGS, CLOUD, STATES, FIGURES, COPY]
---

# m3-12-mac-weekly-review

## Summary
The mockup's **Weekly review** (`Weekly`, mockups `source.canvas.tsx` lines 629 to 709): one sentence about what
changed, four tiles against your usual week, your goals, then up to 4 one-tap questions whose answers tune next
week's ranking ([ONBOARDING section 12](../../docs/ONBOARDING.md#12-the-first-week), [ARCHITECTURE section 6](../../docs/ARCHITECTURE.md#6-opportunity-finder)).
It lands at the review slot (default Friday 4:00 PM) with a notification the person can turn on. In `.cloud` backend
mode it reads `GET /v1/review/week?w=` and posts `POST /v1/review/answers` ([API.md "Today, records and review"](../../docs/API.md#today-records-and-review-core-m5-unless-noted),
brain port `port/brain-user-model`); in `.local` mode it is computed by code from m3-10's local insights, and the
answers are stored on this Mac through m3-10's `LocalAnswerStore`, which local ranking already reads. It replaces
m3-10's `WeeklyReviewScreen` and `WeeklyReviewSettings` placeholders. ROADMAP m5-05's Mac screen brought forward (see
Scope changes). `human_gated: true`: the owner answers real questions about his imported weeks.

## Contract
- **No new dependency, no Package.swift change.** Files under `WeeklyReview/` plus an additive edit to
  `Shell/AppModel.swift` (the scheduler starts at launch). `UserNotifications` is a system framework.
- **`WeeklyReview/`**:
  - `ISOWeek` (`YYYY-Www`, ISO 8601 weeks in the person's time zone, Monday first; `from`, `to`, `previous`, `next`,
    `contains(_:)`).
  - `ReviewSlot` (`day: Weekday`, `time: "HH:mm"`, `timeZone`), default from m3-04's `Rhythm` (`reviewDay`,
    `reviewTime`, default Fri 16:00), overridden by `ReviewSettingsStore` (`UserDefaults`, in-memory fake) in
    `.local`, or the brain profile's `review_slot` in `.cloud`. `ReviewSchedule.next(after:slot:)` (correct across
    daylight saving changes) and `ReviewSchedule.shownWeek(now:slot:)`: the current week once its slot has passed,
    else the previous week.
  - `WeeklyReviewModel` (@MainActor): `week`, `content: ReviewContent?`, `state` (`.loading`, `.ready`, `.empty`,
    `.notYet(week)`, `.failed(ReviewError)`), `previousWeek()`, `nextWeek()`, `answer(_ question:, _ choice:)`,
    `refresh()`.
  - `ReviewContent` (pure, Equatable): `title` ("Week of Nov 9 · review"), `sentence`, `subtitleItems` ("week 8 of
    what Offload knows about you", "every number opens to how it was counted"), `tiles: [ReviewTile]` (label, value
    Figure, delta line, `tone` good or needs-you), `goals: [GoalRow]`, `questions: [ReviewQuestion]` (at most 4),
    `answeredCount`, `provenance`.
  - `ReviewContent.local(snapshot:week:history:goals:answers:)` and `ReviewContent.cloud(review:week:)`: pure.
  - `ReviewSentence`: a closed set of sentence templates filled only with numbers and names from the week's Figures
    and repeats; `ReviewSentence.check(_:figures:)` refuses a sentence with a number that is not in the figures
    (ROADMAP M5 `NARRATIVE` rule, done on the Mac).
  - `ReviewNotifier` protocol (`authorization() async -> Status`, `requestAuthorization() async -> Bool`,
    `schedule(at: DateComponents, id:)`, `remove(id:)`), `LiveReviewNotifier` (`UNUserNotificationCenter`, never
    built in tests), `FakeReviewNotifier`.
  - `ReviewScheduler` (@MainActor): with the setting on, keeps exactly one repeating weekly notification
    (`UNCalendarNotificationTrigger` on weekday, hour and minute of the slot), id `ai.offload.weekly-review`;
    reschedules when the slot changes; removes it when the setting is turned off.
  - `WeeklyReviewSettings(app:)`: the Settings section (m3-10 places it): the slot ("Fri 4:00 PM") with a day and
    time picker, and the toggle "Tell me when my review is ready".
  - `ReviewCopy`: every string of the screen and the notification.
- **Hook** (`Shell/AppModel.swift`, additive): `AppModel.live()` starts `ReviewScheduler` so the notification is kept
  without opening the screen.
- **`.local` content** (m3-10 `InsightsSnapshot`, `LocalAnswerStore`, m3-04 `ProfileAnswers.goals`):
  - Tiles, in mockup order: **Active** (hours this week), **Deep work** (hours in focus blocks), **Switches / hour**,
    **Saved by fixes** (on the Mac no fix runs, so the tile reads "no fixes yet" and shows no number).
  - Delta lines against **your usual**: the median of up to 8 earlier ISO weeks with data: "−2% vs your usual"; a
    week with no earlier week reads "first week"; tone rules: Deep work up is good, Switches / hour up needs you,
    Active within 10% of usual is good, else needs you; a trend of 3 or more weeks in a row reads "down 3 weeks
    running" or "up 3 weeks running".
  - Sentence (one of): "<repeat> grew 3 weeks in a row." (a top repeat whose minutes rose in each of the last 3
    weeks), "You worked 41.2 h, about your usual." / "… 12% more than your usual." / "… 12% less than your usual.",
    "Your first week: 41.2 h of work." Numbers come from the tiles' Figures.
  - Goals: the profile's goals (up to 3); hours for a goal = the minutes this week of repeats whose latest answer
    linked them to that goal (`keep`, `build` or `other_goal` with its `goal_id`); a goal with none reads "not linked
    yet"; trend "↑ 4 weeks" or "↓ 3 weeks · drifting" from the linked hours of earlier weeks. Local goal ids are
    `g_` + first 10 hex of SHA-256 of the goal text (the brain's id shape).
  - Questions, up to 4, from the top-ranked repeats not yet answered this week and not declined: with goals, "Is
    <repeat> part of <goal>?" (chips **Yes** → `keep` with the goal id, **No** → `keep` without, **It's for another
    goal** → picks a goal, `other_goal`); and "Build something for <repeat> next?" with its why line "Top repeat:
    145 min/week, 3 of 4 weeks." (chips **OK, build** → `build`, **Not now** → `not_now`, **Never** → `never`). Each
    question's `subject_key` is the repeat's `k_` key; `question_kind` is `opportunity`.
- **`.cloud` content**: `GET /v1/review/week?w=YYYY-Www` → `sentence`, the four `tiles` as given (the brain's order:
  hours total, focus minutes, meeting hours, switches per active hour), `goals` (text only), `questions` with their
  `answers` and `answered`; chip labels by answer: `keep` "Keep", `not_now` "Not now", `build` "OK, build", `never`
  "Never", `leave_alone` "Leave it alone", `other_goal` "It's for another goal". Answering posts
  `POST /v1/review/answers` with `{ iso_week, subject_key, question_kind, answer, goal_id? }` (`goal_id` only with
  `keep`, `build` or `other_goal`, required with `other_goal`). A 404 is `.notYet` (a future week). The slot comes from
  `GET /v1/profile` and changes go through `PATCH /v1/profile` `{ review_slot: { day, time } }`.
- **After an answer** (both modes): `build` adds "queued · same build screen as today" and calls m3-10's
  `navigation.startBuild` (`.localRepeat` or the opportunity); `never` adds "it won't come back unless the hours rise
  by half"; the counter reads "2 of 4 answered · each answer tunes next week". In `.local`, local ranking reads the
  answer at once (m3-10 `RankingAdjustments`), so Today's card and next week's questions change.

## Design note
- **Layout** follows the mockup's rule: "one sentence about what changed, then tiles compared with your usual week,
  then your goals, then 4 one-tap questions. No charts inside the app's review." Every tile and goal number opens to
  its arithmetic. Answered questions show the animated tick and a green border; Reduce Motion shows the final state.
- **Which week**: before the slot the screen shows last week's review; at and after the slot, this week's. Previous
  and next step through weeks with data; a future week is never computed.
- **Notifications**: off by default and offered on this screen for the first time (ONBOARDING section 12: at most one
  notification a day in the first week; this is one a week). Turning the toggle on asks macOS once; if macOS says no,
  the toggle turns off and the line reads "Notifications are off for Offload in System Settings." The notification
  says "Your weekly review is ready." with no numbers and no names (it shows on a locked screen).
- **States**: `.empty` (`.local`, no data in the week): "Nothing counted this week yet." with **Choose recordings**;
  `.notYet`: "Your review for this week lands Friday at 4:00 PM."; `.failed`: one sentence per `APIError` code with
  **Try again**. No state shows a number that was not counted; sample data is never shown here.
- **Provenance**: `.local` shows "counted on this Mac" (m3-10's caption).

## Red tests (write these first, run them, see them fail)
Folder `apps/mac/Tests/OffloadMacTests/M312/`, Swift Testing, every test `@Test("TAG: ...")` inside
`@Suite struct M312` (tests in extensions of `M312` across files). Fixed clocks and time zones; brain-port JSON
fixtures.

| Tag | Tests (short) |
|---|---|
| WEEK | ISO week of dates around New Year (2026-W53 vs 2027-W01), Monday start, in a non-UTC time zone; previous and next |
| SLOT | default Fri 16:00 from the rhythm; the settings store overrides it; next slot after a Friday 15:59 and 16:00; across a daylight saving change; shown week is last week before the slot and this week after |
| SENTENCE | each template from a fixture week; "grew 3 weeks in a row" chosen only with 3 rising weeks; a sentence with a number not in the figures is refused; first week template |
| TILES | Active, Deep work and Switches / hour values from the snapshot; Saved by fixes shows "no fixes yet" and no number; cloud tiles as given, in order |
| USUAL | median of up to 8 earlier weeks; "−2% vs your usual"; "first week" with no history; tone rules per tile; "down 3 weeks running" |
| GOALS | profile goals listed; hours only from answer-linked repeats; "not linked yet"; trend arrows; local goal id shape `g_` + 10 hex |
| QUESTIONS | at most 4; goal question only when goals exist; answered and declined repeats not asked; why line numbers from Figures; cloud questions and chips by answer |
| ANSWERS | local answers written to `LocalAnswerStore` with week, `k_` key, answer and goal id; `other_goal` needs a goal; the next local snapshot ranks accordingly; cloud posts the exact body and omits `goal_id` when nil |
| NOTES | build note and `navigation.startBuild` with the right request; never note; counter text |
| NOTIFY | toggle off by default; turning on asks once and schedules one weekly trigger at the slot; denied turns it off with the line; slot change reschedules (still one); turning off removes it; the text has no number |
| SETTINGS | the Settings section shows the slot and the toggle; editing the slot in `.local` saves to the store, in `.cloud` sends `PATCH /v1/profile` with only `review_slot` |
| CLOUD | `GET /v1/review/week?w=2026-W47` request; WeekReview fixture maps to content; 404 is `.notYet`; no request in `.local` |
| STATES | empty with Choose recordings; not yet line with the slot in words; failed sentences with Try again |
| FIGURES | every number in `ReviewContent` traces to a Figure with arithmetic |
| COPY | strings have no em dash, banned word or ADR 0016 term; captions lowercase with `·` items as separate items |

## Out of scope
The page-level charts of the mockup ("Patterns across weeks", "Efficiencies found", "Saved: measured vs estimated":
one click deeper, later); fix and name questions of the mockup (questions 2 and 3: they need shipped fixes, M4, and
confirmed names, M7); week record generation in the cloud (m5-02); any change to m3-04's onboarding rhythm or m3-10's
folders.

## Verify
`bash slices/m3-12-mac-weekly-review/verify.sh`. On Linux it checks scope and prints
`m3-12-mac-weekly-review: SKIPPED (needs macOS)`; with `REQUIRE_MAC=1` (CI `mac` job) a skip fails.

## Test plan (owner, on the m3-09 test build)
1. With at least two weeks of recordings imported, open **Weekly review**: the title names the week; the sentence and
   tiles match the weeks; click a tile to see how it was counted. Step to the previous week.
2. Answer **Never** on one question: the note appears; Today's card no longer shows that repeat. Answer **OK,
   build** on another: Build progress opens (a labelled sample in Local mode).
3. Relaunch: the answers are still there and the counter matches.
4. In Settings, set the review slot to two minutes from now and turn on "Tell me when my review is ready": macOS asks
   once; the notification arrives at the slot and has no numbers in it. Turn it off: no notification next time.
5. Before the slot on the review day, the screen shows last week's review.

## Scope changes
- ROADMAP puts the weekly review's Mac screen in m5-05 (M5); the owner asked for it in the test build now. This slice
  is the Mac screen only; m5-02 and m5-05 keep the week records and the API.
- Mockup questions 2 (keep or undo a fix) and 3 (confirm a name) are not built: the brain's `POST /v1/review/answers`
  accepts only `question_kind: "opportunity"` and the answers `keep`, `not_now`, `build`, `never`, `leave_alone`,
  `other_goal`. The mockup's "Saved by fixes" tile is "no fixes yet" on the Mac; in `.cloud` the brain sends meeting
  hours as its third tile (brain port `week-review.ts`), shown as given.
- The brain's `WeekReview` has `iso_week` and the question fields `subject_key`, `question_kind`, `name`, `answers`,
  `answered`, which API.md does not list yet (found while writing this SPEC; for the API owners).
- `Shell/AppModel.swift` is shared (m3-04, m3-05, m3-10); this slice adds one line to `live()`.
- `BASE` is set after m3-10 is `done`, so m3-10's placeholder commits in `WeeklyReview/` are not counted against this
  slice's `owns`.
