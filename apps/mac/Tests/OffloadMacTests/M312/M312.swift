import Foundation
import Testing
@testable import OffloadMac

// m3-12-mac-weekly-review (slices/m3-12-mac-weekly-review/SPEC.md). Every test of this slice is a member of M312; the
// tests live in extensions of it, one file per area. Clocks and time zones are fixed; local weeks are built from
// synthetic imported events through m3-10's LocalInsights, so the review reads exactly what the app would count.
// Cloud tests answer from a RecordingTransport with the brain port's JSON; nothing touches the network,
// UNUserNotificationCenter, a window or a model.

@Suite struct M312 {}

/// Fixed clocks. `now` is Fri 20 Nov 2026 18:00 UTC: ISO week 2026-W47 (Mon 16 to Sun 22 Nov), after the default
/// Friday 4:00 PM slot.
enum M312Clock {
  static let utc = TimeZone(identifier: "UTC")!
  static let now = date(2026, 11, 20, 18)

  static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0, tz: TimeZone = utc) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
  }

  /// The Monday of an ISO week of 2026 (W47 is 16 Nov), at `hour` UTC, plus `day` days.
  static func monday(week: Int, day: Int = 0, hour: Int = 9) -> Date {
    // 2026-W01 starts Mon 29 Dec 2025.
    let w1 = date(2025, 12, 29, hour)
    return w1.addingTimeInterval(TimeInterval(((week - 1) * 7 + day) * 86_400))
  }

  static func week(_ id: String, tz: TimeZone = utc) -> ISOWeek { ISOWeek(id, timeZone: tz)! }
}

enum M312App {
  static let xcode = ("com.apple.dt.Xcode", "Xcode")
  static let safari = ("com.apple.Safari", "Safari")
  static let slack = ("com.tinyspeck.slackmacgap", "Slack")
  static let notes = ("com.apple.Notes", "Notes")

  /// Ten made-up apps for patterns that must not merge ("A" … "J").
  static func letter(_ c: String) -> (String, String) { ("test.app.\(c.lowercased())", c) }
}

typealias M312Step = (app: (String, String), host: String?, minutes: Int)

/// Builds imported events in the readers' shape (m3-05): `idle_end`, a focus per step, `idle_start` 120 s after the
/// session's last activity. Ids sort in the order the events were added.
struct M312Events {
  var origin: InsightEvent.Origin
  /// Event ids are `<prefix>-00001`, …: two builders in one test use different prefixes.
  var prefix: String
  private(set) var events: [InsightEvent] = []

  init(origin: InsightEvent.Origin = .imported("imp-m312"), prefix: String = "m312") {
    self.origin = origin
    self.prefix = prefix
  }

  private mutating func add(_ kind: InsightEvent.Kind, _ at: Date, app: (String, String)? = nil, host: String? = nil) {
    let id = prefix + "-" + ISOWeek.pad(events.count + 1, 5)
    events.append(InsightEvent(id: id, ts: at, kind: kind, appBundleID: app?.0, appName: app?.1, title: nil, host: host,
                               origin: origin))
  }

  mutating func session(_ start: Date, _ steps: [M312Step]) {
    add(.idleEnd, start)
    var t = start
    for s in steps {
      add(.focus, t, app: s.app, host: s.host)
      t = t.addingTimeInterval(TimeInterval(s.minutes * 60))
    }
    add(.idleStart, t.addingTimeInterval(120))
  }

  /// One Xcode session of `minutes` (a focus block from 25 minutes).
  mutating func focus(_ start: Date, minutes: Int) {
    let step: M312Step = (app: M312App.xcode, host: nil, minutes: minutes)
    session(start, [step])
  }

  /// `steps` steps of 2 minutes alternating Safari and Slack: never a focus block.
  mutating func choppy(_ start: Date, steps: Int) {
    let list: [M312Step] = (0..<steps).map { i -> M312Step in
      (app: i % 2 == 0 ? M312App.safari : M312App.slack, host: nil, minutes: 2)
    }
    session(start, list)
  }

  /// The repeat of the fixtures: Xcode, then github.com in Safari, then Slack, 10 minutes each.
  mutating func pattern(_ start: Date) {
    let steps: [M312Step] = [
      (app: M312App.xcode, host: nil, minutes: 10),
      (app: M312App.safari, host: "github.com", minutes: 10),
      (app: M312App.slack, host: nil, minutes: 10),
    ]
    session(start, steps)
  }
}

