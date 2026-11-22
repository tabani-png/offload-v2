import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// m3-11-mac-today-live (slices/m3-11-mac-today-live/SPEC.md). Every test of this slice is a member of M311; the tests
// live in extensions of it, one file per area. Fixtures are synthetic local insights (built by m3-10's engine from
// synthetic events, or RepeatPatterns made directly) and brain-port shaped records. Nothing touches the network, the
// real Application Support folder, a window, TCC or a model.

@Suite struct M311 {}

/// A fixed clock: Thu 12 Nov 2026 18:00 UTC (ISO week 2026-W46, Mon 9 Nov to Sun 15 Nov).
enum M311Clock {
  static let utc = TimeZone(identifier: "UTC")!
  static let now = date(2026, 11, 12, 18)
  static let today = "2026-11-12"
  static let week = "2026-W46"

  static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
  }
}

/// A clock tests can move.
final class M311Now: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  init(_ d: Date = M311Clock.now) { current = d }
  var value: Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }
  func advance(_ seconds: TimeInterval) {
    lock.lock()
    current = current.addingTimeInterval(seconds)
    lock.unlock()
  }
  var clock: @Sendable () -> Date { { [self] in self.value } }
}

enum M311App {
  static let xcode = ("com.apple.dt.Xcode", "Xcode")
  static let safari = ("com.apple.Safari", "Safari")
  static let slack = ("com.tinyspeck.slackmacgap", "Slack")
  static let mail = ("com.apple.mail", "Mail")
  static let notes = ("com.apple.Notes", "Notes")
  static let figma = ("com.figma.Desktop", "Figma")
  static let terminal = ("com.apple.Terminal", "Terminal")
}

typealias M311Step = (app: (String, String), host: String?, minutes: Int)

/// One import's events in the readers' shape (m3-05 and m3-10 review 2): `idle_end`, a focus per step, `idle_start`
/// 120 s after the last activity (insights move it back).
struct M311Events {
  var origin: InsightEvent.Origin = .imported("imp-1")
  var prefix = "e"
  private(set) var events: [InsightEvent] = []

  init(prefix: String = "e") { self.prefix = prefix }

  private mutating func add(_ kind: InsightEvent.Kind, _ at: Date, app: (String, String)? = nil, host: String? = nil) {
    let id = String(format: "%@-%04d", prefix, events.count + 1)
    events.append(InsightEvent(id: id, ts: at, kind: kind, appBundleID: app?.0, appName: app?.1, title: nil, host: host,
                               origin: origin))
  }

  /// A session from `start`, one focus per step for its minutes.
  mutating func session(_ start: Date, _ steps: [M311Step]) {
    add(.idleEnd, start)
    var t = start
    for s in steps {
      add(.focus, t, app: s.app, host: s.host)
      t = t.addingTimeInterval(TimeInterval(s.minutes * 60))
    }
    add(.idleStart, t.addingTimeInterval(120))
  }
}

enum M311Fixture {
  /// One day of local insights from sessions (hour, minute, steps), UTC.
  static func day(_ label: String, _ sessions: [(h: Int, m: Int, steps: [M311Step])],
                  rules: [ImportExclusionRule] = []) -> DayInsights {
    let parts = label.split(separator: "-").map { Int($0)! }
    var e = M311Events(prefix: "d" + label.replacingOccurrences(of: "-", with: ""))
    for s in sessions { e.session(M311Clock.date(parts[0], parts[1], parts[2], s.h, s.m), s.steps) }
    return LocalInsights.day(e.events, day: label, timeZone: M311Clock.utc, exclusions: rules)
  }

  /// Fifty 4-minute steps alternating Mail and Slack: 200 minutes with 49 switches (not a focus block).
  static var busy: [M311Step] {
    (0..<50).map { i in (app: i % 2 == 0 ? M311App.mail : M311App.slack, host: nil, minutes: 4) }
  }

  /// The HEADER day (Thu 12 Nov): 460 active minutes ("7 h 40 m"); Xcode 190 min (41%); longest focus 90 min.
  ///   09:00 Xcode 90 · 11:00 Xcode 40, Slack 40 · 13:00 Xcode 60, github.com in Safari 30 · 14:40 Mail/Slack 200.
  static var workday: DayInsights {
    day("2026-11-12", [
      (9, 0, [(M311App.xcode, nil, 90)]),
      (11, 0, [(M311App.xcode, nil, 40), (M311App.slack, nil, 40)]),
      (13, 0, [(M311App.xcode, nil, 60), (M311App.safari, "github.com", 30)]),
      (14, 40, busy),
    ])
  }

