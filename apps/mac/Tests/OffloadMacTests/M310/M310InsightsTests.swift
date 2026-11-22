import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Analysis/: one day's figures, sessions, the things you repeat, ranking, the answers kept on this Mac and Never watch
// applied when insights are read.
extension M310 {
  /// The golden day (2026-11-20, UTC): Xcode 30 min, github.com in Safari 10, Slack 10, Xcode 30, then idle.
  static func goldenDay() -> (events: M310Events, day: DayInsights) {
    var e = M310Events(prefix: "g")
    e.idleEnd(M310Clock.date(2026, 11, 20, 9))                                                          // g-001
    e.focus(M310Clock.date(2026, 11, 20, 9), M310App.xcode)                                             // g-002
    e.focus(M310Clock.date(2026, 11, 20, 9, 30), M310App.safari, title: "Pull request 41", host: "github.com")  // g-003
    e.focus(M310Clock.date(2026, 11, 20, 9, 40), M310App.slack, title: "#ops")                         // g-004
    e.focus(M310Clock.date(2026, 11, 20, 9, 50), M310App.xcode)                                         // g-005
    e.idleStart(M310Clock.date(2026, 11, 20, 10, 22))   // g-006: the readers' shape, last activity 10:20 + 120 s
    return (e, LocalInsights.day(e.events, day: "2026-11-20", timeZone: M310Clock.utc, exclusions: []))
  }

  // MARK: INSIGHTS

  @Test("INSIGHTS: the golden day's active seconds, per-app seconds, switches and longest focus, each a Figure")
  func goldenDayFigures() {
    let (e, d) = Self.goldenDay()
    #expect(d.activeSeconds.value == 4800)
    #expect(d.activeSeconds.unit == "seconds")
    #expect(d.activeSeconds.arithmetic == "4 spans added up = 1 h 20 m")
    #expect(d.activeSeconds.evidence == [e.id(2), e.id(3), e.id(4), e.id(5)].map { EvidenceRef.observation($0) })
    #expect(d.perApp.map(\.appName) == ["Xcode", "Safari", "Slack"])
    #expect(d.perApp.map(\.seconds.value) == [3600, 600, 600])
    #expect(d.perApp[0].seconds.arithmetic == "Xcode: 2 spans = 1 h")
    #expect(d.perApp[0].seconds.evidence == [EvidenceRef.observation(e.id(2)), .observation(e.id(5))])
    #expect(d.switches.value == 3)
    #expect(d.focusBlocks.value == 1)
    #expect(d.longestFocus.value == 4800)
    #expect(d.longestFocus.arithmetic == "longest of 1 focus block = 1 h 20 m")
    #expect(d.switchesPerActiveHour.value == 2.3)
    for f in [d.activeSeconds, d.switches, d.focusBlocks, d.longestFocus, d.focusSeconds] {
      #expect(f.id == Figure.id(value: f.value, unit: f.unit, arithmetic: f.arithmetic, evidence: f.evidence, sourcePurgedAt: nil))
      #expect(f.id.hasPrefix("fig_") && f.id.count == 20)
    }
  }

  @Test("INSIGHTS: a figure's id is the brain's (fig_ + 16 hex of SHA-256 over JCS without id) and source_purged_at is always encoded")
  func figureIdMatchesBrain() throws {
    // Golden id from the brain port's figure(): services/brain/src/records/figure.ts, same body.
    let f = Figure.local(145, unit: "minutes_per_week", arithmetic: "6 times · 31 min median = 145 min/week",
                         evidence: [EvidenceRef(kind: "observation", id: "01JOBS0001")])
    #expect(f.id == "fig_b519d8d9295cecd7")
    #expect(Figure.local(2.3, unit: "per_hour", arithmetic: "x", evidence: []).id == "fig_80ab63878ff465e6")
    let json = try #require(String(data: try JSONEncoder().encode(f), encoding: .utf8))
    #expect(json.contains("\"source_purged_at\":null"))
    let back = try JSONDecoder().decode(Figure.self, from: Data(json.utf8))
    #expect(back == f)
  }

