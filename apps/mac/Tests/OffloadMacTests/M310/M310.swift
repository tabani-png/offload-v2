import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// m3-10-mac-recordings-analysis (slices/m3-10-mac-recordings-analysis/SPEC.md). Every test of this slice is a member
// of M310; the tests live in extensions of it, one file per area. Vision runs for real in one OCR test on a
// CoreText-rendered image; everything else injects recognizers, clocks, stores and transports. Nothing touches the
// network, the real Application Support folder, the Keychain, TCC, a window or a model.

@Suite struct M310 {}

/// A fixed clock: Fri 20 Nov 2026 18:00 UTC (ISO week 2026-W47).
enum M310Clock {
  static let utc = TimeZone(identifier: "UTC")!
  static let now = date(2026, 11, 20, 18)

  static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0, tz: TimeZone = utc) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
  }
}

enum M310Files {
  /// A fresh empty folder under the temporary directory.
  static func folder(_ name: String = "Support") -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("m310-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func remove(_ dir: URL) { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

  static func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
  }
}

/// Apps with the bundle ids MenuBarApp and the built-ins use.
enum M310App {
  static let xcode = ("com.apple.dt.Xcode", "Xcode")
  static let safari = ("com.apple.Safari", "Safari")
  static let slack = ("com.tinyspeck.slackmacgap", "Slack")
  static let mail = ("com.apple.mail", "Mail")
  static let onePassword = ("com.1password.1password", "1Password")
}

/// Builds one origin's events in order, with sortable ids ("a-001", "a-002", …).
struct M310Events {
  var origin: InsightEvent.Origin
  var prefix: String
  private(set) var events: [InsightEvent] = []

  init(origin: InsightEvent.Origin = .imported("imp-1"), prefix: String = "a") {
    self.origin = origin
    self.prefix = prefix
  }

  private mutating func add(_ kind: InsightEvent.Kind, _ at: Date, app: (String, String)? = nil, title: String? = nil,
                            host: String? = nil) {
    let id = String(format: "%@-%03d", prefix, events.count + 1)
    events.append(InsightEvent(id: id, ts: at, kind: kind, appBundleID: app?.0, appName: app?.1, title: title, host: host,
                               origin: origin))
  }

  mutating func focus(_ at: Date, _ app: (String, String), title: String? = nil, host: String? = nil) {
    add(.focus, at, app: app, title: title, host: host)
  }
  mutating func idleEnd(_ at: Date) { add(.idleEnd, at) }
  mutating func idleStart(_ at: Date) { add(.idleStart, at) }
  mutating func text(_ at: Date) { add(.textSnapshot, at) }

  /// One session: `idle_end`, a focus per step for its minutes, `idle_start` at the end.
  mutating func session(_ start: Date, _ steps: [(app: (String, String), title: String?, host: String?, minutes: Int)]) {
    idleEnd(start)
    var t = start
    for s in steps {
      focus(t, s.app, title: s.title, host: s.host)
      t = t.addingTimeInterval(TimeInterval(s.minutes * 60))
    }
    idleStart(t)
  }

  /// The id of the n-th event (1-based).
  func id(_ n: Int) -> String { String(format: "%@-%03d", prefix, n) }
}

/// The pattern of the REPEAT fixture: Xcode, then github.com in Safari, then Slack, 10 minutes each.
let m310Pattern: [(app: (String, String), title: String?, host: String?, minutes: Int)] = [
  (M310App.xcode, "Invoice 2041 for Amara Okafor", nil, 10),
  (M310App.safari, "Pull request 41", "github.com", 10),
  (M310App.slack, "#ops", nil, 10),
]

/// One day of insights from sessions starting at the given hours (UTC), each with the given steps.
func m310Day(_ y: Int, _ m: Int, _ d: Int, sessions: [(hour: Int, steps: [(app: (String, String), title: String?, host: String?, minutes: Int)])],
             rules: [ImportExclusionRule] = [], prefix: String? = nil) -> DayInsights {
  let label = String(format: "%04d-%02d-%02d", y, m, d)
  var e = M310Events(prefix: prefix ?? "d\(m)\(d)")
  for s in sessions { e.session(M310Clock.date(y, m, d, s.hour), s.steps) }
  return LocalInsights.day(e.events, day: label, timeZone: M310Clock.utc, exclusions: rules)
}