  /// A day where no app holds 40%: four apps, 60 minutes each.
  static var spreadDay: DayInsights {
    day("2026-11-12", [
      (9, 0, [(M311App.xcode, nil, 60)]),
      (10, 30, [(M311App.slack, nil, 60)]),
      (12, 0, [(M311App.mail, nil, 60)]),
      (14, 0, [(M311App.notes, nil, 60)]),
    ])
  }

  /// Thu 5 Nov and Mon 9 Nov: a short day each.
  static var nov5: DayInsights { day("2026-11-05", [(10, 0, [(M311App.xcode, nil, 45)])]) }
  static var nov9: DayInsights { day("2026-11-09", [(10, 0, [(M311App.slack, nil, 30)])]) }

  static func snapshot(_ days: [DayInsights], repeats: [RepeatPattern] = []) -> InsightsSnapshot {
    let sorted = days.sorted { $0.day < $1.day }
    return InsightsSnapshot(days: sorted, repeats: repeats, observedDays: sorted.map(\.day), lastUpdated: M311Clock.now)
  }

  /// A repeat with occurrences on the given days, each `minutes` long (starting 10:00 + 2 h per extra one that day).
  static func pattern(key: String, name: String, occurrences: [(day: String, minutes: Int)], score: Double,
                      penalty: Double = 1, perWeek: Int = 120) -> RepeatPattern {
    var perDay: [String: Int] = [:]
    let occ: [RepeatOccurrence] = occurrences.enumerated().map { i, o in
      let p = o.day.split(separator: "-").map { Int($0)! }
      let n = perDay[o.day, default: 0]
      perDay[o.day] = n + 1
      let start = M311Clock.date(p[0], p[1], p[2], 10 + 2 * n)
      return RepeatOccurrence(day: o.day, start: start, end: start.addingTimeInterval(TimeInterval(o.minutes * 60)),
                              firstObservationID: "\(key)-obs-\(i + 1)")
    }
    let total = occurrences.reduce(0) { $0 + $1.minutes }
    let figure = Figure.local(Double(perWeek), unit: "minutes_per_week",
                              arithmetic: "\(occ.count) times · \(total) min over 9 days × 7 ÷ 9 = \(perWeek) min/week",
                              evidence: occ.map { .observation($0.firstObservationID) })
    return RepeatPattern(key: key, name: name, steps: [], occurrences: occ, days: Array(Set(occurrences.map(\.day))).sorted(),
                         medianMinutes: 0, totalMinutes: total, minutesPerWeek: figure, confidence: .high, weeksPresent: 1,
                         weeksObserved: 1, persistence: 1, goalWeight: 1, declinePenalty: penalty, score: score)
  }

  /// The top repeat of week 2026-W46: Mon 1, Tue 1, Wed 2, Thu 2, each 31 min ("6× · 3.1 h", "Mon–Thu"), plus one
  /// in the week before (not counted this week).
  static var reviewRepeat: RepeatPattern {
    pattern(key: "k_aaaaaaaaaaaa", name: "Xcode, then github.com in Safari, then Slack",
            occurrences: [("2026-11-02", 40), ("2026-11-09", 31), ("2026-11-10", 31), ("2026-11-11", 31), ("2026-11-11", 31),
                          ("2026-11-12", 31), ("2026-11-12", 31)],
            score: 9, perWeek: 186)
  }

  /// Five more repeats this week, lower ranked, plus one only in another week.
  static var moreRepeats: [RepeatPattern] {
    [
      pattern(key: "k_bbbbbbbbbbbb", name: "Mail, then Notes", occurrences: [("2026-11-09", 10), ("2026-11-13", 10)], score: 8),
      pattern(key: "k_cccccccccccc", name: "Slack, then Notes", occurrences: [("2026-11-10", 12)], score: 7),
      pattern(key: "k_dddddddddddd", name: "Figma, then Slack", occurrences: [("2026-11-11", 20)], score: 6),
      pattern(key: "k_eeeeeeeeeeee", name: "Terminal, then Xcode", occurrences: [("2026-11-12", 15)], score: 5),
      pattern(key: "k_ffffffffffff", name: "Notes, then Mail", occurrences: [("2026-11-15", 5)], score: 4),
      pattern(key: "k_gggggggggggg", name: "Last week only", occurrences: [("2026-11-03", 50)], score: 20),
    ]
  }