  @Test("INSIGHTS: top 5 apps by seconds and top sites by host only (no path ever)")
  func topAppsAndSites() {
    var e = M310Events(prefix: "t")
    var t = M310Clock.date(2026, 11, 20, 9)
    e.idleEnd(t)
    let apps: [(String, String)] = (1...7).map { ("test.app\($0)", "App \($0)") }
    for (i, app) in apps.enumerated() {
      e.focus(t, app, title: "page", host: i < 6 ? "site\(i).example.com" : nil)
      t = t.addingTimeInterval(TimeInterval((10 - i) * 60))
    }
    e.idleStart(t.addingTimeInterval(120))
    let d = LocalInsights.day(e.events, day: "2026-11-20", timeZone: M310Clock.utc, exclusions: [])
    #expect(d.topApps.map(\.appName) == ["App 1", "App 2", "App 3", "App 4", "App 5"])
    #expect(d.perApp.count == 7)
    #expect(d.topSites.map(\.host) == ["site0.example.com", "site1.example.com", "site2.example.com", "site3.example.com",
                                       "site4.example.com"])
    #expect(d.topSites.allSatisfy { !$0.host.contains("/") })
    #expect(d.topSites[0].seconds.value == 600)
  }

  @Test("INSIGHTS: in live capture, an idle gap over 300 s ends a span at the last activity + 120 s")
  func idleGapEndsSpan() {
    var e = M310Events(origin: .live, prefix: "l")
    e.focus(M310Clock.date(2026, 11, 20, 9), M310App.xcode)
    e.text(M310Clock.date(2026, 11, 20, 9, 1))
    e.focus(M310Clock.date(2026, 11, 20, 9, 20), M310App.slack)
    let d = LocalInsights.day(e.events, day: "2026-11-20", timeZone: M310Clock.utc, exclusions: [])
    #expect(d.spans.map(\.seconds) == [180, 120])
    #expect(d.spans[0].end == M310Clock.date(2026, 11, 20, 9, 3))
    #expect(d.activeSeconds.value == 300)
  }

  @Test("INSIGHTS: a span across midnight is split at the day boundary")
  func spanAcrossMidnight() {
    var e = M310Events(prefix: "m")
    e.focus(M310Clock.date(2026, 11, 19, 23, 50), M310App.xcode)
    e.idleStart(M310Clock.date(2026, 11, 20, 0, 22))
    let before = LocalInsights.day(e.events, day: "2026-11-19", timeZone: M310Clock.utc, exclusions: [])
    let after = LocalInsights.day(e.events, day: "2026-11-20", timeZone: M310Clock.utc, exclusions: [])
    #expect(before.activeSeconds.value == 600)
    #expect(after.activeSeconds.value == 1200)
    #expect(after.spans.first?.start == M310Clock.date(2026, 11, 20))
  }

  @Test("INSIGHTS: days follow the person's time zone")
  func dayInAnotherTimeZone() throws {
    let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
    var e = M310Events(prefix: "z")
    e.focus(M310Clock.date(2026, 11, 19, 23, 50), M310App.xcode)   // 00:50 in Berlin
    e.idleStart(M310Clock.date(2026, 11, 20, 0, 22))
    let local = LocalInsights.day(e.events, day: "2026-11-20", timeZone: berlin, exclusions: [])
    let before = LocalInsights.day(e.events, day: "2026-11-19", timeZone: berlin, exclusions: [])
    #expect(local.activeSeconds.value == 1800)
    #expect(before.isEmpty)
    #expect(LocalDays.label(M310Clock.date(2026, 11, 19, 23, 50), timeZone: berlin) == "2026-11-20")
  }

  @Test("INSIGHTS: empty input gives zero figures with nothing behind them and no invented numbers")
  func emptyDay() {
    let d = LocalInsights.day([], day: "2026-11-20", timeZone: M310Clock.utc, exclusions: [])
    #expect(d.isEmpty)
    for f in [d.activeSeconds, d.switches, d.focusBlocks, d.longestFocus, d.focusSeconds, d.switchesPerActiveHour] {
      #expect(f.value == 0)
      #expect(f.evidence.isEmpty)
      #expect(f.arithmetic == "nothing counted")
    }
    #expect(d.topApps.isEmpty && d.topSites.isEmpty && d.sessions.isEmpty)
  }

  @Test("INSIGHTS: InsightEvent reads stored lines and live events; unknown kinds are skipped")
  func eventAdapters() {
    let stored = StoredObservation(id: "o1", ts: "2026-11-20T09:41:07.250Z", kind: "focus", importID: "imp-9",
                                   appBundleID: "com.apple.Safari", appName: "Safari", title: "Inbox", host: "mail.example.com")
    let e = InsightEvent(stored: stored)
    #expect(e?.ts == M310Clock.date(2026, 11, 20, 9, 41, 7).addingTimeInterval(0.25))
    #expect(e?.origin == .imported("imp-9"))
    #expect(e?.host == "mail.example.com")
    #expect(InsightEvent(stored: StoredObservation(id: "o2", ts: "2026-11-20T09:41:07.000Z", kind: "keyframe", importID: "x")) == nil)
    let live = InsightEvent(local: LocalEvent(id: "l1", ts: 1_795_132_800_000, kind: "ocr", app: "com.apple.dt.Xcode", appName: "Xcode"))
    #expect(live?.kind == .textSnapshot)
    #expect(live?.origin == .live)
    #expect(InsightEvent(local: LocalEvent(id: "l2", ts: 1, kind: "mystery", app: nil, appName: nil)) == nil)
  }

  // MARK: SESSIONS

  static func span(_ app: (String, String), _ h: Int, _ m: Int, _ s: Int = 0, seconds: TimeInterval) -> ActivitySpan {
    let start = M310Clock.date(2026, 11, 20, h, m, s)
    return ActivitySpan(start: start, end: start.addingTimeInterval(seconds), appBundleID: app.0, appName: app.1,
                        title: nil, host: nil, firstEventID: "\(app.1)-\(h)\(m)\(s)")
  }

  @Test("SESSIONS: sessions split on an idle gap of 300 s or more")
  func sessionsSplitOnGap() {
    let spans = [Self.span(M310App.xcode, 9, 0, seconds: 600), Self.span(M310App.slack, 9, 15, seconds: 300),
                 Self.span(M310App.xcode, 9, 24, seconds: 360)]
    let s = LocalInsights.sessions(spans)
    #expect(s.count == 2)
    #expect(s.map(\.spans.count) == [1, 2])
    #expect(s[1].start == M310Clock.date(2026, 11, 20, 9, 15))
    #expect(s[1].end == M310Clock.date(2026, 11, 20, 9, 30))
  }

  @Test("SESSIONS: a session under 60 s is dropped")
  func shortSessionDropped() {
    #expect(LocalInsights.sessions([Self.span(M310App.xcode, 9, 0, seconds: 50)]).isEmpty)
    #expect(LocalInsights.sessions([Self.span(M310App.xcode, 9, 0, seconds: 60)]).count == 1)
  }

  @Test("SESSIONS: a focus block is 25 minutes or more with at most 2 switches per 10 minutes")
  func focusBlocks() {
    // 25 min, 2 switches: a focus block.
    let calm = [Self.span(M310App.xcode, 9, 0, seconds: 600), Self.span(M310App.safari, 9, 10, seconds: 300),
                Self.span(M310App.xcode, 9, 15, seconds: 600)]
    #expect(LocalInsights.sessions(calm).first?.isFocusBlock == true)
    // 24 min on one app: too short.
    #expect(LocalInsights.sessions([Self.span(M310App.xcode, 9, 0, seconds: 1440)]).first?.isFocusBlock == false)
    // 30 min with 11 switches: too many.
    var busy: [ActivitySpan] = []
    for i in 0..<12 { busy.append(Self.span(i % 2 == 0 ? M310App.xcode : M310App.slack, 10, i * 2, seconds: i == 11 ? 480 : 120)) }
    let s = LocalInsights.sessions(busy)
    #expect(s.count == 1 && s[0].switches == 11 && !s[0].isFocusBlock)
  }

  @Test("SESSIONS: spans under 10 s are folded into the step before them")
  func shortSpansFolded() {
    let spans = [Self.span(M310App.xcode, 9, 0, seconds: 300), Self.span(M310App.slack, 9, 5, 0, seconds: 8),
                 Self.span(M310App.xcode, 9, 5, 8, seconds: 292)]
    let steps = LocalInsights.steps(spans)
    #expect(steps.count == 1)
    #expect(steps[0].step.appName == "Xcode")
    #expect(steps[0].end == M310Clock.date(2026, 11, 20, 9, 10))
    #expect(LocalInsights.titleShape("Re: Invoice 2041 for <email:h_0123456789abcdef> today and then more words")
      == "re: invoice # for <email> today")
  }

  // MARK: REPEAT

  /// Three days (Mon to Wed of 2026-W47), each with one session of the pattern.
  static func threeDays(rules: [ImportExclusionRule] = []) -> [DayInsights] {
    [m310Day(2026, 11, 16, sessions: [(9, m310Pattern)], rules: rules),
     m310Day(2026, 11, 17, sessions: [(14, m310Pattern)], rules: rules),
     m310Day(2026, 11, 18, sessions: [(10, m310Pattern)], rules: rules)]
  }

  @Test("REPEAT: a 3-step sequence on 3 days is found once with 3 occurrences")
  func repeatFoundOnce() {
    let r = LocalInsights.repeats(days: Self.threeDays(), now: M310Clock.now, timeZone: M310Clock.utc)
    #expect(r.count == 1)
    #expect(r.first?.times == 3)
    #expect(r.first?.steps.map(\.appName) == ["Xcode", "Safari", "Slack"])
    #expect(r.first?.days == ["2026-11-16", "2026-11-17", "2026-11-18"])
  }

  @Test("REPEAT: a sequence seen on one day only is not a repeat")
  func repeatNeedsTwoDays() {
    let d = m310Day(2026, 11, 16, sessions: [(9, m310Pattern), (11, m310Pattern), (14, m310Pattern)])
    #expect(LocalInsights.repeats(days: [d], now: M310Clock.now, timeZone: M310Clock.utc).isEmpty)
  }

  @Test("REPEAT: a shorter sequence inside a longer one with the same occurrences is dropped")
  func repeatContainedDropped() {
    let r = LocalInsights.repeats(days: Self.threeDays(), now: M310Clock.now, timeZone: M310Clock.utc)
    #expect(!r.contains { $0.steps.count == 2 })
    // With an extra Xcode then Safari on a fourth day, the pair is seen more often and stays.
    let extra = m310Day(2026, 11, 19, sessions: [(9, Array(m310Pattern.prefix(2)))])
    let more = LocalInsights.repeats(days: Self.threeDays() + [extra], now: M310Clock.now, timeZone: M310Clock.utc)
    #expect(more.contains { $0.steps.count == 2 && $0.times == 4 })
  }

  @Test("REPEAT: a single-app run is never a repeat")
  func repeatNeedsTwoAppsOrHosts() {
    let steps: [(app: (String, String), title: String?, host: String?, minutes: Int)] = [
      (M310App.xcode, "Project one", nil, 10), (M310App.xcode, "Project two", nil, 10), (M310App.xcode, "Project one", nil, 10),
    ]
    let days = [m310Day(2026, 11, 16, sessions: [(9, steps)]), m310Day(2026, 11, 17, sessions: [(9, steps)]),
                m310Day(2026, 11, 18, sessions: [(9, steps)])]
    #expect(LocalInsights.repeats(days: days, now: M310Clock.now, timeZone: M310Clock.utc).isEmpty)
  }

  @Test("REPEAT: the key is k_ + 12 hex of the step keys and stable across runs")
  func repeatKey() throws {
    let a = try #require(LocalInsights.repeats(days: Self.threeDays(), now: M310Clock.now, timeZone: M310Clock.utc).first)
    let b = try #require(LocalInsights.repeats(days: Self.threeDays(), now: M310Clock.now, timeZone: M310Clock.utc).first)
    #expect(a.key == b.key)
    #expect(a.key == LocalInsights.taskKey(a.steps))
    let shape = try Regex("k_[0-9a-f]{12}")
    #expect(a.key.wholeMatch(of: shape) != nil)
  }

  @Test("REPEAT: the name is built from app names and hosts, never from text")
  func repeatName() throws {
    let r = try #require(LocalInsights.repeats(days: Self.threeDays(), now: M310Clock.now, timeZone: M310Clock.utc).first)
    #expect(r.name == "Xcode, then github.com in Safari, then Slack")
    #expect(!r.name.contains("Invoice") && !r.name.contains("Amara") && !r.name.contains("Pull"))
  }

  @Test("REPEAT: minutes per week and its arithmetic are exact for the fixture")
  func repeatMinutesPerWeek() throws {
    // 3 times, 30 minutes each, observed from Nov 9 to Nov 18 (10 days).
    let days = [m310Day(2026, 11, 9, sessions: [(9, m310Pattern)]), m310Day(2026, 11, 12, sessions: [(9, m310Pattern)]),
                m310Day(2026, 11, 18, sessions: [(9, m310Pattern)])]
    let r = try #require(LocalInsights.repeats(days: days, now: M310Clock.now, timeZone: M310Clock.utc).first)
    #expect(r.minutesPerWeek.value == 63)
    #expect(r.minutesPerWeek.unit == "minutes_per_week")
    #expect(r.minutesPerWeek.arithmetic == "3 times · 30 min median · 90 min over 10 days × 7 ÷ 10 = 63 min/week")
    #expect(r.minutesPerWeek.evidence.count == 3)
    #expect(r.medianMinutes == 30 && r.totalMinutes == 90)
    // Under a week of data, the divisor stays 7.
    let short = try #require(LocalInsights.repeats(days: Self.threeDays(), now: M310Clock.now, timeZone: M310Clock.utc).first)
    #expect(short.minutesPerWeek.arithmetic == "3 times · 30 min median · 90 min over 3 days × 7 ÷ 7 = 90 min/week")
  }

  @Test("REPEAT: confidence labels at each threshold")
  func repeatConfidence() {
    #expect(RepeatConfidence.of(days: 4, times: 6) == .high)
    #expect(RepeatConfidence.of(days: 4, times: 5) == .medium)
    #expect(RepeatConfidence.of(days: 3, times: 3) == .medium)
    #expect(RepeatConfidence.of(days: 2, times: 4) == .medium)
    #expect(RepeatConfidence.of(days: 2, times: 3) == .low)
    #expect([RepeatConfidence.high, .medium, .low].map(\.weight) == [1.0, 0.7, 0.4])
  }

  // MARK: RANK

  static func spreadDays() -> [DayInsights] {
    [m310Day(2026, 11, 9, sessions: [(9, m310Pattern)]), m310Day(2026, 11, 12, sessions: [(9, m310Pattern)]),
     m310Day(2026, 11, 18, sessions: [(9, m310Pattern)])]
  }

  @Test("RANK: golden factors give the exact score")
  func rankGoldenScore() throws {
    let r = try #require(LocalInsights.repeats(days: Self.spreadDays(), now: M310Clock.now, timeZone: M310Clock.utc).first)
    #expect(r.confidence == .medium)
    #expect(r.persistence == 1)
    #expect(r.goalWeight == 1 && r.declinePenalty == 1)
    #expect(abs(r.score - 63.0 / 60 * 1 * 1 * 0.7 * 1) < 1e-12)
  }

  @Test("RANK: a goal-linked answer gives goal weight 1.5")
  func rankGoalWeight() throws {
    let key = try #require(LocalInsights.repeats(days: Self.spreadDays(), now: M310Clock.now, timeZone: M310Clock.utc).first).key
    let answers = [LocalReviewAnswer(isoWeek: "2026-W47", subjectKey: key, answer: .keep, goalID: "g_0123456789",
                                     answeredAt: M310Clock.date(2026, 11, 19), minutesPerWeek: 63)]
    let r = try #require(LocalInsights.repeats(days: Self.spreadDays(), now: M310Clock.now, timeZone: M310Clock.utc,
                                               adjustments: RankingAdjustments(answers: answers), goals: ["g_0123456789"]).first)
    #expect(r.goalWeight == 1.5)
    #expect(abs(r.score - 63.0 / 60 * 0.7 * 1.5) < 1e-12)
    // A goal that is no longer the person's does not weigh.
    let gone = RankingAdjustments(answers: answers)
    #expect(gone.goalWeight(key: key, goals: ["g_ffffffffff"]) == 1)
    let noGoal = RankingAdjustments(answers: [LocalReviewAnswer(isoWeek: "2026-W47", subjectKey: key, answer: .keep,
                                                                answeredAt: M310Clock.date(2026, 11, 19), minutesPerWeek: 63)])
    #expect(noGoal.goalWeight(key: key, goals: []) == 1)
  }

  @Test("RANK: ties are broken by key")
  func rankTies() {
    let ranked = LocalInsights.rank([m310Ranked(key: "k_bbbbbbbbbbbb", score: 1), m310Ranked(key: "k_aaaaaaaaaaaa", score: 1),
                                     m310Ranked(key: "k_cccccccccccc", score: 2)])
    #expect(ranked.map(\.key) == ["k_cccccccccccc", "k_aaaaaaaaaaaa", "k_bbbbbbbbbbbb"])
  }

  @Test("RANK: only the top 5 not declined are things you repeat")
  func rankTopFive() {
    var all = (0..<7).map { m310Ranked(key: "k_00000000000\($0)", score: Double(10 - $0)) }
    all.append(m310Ranked(key: "k_declined0000", score: 0, penalty: 0))
    let top = LocalInsights.top(LocalInsights.rank(all))
    #expect(top.count == 5)
    #expect(top.map(\.key) == (0..<5).map { "k_00000000000\($0)" })
    let snapshot = InsightsSnapshot(days: [], repeats: LocalInsights.rank(all), observedDays: [], lastUpdated: nil)
    #expect(snapshot.thingsYouRepeat.count == 7)
    #expect(snapshot.topRepeats.count == 5)
  }

  @Test("RANK: persistence is ISO weeks present over ISO weeks observed, in the last 8 weeks")
  func rankPersistence() throws {
    let other: [(app: (String, String), title: String?, host: String?, minutes: Int)] = [(M310App.mail, "Inbox", nil, 20)]
    let days = [m310Day(2026, 9, 7, sessions: [(9, m310Pattern)]),        // W37: outside the 8 weeks
                m310Day(2026, 11, 2, sessions: [(9, other)]),               // W45: observed, no occurrence
                m310Day(2026, 11, 9, sessions: [(9, m310Pattern)]),         // W46
                m310Day(2026, 11, 18, sessions: [(9, m310Pattern)])]        // W47
    let r = try #require(LocalInsights.repeats(days: days, now: M310Clock.now, timeZone: M310Clock.utc).first)
    #expect(r.times == 3)
    #expect(r.weeksObserved == 3 && r.weeksPresent == 2)
    #expect(abs(r.persistence - 2.0 / 3) < 1e-12)
  }

  // MARK: ANSWERS

  @Test("ANSWERS: the file store round-trips, 0600 in a 0700 folder")
  func answersFileStore() throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let paths = OnDevicePaths(offloadSupport: root)
    let store = FileLocalAnswerStore(file: paths.answers)
    let a = LocalReviewAnswer(isoWeek: "2026-W47", subjectKey: "k_0123456789ab", answer: .otherGoal, goalID: "g_0123456789",
                              answeredAt: M310Clock.date(2026, 11, 20, 16), minutesPerWeek: 145)
    try store.record(a)
    #expect(FileLocalAnswerStore(file: paths.answers).answers() == [a])
    #expect(M310Files.mode(paths.answers) == 0o600)
    #expect(M310Files.mode(paths.root) == 0o700)
    let raw = try String(contentsOf: paths.answers, encoding: .utf8)
    #expect(raw.contains("\"subject_key\":\"k_0123456789ab\"") && raw.contains("\"answer\":\"other_goal\""))
  }

  @Test("ANSWERS: the latest answer per week and subject wins")
  func answersLatestWins() throws {
    let store = MemoryLocalAnswerStore()
    try store.record(LocalReviewAnswer(isoWeek: "2026-W47", subjectKey: "k_aaaaaaaaaaaa", answer: .notNow,
                                       answeredAt: M310Clock.date(2026, 11, 20, 16), minutesPerWeek: 60))
    try store.record(LocalReviewAnswer(isoWeek: "2026-W47", subjectKey: "k_aaaaaaaaaaaa", answer: .keep,
                                       answeredAt: M310Clock.date(2026, 11, 20, 17), minutesPerWeek: 60))
    try store.record(LocalReviewAnswer(isoWeek: "2026-W46", subjectKey: "k_aaaaaaaaaaaa", answer: .never,
                                       answeredAt: M310Clock.date(2026, 11, 13, 16), minutesPerWeek: 60))
    let all = store.answers()
    #expect(all.map(\.isoWeek) == ["2026-W46", "2026-W47"])
    #expect(all.last?.answer == .keep)
    #expect(RankingAdjustments(store: store).entries["k_aaaaaaaaaaaa"]?.answer == .keep)
  }

  @Test("ANSWERS: never and leave_alone drop a repeat")
  func answersNeverDrops() throws {
    let key = try #require(LocalInsights.repeats(days: Self.spreadDays(), now: M310Clock.now, timeZone: M310Clock.utc).first).key
    for answer in [LocalAnswer.never, .leaveAlone] {
      let adj = RankingAdjustments(answers: [LocalReviewAnswer(isoWeek: "2026-W46", subjectKey: key, answer: answer,
                                                               answeredAt: M310Clock.date(2026, 10, 1), minutesPerWeek: 63)])
      let r = LocalInsights.repeats(days: Self.spreadDays(), now: M310Clock.now, timeZone: M310Clock.utc, adjustments: adj)
      #expect(r.first?.isDeclined == true)
      #expect(r.first?.score == 0)
      #expect(LocalInsights.top(r).isEmpty)
    }
  }

  @Test("ANSWERS: not_now hides a repeat for 4 weeks, then it returns")
  func answersNotNowFourWeeks() {
    let at = M310Clock.date(2026, 11, 1)
    let adj = RankingAdjustments(answers: [LocalReviewAnswer(isoWeek: "2026-W44", subjectKey: "k_aaaaaaaaaaaa", answer: .notNow,
                                                             answeredAt: at, minutesPerWeek: 60)])
    #expect(adj.declinePenalty(key: "k_aaaaaaaaaaaa", minutesPerWeek: 60, now: at.addingTimeInterval(27 * 86_400)) == 0)
    #expect(adj.declinePenalty(key: "k_aaaaaaaaaaaa", minutesPerWeek: 60, now: at.addingTimeInterval(29 * 86_400)) == 1)
    #expect(adj.declinePenalty(key: "k_bbbbbbbbbbbb", minutesPerWeek: 60, now: at) == 1)
  }

  @Test("ANSWERS: a dropped repeat returns when its minutes per week rise 50% over the value at the answer")
  func answersReturnOnRise() {
    let at = M310Clock.date(2026, 11, 1)
    func adj(_ mpw: Int) -> RankingAdjustments {
      RankingAdjustments(answers: [LocalReviewAnswer(isoWeek: "2026-W44", subjectKey: "k_aaaaaaaaaaaa", answer: .never,
                                                     answeredAt: at, minutesPerWeek: mpw)])
    }
    #expect(adj(40).declinePenalty(key: "k_aaaaaaaaaaaa", minutesPerWeek: 60, now: M310Clock.now) == 1)
    #expect(adj(40).declinePenalty(key: "k_aaaaaaaaaaaa", minutesPerWeek: 59, now: M310Clock.now) == 0)
    #expect(adj(50).declinePenalty(key: "k_aaaaaaaaaaaa", minutesPerWeek: 63, now: M310Clock.now) == 0)
  }

  // MARK: EXCLUDE

  @Test("EXCLUDE: an app added to Never watch after import shows as Never watch app with its time and leaves every repeat")
  func excludeAppAfterImport() {
    let rules = [ImportExclusionRule(kind: .bundleID, value: M310App.slack.0)]
    let days = Self.threeDays(rules: rules)
    let never = days[0].perApp.first { $0.appName == "Never watch app" }
    #expect(never?.seconds.value == 600)
    #expect(!days[0].perApp.contains { $0.appName == "Slack" })
    #expect(days[0].activeSeconds.value == 1800)
    let r = LocalInsights.repeats(days: days, now: M310Clock.now, timeZone: M310Clock.utc)
    #expect(!r.isEmpty)
    for p in r {
      #expect(!p.steps.contains { $0.appBundleID == M310App.slack.0 || $0.appBundleID == LocalInsights.excludedAppID })
      #expect(!p.name.contains("Slack") && !p.name.contains("Never watch"))
    }
  }

  @Test("EXCLUDE: an excluded host drops from the top sites")
  func excludeHost() {
    let d = m310Day(2026, 11, 16, sessions: [(9, m310Pattern)], rules: [ImportExclusionRule(kind: .host, value: "github.com")])
    #expect(d.topSites.isEmpty)
    #expect(d.spans.contains { $0.excluded && $0.host == nil && $0.title == nil })
  }

  @Test("EXCLUDE: a title_contains entry drops matching titles from the steps")
  func excludeTitle() {
    let days = Self.threeDays(rules: [ImportExclusionRule(kind: .titleContains, value: "invoice")])
    let steps = days.flatMap { $0.sessions.flatMap(\.steps) }
    #expect(!steps.contains { ($0.step.titleShape ?? "").contains("invoice") })
    #expect(steps.contains { $0.excluded })
    let r = LocalInsights.repeats(days: days, now: M310Clock.now, timeZone: M310Clock.utc)
    #expect(!r.contains { $0.steps.contains { $0.appBundleID == M310App.xcode.0 } })
  }

  @Test("EXCLUDE: built-in exclusions apply (a password manager keeps its time only)")
  func excludeBuiltIns() {
    let steps: [(app: (String, String), title: String?, host: String?, minutes: Int)] = [(M310App.onePassword, "Bank login", nil, 5)]
    let d = m310Day(2026, 11, 16, sessions: [(9, steps)])
    #expect(d.perApp.map(\.appName) == ["Never watch app"])
    #expect(d.spans.allSatisfy { $0.title == nil })
  }

  @Test("EXCLUDE: a Never watch entry added later applies on the next refresh, without a new import")
  func excludeWithoutReimport() async throws {
    var e = M310Events(prefix: "x")
    e.session(M310Clock.date(2026, 11, 18, 9), m310Pattern)
    let rules = M310Rules()
    let store = InsightsStore(sources: InsightsStore.Sources(reader: M310Reader(e.events), exclusions: { rules.rules },
                                                             timeZone: M310Clock.utc, now: { M310Clock.now }))
    let before = await store.refreshAll()
    #expect(before.day("2026-11-18")?.perApp.contains { $0.appName == "Slack" } == true)
    rules.rules = [ImportExclusionRule(kind: .bundleID, value: M310App.slack.0)]
    let after = await store.refreshAll()
    #expect(after.day("2026-11-18")?.perApp.contains { $0.appName == "Slack" } == false)
    #expect(after.day("2026-11-18")?.perApp.contains { $0.appName == "Never watch app" } == true)
  }
}