/// The name LocalInsights gives the fixture's repeat.
let m312PatternName = "Xcode, then github.com in Safari, then Slack"

enum M312Data {
  /// A snapshot as InsightsStore would publish it: days with data and the repeats ranked with the answers (no goal
  /// filter, as the app's store).
  static func snapshot(_ events: [InsightEvent], answers: [LocalReviewAnswer] = [], now: Date = M312Clock.now,
                       tz: TimeZone = M312Clock.utc) -> InsightsSnapshot {
    let labels = Array(Set(events.map { LocalDays.label($0.ts, timeZone: tz) })).sorted()
    let byDay = LocalInsights.days(events, labels: labels, timeZone: tz, exclusions: [])
    let days = labels.compactMap { byDay[$0] }.filter { !$0.isEmpty }
    let repeats = LocalInsights.repeats(days: days, now: now, timeZone: tz, adjustments: RankingAdjustments(answers: answers))
    return InsightsSnapshot(days: days, repeats: repeats, observedDays: days.map(\.day), lastUpdated: now)
  }

  /// One week per entry, each one Monday Xcode session of the given minutes (active time = deep work, no switches).
  static func focusWeeks(_ minutesByWeek: [(week: Int, minutes: Int)]) -> [InsightEvent] {
    var e = M312Events()
    for w in minutesByWeek { e.focus(M312Clock.monday(week: w.week, hour: 6), minutes: w.minutes) }
    return e.events
  }

  /// The TILES week: Mon and Tue of W47, each a 60 min Xcode focus block and a 20 min choppy session of 10 steps.
  /// Per day 80 min active and 10 switches; the week 160 min (2.7 h), 120 min deep work (2 h), 20 switches ÷
  /// 2.67 h = 7.5 an hour.
  static var tilesWeek: [InsightEvent] {
    var e = M312Events()
    for day in 0..<2 {
      e.focus(M312Clock.monday(week: 47, day: day, hour: 9), minutes: 60)
      e.choppy(M312Clock.monday(week: 47, day: day, hour: 14), steps: 10)
    }
    return e.events
  }

  /// The pattern `counts[i]` times in week `firstWeek + i` (one session a day from Monday on, at 10:00).
  static func patternWeeks(firstWeek: Int, counts: [Int], into e: inout M312Events) {
    for (i, n) in counts.enumerated() {
      for day in 0..<n { e.pattern(M312Clock.monday(week: firstWeek + i, day: day, hour: 10)) }
    }
  }

  static func patternWeeks(firstWeek: Int, counts: [Int]) -> [InsightEvent] {
    var e = M312Events()
    patternWeeks(firstWeek: firstWeek, counts: counts, into: &e)
    return e.events
  }

  /// Five two-app patterns (A then B, C then D, …), each 3 times in W47 (Mon, Tue, Wed), the first longest so the
  /// ranking is A, C, E, G, I.
  static var fivePatterns: [InsightEvent] {
    var e = M312Events()
    let pairs = [("A", "B"), ("C", "D"), ("E", "F"), ("G", "H"), ("I", "J")]
    for day in 0..<3 {
      for (i, p) in pairs.enumerated() {
        let minutes = 12 - i * 2  // 12, 10, 8, 6, 4 per step
        let steps: [M312Step] = [
          (app: M312App.letter(p.0), host: nil, minutes: minutes),
          (app: M312App.letter(p.1), host: nil, minutes: minutes),
        ]
        e.session(M312Clock.monday(week: 47, day: day, hour: 8 + i * 2), steps)
      }
    }
    return e.events
  }

  /// The key of the repeat whose name is `name` in the snapshot.
  static func key(_ snapshot: InsightsSnapshot, named name: String) -> String {
    snapshot.repeats.first { $0.name == name }?.key ?? "missing"
  }
}

/// Imported events from a fixed list.
struct M312Reader: InsightEventReader {
  let all: [InsightEvent]
  init(_ events: [InsightEvent]) { all = events }
  func events(in interval: DateInterval) -> [InsightEvent] { all.filter { $0.ts >= interval.start && $0.ts < interval.end } }
  func dayLabels(timeZone: TimeZone) -> [String] {
    Array(Set(all.map { LocalDays.label($0.ts, timeZone: timeZone) })).sorted()
  }
}