  static func local(_ snapshot: InsightsSnapshot, day: String = M311Clock.today, rhythm: Rhythm? = nil,
                    answers: [LocalReviewAnswer] = [], now: Date = M311Clock.now) -> TodayContent? {
    TodayContent.local(snapshot: snapshot, day: day, rhythm: rhythm, timeZone: M311Clock.utc, answers: answers, now: now)
  }
}

// MARK: - Cloud fixtures (the brain and build-loop ports' shapes)

enum M311Cloud {
  static func fig(_ v: Double, _ unit: String, _ arithmetic: String, _ ev: String = "ep_1") -> Figure {
    Figure(id: "fig_" + String(abs(arithmetic.hashValue % 1_000_000)), value: v, unit: unit, arithmetic: arithmetic,
           evidence: [EvidenceRef(kind: "episode", id: ev)], sourcePurgedAt: nil)
  }

  static func day(_ label: String = M311Clock.today, activeMinutes: Double = 460) -> DayRecord {
    DayRecord(
      day: label, generatedAt: "2026-11-12T18:00:00.000Z",
      totals: DayTotals(
        activeMinutes: fig(activeMinutes, "minutes", "sum of 41 spans' active time = \(activeMinutes) min"),
        switches: fig(57, "count", "57 times the app changed"),
        switchesPerActiveHour: fig(38, "per_hour", "57 switches / 1.5 h = 38 per active hour"),
        focusBlocks: fig(2, "count", "runs of one task lasting at least 25 min: 2"),
        focusMinutes: fig(90, "minutes", "active time in 2 focus blocks = 90 min"),
        meetingMinutes: fig(45, "minutes", "3 meeting spans = 45 min")),
      byKind: [
        KindMinutes(kind: "code", minutes: fig(200, "minutes", "active time of 10 code spans = 200 min")),
        KindMinutes(kind: "docs", minutes: fig(120, "minutes", "active time of 6 docs spans = 120 min")),
        KindMinutes(kind: "email", minutes: fig(60, "minutes", "active time of 5 email spans = 60 min")),
      ],
      byApp: [AppMinutes(app: "com.apple.dt.Xcode", minutes: fig(200, "minutes", "200 min in Xcode"))],
      byTask: [
        DayTask(taskKey: "k_0123456789ab", name: "Reconcile invoices", minutes: fig(65, "minutes", "3 instances = 65 min"),
                instances: fig(3, "count", "3 instances"), medianMinutes: fig(21, "minutes", "median 21 min")),
        DayTask(taskKey: "k_1123456789ab", name: "Review agent PRs", minutes: fig(90, "minutes", "2 instances = 90 min"),
                instances: fig(2, "count", "2 instances"), medianMinutes: fig(45, "minutes", "median 45 min")),
      ],
      episodeIDs: ["ep_1"], sourcePurgedAt: nil)
  }

  static func task(_ key: String, _ name: String, minutes: Double, instances: Double) -> WeekTask {
    WeekTask(taskKey: key, name: name, minutes: fig(minutes, "minutes", "sum of the task's minutes = \(minutes) min"),
             instances: fig(instances, "count", "sum of the task's instances = \(instances)"),
             medianMinutes: fig(20, "minutes", "median 20 min"), baselineMinutes: nil, vsBaseline: nil, status: .recurring)
  }

  static func week(_ iso: String = M311Clock.week) -> WeekRecord {
    WeekRecord(
      isoWeek: iso, from: "2026-11-09", to: "2026-11-15", daysRecorded: ["2026-11-09", "2026-11-12"],
      hours: WeekHours(total: fig(12, "hours", "sum = 12 h"), byKind: [], byApp: []),
      focus: WeekFocus(blocks: fig(4, "count", "4 blocks"), minutes: fig(180, "minutes", "180 min"),
                       switchesPerActiveHour: fig(30, "per_hour", "30 an hour"), meetingHours: fig(1, "hours", "1 h")),
      tasks: [
        task("k_t1", "Reconcile invoices", minutes: 62, instances: 3),
        task("k_t2", "Review agent PRs", minutes: 186, instances: 6),
        task("k_t3", "Once only", minutes: 300, instances: 1),
        task("k_t4", "Customer follow-up", minutes: 48, instances: 5),
      ],
      fixes: WeekFixes(estimated: [], measured: []), weeksObserved: 3, narrative: nil, generatedAt: "2026-11-12T18:00:00.000Z")
  }