/// A ranked pattern with only the fields a ranking test needs.
func m310Pattern(key: String, score: Double, penalty: Double = 1, minutesPerWeek: Int = 60) -> RepeatPattern {
  RepeatPattern(key: key, name: "Xcode, then Slack", steps: [], occurrences: [], days: ["2026-11-16", "2026-11-17"],
                medianMinutes: 20, totalMinutes: 60, minutesPerWeek: Figure.local(Double(minutesPerWeek), unit: "minutes_per_week",
                                                                                   arithmetic: "fixture", evidence: []),
                confidence: .medium, weeksPresent: 1, weeksObserved: 1, persistence: 1, goalWeight: 1,
                declinePenalty: penalty, score: score)
}

/// Insight events from a mutable list (an import that can be removed).
final class M310Reader: InsightEventReader, @unchecked Sendable {
  private let lock = NSLock()
  private var all: [InsightEvent]

  init(_ events: [InsightEvent] = []) { all = events }

  func set(_ events: [InsightEvent]) {
    lock.lock()
    all = events
    lock.unlock()
  }

  func events(in interval: DateInterval) -> [InsightEvent] {
    lock.lock()
    defer { lock.unlock() }
    return all.filter { $0.ts >= interval.start && $0.ts < interval.end }
  }

  func dayLabels(timeZone: TimeZone) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return Array(Set(all.map { LocalDays.label($0.ts, timeZone: timeZone) })).sorted()
  }
}

/// m3-04's live buffer, faked: events with `from < ts <= to`.
struct M310LiveEvents: LocalEventSource {
  var events: [LocalEvent]
  func events(from: Int64, to: Int64) -> [LocalEvent] { events.filter { $0.ts > from && $0.ts <= to } }
  func captureStartedAt() -> Int64? { events.first?.ts }
}

func m310Ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

/// Never watch rules that can change after an import.
final class M310Rules: @unchecked Sendable {
  private let lock = NSLock()
  private var current: [ImportExclusionRule] = []
  var rules: [ImportExclusionRule] {
    get {
      lock.lock()
      defer { lock.unlock() }
      return current
    }
    set {
      lock.lock()
      current = newValue
      lock.unlock()
    }
  }
}

/// A member token, for building a `.cloud` mode without any network.
struct M310Token: MemberTokenProvider {
  var token: String? = "member-token-for-tests"
  func currentToken() -> String? { token }
}

/// A fixed pseudonym key for the masker.
let m310Key = Data(repeating: 7, count: 32)

/// The services of m3-04's fakes with a given onboarding state and a recordings model.
@MainActor struct M310AppKit {
  let fakes = M304Services()
  let store: InMemoryOnboardingStore

  init(state: OnboardingState = OnboardingState()) { store = InMemoryOnboardingStore(state: state) }

  func services(recordings: RecordingsImportModel?) -> OnboardingServices {
    OnboardingServices(
      account: fakes.account, consent: fakes.consent, uploader: fakes.uploader, capture: fakes.capture,
      profile: fakes.profile, neverWatch: fakes.neverWatch, exclusions: fakes.exclusions, connections: fakes.connections,
      loginItem: fakes.loginItem, relauncher: fakes.relauncher, sampleWeek: fakes.sampleWeek, recordings: recordings
    )
  }

  func app(recordings: RecordingsImportModel? = nil, backends: Backends = .local, insights: InsightsModel? = nil,
           onDevice: OnDeviceRecordings? = nil) -> AppModel {
    AppModel(options: LaunchOptions(), bundlePath: "/Applications/Offload.app", bufferReadable: true, store: store,
             services: services(recordings: recordings), probe: FakePermissionProbe(), events: NoLocalEvents(),
             sampleWeek: SampleWeekFlag(), backends: backends, insights: insights, onDeviceRecordings: onDevice)
  }

  /// A finished setup in Local mode (route Today).
  static var doneLocal: OnboardingState {
    var s = OnboardingState()
    s.completed = true
    s.screen = .done
    return s
  }
}