/// A token for building `.cloud` without any network.
struct M312Token: MemberTokenProvider {
  func currentToken() -> String? { "m312-member-token" }
}

@MainActor
enum M312Kit {
  /// Local insights over `events`, counted once, with `answers` as its answer store.
  static func insights(_ events: [InsightEvent], answers: any LocalAnswerStore = MemoryLocalAnswerStore(),
                       now: Date = M312Clock.now) async -> InsightsModel {
    let store = InsightsStore(sources: InsightsStore.Sources(reader: M312Reader(events), answers: answers,
                                                             timeZone: M312Clock.utc, now: { now }))
    let model = InsightsModel(store: store)
    await model.refreshAll()
    return model
  }

  static func cloudBackends(_ transport: RecordingTransport) -> Backends {
    let config = BackendConfig(baseURL: URL(string: "https://api.example.test")!, tokens: M312Token())
    let core = APIClientCore(config: config, transport: transport, signer: nil)
    return Backends(mode: .cloud(config), brain: HTTPBrainClient(core: core), builds: nil, provenance: .cloud)
  }

  static func model(backends: Backends = .local, insights: InsightsModel, navigation: NavigationModel = NavigationModel(),
                    goals: [String] = [], slot: ReviewSlot = ReviewSlot(day: .fri, time: "16:00", timeZone: M312Clock.utc),
                    now: Date = M312Clock.now) -> WeeklyReviewModel {
    WeeklyReviewModel(backends: backends, insights: insights, navigation: navigation, goals: { goals }, slot: { slot },
                      now: { now })
  }

  static func body(_ request: URLRequest) -> String { String(decoding: request.httpBody ?? Data(), as: UTF8.self) }
}

/// The brain port's JSON (buildWeekReview, parseReviewAnswer, defaultProfile). Synthetic: no real person's data.
enum M312Fixtures {
  static let review = #"{"iso_week":"2026-W47","sentence":"You worked 5.21 h this week: 71 min in focus blocks and 0.75 h in meetings.","tiles":[{"id":"fig_2c85640bc0da46fd","value":5.21,"unit":"hours","arithmetic":"sum of 1 day records' active minutes (312.5 min) / 60 = 5.21 h","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},{"id":"fig_41716091fda3611a","value":71,"unit":"minutes","arithmetic":"sum of focus minutes on 1 days = 71 min","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},{"id":"fig_59f504e7ad0ef358","value":0.75,"unit":"hours","arithmetic":"sum of meeting minutes on 1 days / 60 = 0.75 h","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},{"id":"fig_65c308ec4f932000","value":10.9,"unit":"per_hour","arithmetic":"57 switches / (312.5 min / 60) = 10.9 per active hour","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null}],"goals":[{"id":"g_a41535a1d6","text":"Ship the Mac app"},{"id":"g_0b1c2d3e4f","text":"Close customers"}],"questions":[{"subject_key":"k_0123456789ab","question_kind":"opportunity","name":"Reconcile invoices","answers":["keep","not_now","build","never","leave_alone","other_goal"],"answered":"keep"},{"subject_key":"k_ba9876543210","question_kind":"opportunity","name":"Weekly report","answers":["keep","not_now","build","never","leave_alone","other_goal"],"answered":null}]}"#

  static let answer = #"{"iso_week":"2026-W47","subject_key":"k_ba9876543210","question_kind":"opportunity","answer":"not_now","goal_id":null,"answered_at":"2026-11-20T18:00:00.000Z"}"#

  static let notFound = #"{"error":{"code":"not_found","message":"that week has not happened yet","request_id":"req_01JCA0000000000000000000A1"}}"#

  static func profile(day: String, time: String) -> String {
    #"{"version":2,"role":null,"industry":null,"goals":[],"drains":[],"schedule":null,"timezone":"UTC","review_slot":{"day":""# + day + #"","time":""# + time + #""},"autonomy":"suggest","own_name_to_models":"mask","keyframes_to_cloud":false,"learning_paused":false,"updated_at":null}"#
  }
}