  static func opportunity(_ id: String, rank: Int?, goal: OpportunityGoal? = OpportunityGoal(id: "g_1", text: "ship a product"),
                          options: [FixOption]? = nil) -> Opportunity {
    Opportunity(
      id: id, taskKey: "k_t2", title: "You've reviewed agent PRs 6 times this week.", rank: rank, state: .open,
      options: options ?? [
        FixOption(id: "fix_2", optionNo: 2, title: "Batch reviews into one 45-min block",
                  detail: "setup · a calendar block and one notification a day", recommended: false,
                  estimate: fig(0.6, "hours_per_week", "0.6 h/wk")),
        FixOption(id: "fix_1", optionNo: 1, title: "A checklist tool that pre-reads each agent PR",
                  detail: "tool · flags missing tests and risky files", recommended: true,
                  estimate: fig(1.4, "hours_per_week", "31 min × 6 × 0.45 = 1.4 h/wk")),
      ],
      goal: goal)
  }
}

extension M311Cloud {
  /// The planned `GET /v1/today` payload the server would send for these records: What you did from the day's tasks,
  /// the repeats from the week's tasks, the suggested fix the open opportunity ranked first, no grid cells.
  static func payload(day: DayRecord = day(), week: WeekRecord? = week(), opportunities: [Opportunity] = []) -> TodayPayload {
    TodayPayload(
      date: day.day, dayGrid: TodayDayGridPayload(categories: [], cells: [], switchBursts: []),
      whatYouDid: day.byTask.map { TodayDidItem(taskKey: $0.taskKey, name: $0.name, start: nil, minutes: $0.minutes) },
      repeats: (week?.tasks ?? []).map {
        TodayRepeatItem(taskKey: $0.taskKey, name: $0.name, instances: $0.instances, minutes: $0.minutes,
                        medianMinutes: $0.medianMinutes)
      },
      suggestedFix: TodayContent.nextOpportunity(opportunities, excluding: []))
  }

  /// The cloud content from the records' shapes, through the planned payload (the tests written before `GET /v1/today`
  /// keep their fixtures).
  static func content(day: DayRecord, week: WeekRecord?, opportunities: [Opportunity], today: String,
                      timeZone: TimeZone) -> TodayContent? {
    TodayContent.cloud(day: day, payload: payload(day: day, week: week, opportunities: opportunities), rhythm: nil,
                       today: today, timeZone: timeZone)
  }
}

/// Real-shaped JSON for the planned `GET /v1/today?date=` (API.md "Today, records and review"; field names as the
/// brain's records: snake_case, every number a Figure with `source_purged_at`).
enum M311TodayJSON {
  static func fig(_ id: String, _ value: String, _ unit: String, _ arithmetic: String) -> String {
    """
    {"id":"fig_\(id)","value":\(value),"unit":"\(unit)","arithmetic":"\(arithmetic)",\
    "evidence":[{"kind":"episode","id":"ep_01J\(id)"}],"source_purged_at":null}
    """
  }

  static let opportunity = """
    {"id":"opp_1","source":"finder","task_key":"k_t2","title":"You've reviewed agent PRs 6 times this week.",
     "description":"Agent PR reviews","iso_week":"2026-W46","rank":1,"state":"open","score":0.82,
     "factors":{"weekly_hours_saved":\(fig("f001", "1.4", "hours_per_week", "31 min × 6 × 0.45 = 1.4 h/wk")),
                "confidence":"high"},
     "options":[
       {"id":"fix_2","option_no":2,"kind":"routine","recommended":false,"title":"Batch reviews into one 45-min block",
        "detail":"setup · a calendar block and one notification a day",
        "estimate":\(fig("f002", "0.6", "hours_per_week", "0.6 h/wk")),"confidence":"medium","effort_hours":1},
       {"id":"fix_1","option_no":1,"kind":"tool","recommended":true,"title":"A checklist tool that pre-reads each agent PR",
        "detail":"tool · flags missing tests and risky files",
        "estimate":\(fig("f003", "1.4", "hours_per_week", "31 min × 6 × 0.45 = 1.4 h/wk")),"confidence":"high","effort_hours":3}
     ],
     "missing_connections":[],"goal":{"id":"g_1","text":"ship a product"},"not_now_until":null,
     "created_at":"2026-11-12T08:00:00.000Z"}
    """

  /// Thu 12 Nov: three kinds over 09:00 to 10:15 plus one email cell at 07:45, a burst at 10:00, two tasks done, four
  /// week tasks (one only once), the suggested fix above, and an item of each list that does not decode.
  static let full = """
    {
      "date":"2026-11-12",
      "day_grid":{
        "categories":[
          {"key":"code","name":"Coding","minutes":\(fig("c01", "200", "minutes", "active time of 10 code spans = 200 min"))},
          {"key":"docs","minutes":\(fig("c02", "120", "minutes", "active time of 6 docs spans = 120 min"))},
          {"key":"email","minutes":\(fig("c03", "60", "minutes", "active time of 5 email spans = 60 min"))}
        ],
        "cells":[
          {"start":"07:45","category":"email"},
          {"start":"09:00","category":"code"},
          {"start":"09:15","category":"code"},
          {"start":"09:30","category":null},
          {"start":"10:00","category":"docs"},
          {"start":"nonsense","category":"code"}
        ],
        "switch_bursts":[{"start":"10:00","switches":\(fig("b01", "5", "count", "5 app switches in 10:00 to 10:15"))}]
      },
      "what_you_did":[
        {"task_key":"k_0123456789ab","name":"Reconcile invoices","start":"09:00",
         "minutes":\(fig("d01", "65", "minutes", "3 instances = 65 min"))},
        {"task_key":"k_1123456789ab","name":"Review agent PRs","start":"13:05",
         "minutes":\(fig("d02", "90", "minutes", "2 instances = 90 min"))},
        {"name":"No minutes, so not drawn"}
      ],
      "repeats":[
        {"task_key":"k_t1","name":"Reconcile invoices","instances":\(fig("r01", "3", "count", "3 instances")),
         "minutes":\(fig("r02", "62", "minutes", "sum of 3 instances = 62 min")),
         "median_minutes":\(fig("r03", "20", "minutes", "median 20 min"))},
        {"task_key":"k_t2","name":"Review agent PRs","instances":\(fig("r04", "6", "count", "Mon 1 + Tue 1 + Wed 2 + Thu 2 = 6")),
         "minutes":\(fig("r05", "186", "minutes", "sum of 6 instances = 186 min"))},
        {"task_key":"k_t3","name":"Once only","instances":\(fig("r06", "1", "count", "1 instance")),
         "minutes":\(fig("r07", "300", "minutes", "300 min"))},
        {"task_key":"k_t4","name":"Customer follow-up","instances":\(fig("r08", "5", "count", "5 instances")),
         "minutes":\(fig("r09", "48", "minutes", "sum of 5 instances = 48 min"))},
        {"task_key":"k_bad","name":"A plain number","instances":4,"minutes":40}
      ],
      "suggested_fix":\(opportunity)
    }
    """

  static func payload(_ text: String = full) throws -> TodayPayload {
    try JSONDecoder().decode(TodayPayload.self, from: Data(text.utf8))
  }
}

/// A Today client that answers from a payload and records the days asked for.
final class M311Today: TodayClient, @unchecked Sendable {
  private let lock = NSLock()
  private var _calls: [String] = []
  private var result: @Sendable (String) throws -> TodayPayload

  init(_ result: @escaping @Sendable (String) throws -> TodayPayload = { day in
    var p = try M311TodayJSON.payload()
    p.date = day
    return p
  }) {
    self.result = result
  }

  var calls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }

  func set(_ f: @escaping @Sendable (String) throws -> TodayPayload) {
    lock.lock()
    result = f
    lock.unlock()
  }

  // NSLock may not be used directly in an async function (Swift 6): a synchronous helper takes the call.
  private func take(_ day: String) -> @Sendable (String) throws -> TodayPayload {
    lock.lock()
    defer { lock.unlock() }
    _calls.append(day)
    return result
  }

  func today(date: String) async throws -> TodayPayload {
    try take(date)(date)
  }
}

/// A brain client that answers from fixtures and counts calls.
final class M311Brain: BrainClient, @unchecked Sendable {
  private let lock = NSLock()
  private var _dayCalls: [String] = []
  private var _weekCalls: [String] = []
  var dayResult: @Sendable (String) throws -> DayRecord
  var weekResult: @Sendable (String) throws -> WeekRecord
  /// Runs before a day is answered (a test steps to another day while a read is out).
  private var beforeDay: (@Sendable (String) async -> Void)?

  init(day: @escaping @Sendable (String) throws -> DayRecord = { M311Cloud.day($0) },
       week: @escaping @Sendable (String) throws -> WeekRecord = { M311Cloud.week($0) }) {
    dayResult = day
    weekResult = week
  }

  var dayCalls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _dayCalls
  }

  var weekCalls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _weekCalls
  }

  private func note(day: String? = nil, week: String? = nil) {
    lock.lock()
    if let day { _dayCalls.append(day) }
    if let week { _weekCalls.append(week) }
    lock.unlock()
  }

  func setDay(_ f: @escaping @Sendable (String) throws -> DayRecord) {
    lock.lock()
    dayResult = f
    lock.unlock()
  }

  func setBeforeDay(_ f: @escaping @Sendable (String) async -> Void) {
    lock.lock()
    beforeDay = f
    lock.unlock()
  }

  private func hook() -> (@Sendable (String) async -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return beforeDay
  }

  private func dayFn() -> @Sendable (String) throws -> DayRecord {
    lock.lock()
    defer { lock.unlock() }
    return dayResult
  }

  func profile() async throws -> BrainProfile { throw APIError.notFound }
  func updateProfile(_ patch: BrainProfilePatch) async throws -> BrainProfile { throw APIError.notFound }
  func dayRecord(day: String) async throws -> DayRecord {
    note(day: day)
    if let hook = hook() { await hook(day) }
    return try dayFn()(day)
  }
  func weekRecord(isoWeek: String) async throws -> WeekRecord {
    note(week: isoWeek)
    return try weekResult(isoWeek)
  }
  func weekReview(isoWeek: String) async throws -> WeekReview { throw APIError.notFound }
  func answer(_ body: ReviewAnswerRequest) async throws -> ReviewAnswer { throw APIError.notFound }
}

/// A builds client with fixed open opportunities; records answers.
final class M311Builds: BuildsClient, @unchecked Sendable {
  private let lock = NSLock()
  private var _calls = 0
  private var _answers: [(String, OpportunityAnswer, String?)] = []
  let open: [Opportunity]
  /// When set, every answer fails with it.
  let answerFailure: APIError?
  /// What `GET /v1/opportunities/{id}` answers, by id (else 404).
  let full: [String: Opportunity]
  private var _opportunityCalls: [String] = []

  init(open: [Opportunity] = [M311Cloud.opportunity("opp_1", rank: 1)], answerFailure: APIError? = nil,
       full: [String: Opportunity] = [:]) {
    self.open = open
    self.answerFailure = answerFailure
    self.full = full
  }

  var opportunityCalls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _opportunityCalls
  }

  private func noteOpportunity(_ id: String) {
    lock.lock()
    _opportunityCalls.append(id)
    lock.unlock()
  }

  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }

  var answers: [(String, OpportunityAnswer, String?)] {
    lock.lock()
    defer { lock.unlock() }
    return _answers
  }

  // NSLock's lock() and unlock() are unavailable in async functions (Swift 6), so the async client methods below
  // only call these synchronous helpers.
  private func count() {
    lock.lock()
    _calls += 1
    lock.unlock()
  }

  private func record(_ id: String, _ answer: OpportunityAnswer, _ optionID: String?) {
    lock.lock()
    _answers.append((id, answer, optionID))
    lock.unlock()
  }

  func openOpportunities() async throws -> [Opportunity] {
    count()
    return open
  }
  func opportunity(id: String) async throws -> Opportunity {
    noteOpportunity(id)
    guard let o = full[id] else { throw APIError.notFound }
    return o
  }
  func answerOpportunity(id: String, answer: OpportunityAnswer, optionID: String?) async throws -> Opportunity {
    if let answerFailure { throw answerFailure }
    record(id, answer, optionID)
    return Opportunity(id: id, title: "", state: .notNow)
  }
  func fix(id: String) async throws -> Fix { throw APIError.notFound }
  func okBuild(fixID: String, hashes: FixHashes) async throws -> BuildStarted { throw APIError.signingUnavailable }
  func build(id: String) async throws -> Build { throw APIError.notFound }
  func cancel(id: String) async throws -> Build { throw APIError.notFound }
  func definition(id: String) async throws -> BuildDefinition { throw APIError.notFound }
  func deploy(id: String, hashes: DeployHashes) async throws -> Deployed { throw APIError.signingUnavailable }
  func outcomes(month: String) async throws -> [FixOutcome] { [] }
}

struct M311Token: MemberTokenProvider {
  func currentToken() -> String? { "m311-member-token" }
}

enum M311Backends {
  static let base = URL(string: "https://api.example.test")!
  static var config: BackendConfig { BackendConfig(baseURL: base, tokens: M311Token()) }

  static func cloud(brain: any BrainClient = M311Brain(), builds: any BuildsClient = M311Builds()) -> Backends {
    Backends(mode: .cloud(config), brain: brain, builds: builds, provenance: .cloud)
  }
}

/// The app over m3-04's fakes: a finished setup in Local mode (route Today), injected insights and recordings.
@MainActor struct M311Kit {
  let fakes = M304Services()
  let store: InMemoryOnboardingStore

  init(completed: Bool = true) {
    var s = OnboardingState()
    s.completed = completed
    if completed { s.screen = .done }
    store = InMemoryOnboardingStore(state: s)
  }

  func app(backends: Backends = .local, insights: InsightsModel = InsightsModel.empty(timeZone: M311Clock.utc),
           recordings: RecordingsImportModel? = nil) -> AppModel {
    let services = OnboardingServices(
      account: fakes.account, consent: fakes.consent, uploader: fakes.uploader, capture: fakes.capture,
      profile: fakes.profile, neverWatch: fakes.neverWatch, exclusions: fakes.exclusions, connections: fakes.connections,
      loginItem: fakes.loginItem, relauncher: fakes.relauncher, sampleWeek: fakes.sampleWeek, recordings: recordings
    )
    return AppModel(options: LaunchOptions(), bundlePath: "/Applications/Offload.app", bufferReadable: true, store: store,
                    services: services, probe: FakePermissionProbe(), events: NoLocalEvents(), sampleWeek: SampleWeekFlag(),
                    backends: backends, insights: insights)
  }

  /// A recordings model with no importer (m3-05's fakes): tests drive its phase with `apply`.
  static func recordings() -> RecordingsImportModel {
    RecordingsImportModel(store: MemoryRecordingsFolderStore(), picker: FakeFolderPicker(), panel: FakeImportPanel(),
                          importer: nil, sink: nil, ledger: nil, durations: { _ in nil },
                          suggestedFolder: URL(fileURLWithPath: "/nowhere"), protected: [])
  }

  /// A local model over a published snapshot; ranking reloads are left to the test (no store behind the snapshot).
  static func localModel(_ snapshot: InsightsSnapshot, now: M311Now = M311Now(), recordings: RecordingsImportModel? = nil,
                         kit: M311Kit = M311Kit()) -> (TodayLiveModel, AppModel) {
    let insights = InsightsModel.empty(timeZone: M311Clock.utc)
    insights.publish(snapshot)
    let app = kit.app(insights: insights, recordings: recordings)
    let model = TodayLiveModel(app: app, now: now.clock, reloadRanking: {})
    return (model, app)
  }

  /// A `.cloud` model. `todayAPI` is the `TodayAPI.available` flag (on here: the planned `GET /v1/today` is read
  /// through `today`); off shows the labelled sample.
  static func cloudModel(brain: M311Brain = M311Brain(), builds: any BuildsClient = M311Builds(),
                         today: M311Today = M311Today(), todayAPI: Bool = true,
                         now: M311Now = M311Now()) -> (TodayLiveModel, AppModel) {
    let app = M311Kit().app(backends: M311Backends.cloud(brain: brain, builds: builds))
    let model = TodayLiveModel(app: app, now: now.clock, reloadRanking: {}, todayAPI: todayAPI, todayClient: today)
    return (model, app)
  }
}

extension TodayLiveModel {
  /// The content when ready, for short expectations.
  var ready: TodayContent? {
    if case .ready(let c) = state { return c }
    return nil
  }
}

/// A LocalAnswerStore whose writes fail (a full disk, a locked file).
struct M311FailingAnswers: LocalAnswerStore {
  struct WriteFailed: Error {}
  func answers() -> [LocalReviewAnswer] { [] }
  func record(_ answer: LocalReviewAnswer) throws { throw WriteFailed() }
}
