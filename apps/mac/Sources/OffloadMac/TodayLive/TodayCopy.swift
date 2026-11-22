import Foundation

// Every string of the live Today screen (m3-11), so the copy tests see them. Facts are separate items: views draw a
// caption's "·" items apart (MetaItems), never as one string. Numbers in these strings come from Figures; this file
// only formats them.

public enum TodayCopy {
  // MARK: Title and header

  static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  /// Monday first, as the ISO week and the repeats strip.
  static let isoWeekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

  public static let today = "Today"

  /// "Today · Thu, Nov 12" for today, "Thu, Nov 5" for another day (YYYY-MM-DD labels in `timeZone`).
  public static func title(day: String, today: String, timeZone: TimeZone) -> String {
    guard let start = LocalDays.start(of: day, timeZone: timeZone) else { return day }
    let c = LocalDays.calendar(timeZone).dateComponents([.weekday, .month, .day], from: start)
    let weekday = weekdayNames[max(1, min(7, c.weekday ?? 1)) - 1]
    let month = monthNames[max(1, min(12, c.month ?? 1)) - 1]
    let short = "\(weekday), \(month) \(c.day ?? 0)"
    return day == today ? "\(Self.today) · \(short)" : short
  }

  /// Whole minutes from seconds: 0 for nothing, at least 1 for anything counted.
  public static func minutes(seconds: Double) -> Int {
    guard seconds > 0 else { return 0 }
    return max(1, Int((seconds / 60).rounded()))
  }

  /// "7 h 40 m", "45 m", "2 h".
  public static func duration(minutes: Int) -> String {
    let m = max(0, minutes)
    if m < 60 { return "\(m) m" }
    return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) m"
  }

  /// The mono column's form: "1 h 05 m", "1 h 00 m", "45 m".
  public static func paddedDuration(minutes: Int) -> String {
    let m = max(0, minutes)
    if m < 60 { return "\(m) m" }
    return "\(m / 60) h " + String(format: "%02ld", m % 60) + " m"
  }

  /// "7 h 40 m of work."
  public static func headline(minutes: Int) -> String { "\(duration(minutes: minutes)) of work." }

  /// "Most of it in Xcode."
  public static func mostlyIn(_ app: String) -> String { "Most of it in \(app)." }

  /// "longest focus 1 h 30 m".
  public static func longestFocus(minutes: Int) -> String { "longest focus \(duration(minutes: minutes))" }

  /// "38 switches an hour", "10.9 switches an hour".
  public static func switchesAnHour(_ perHour: Double) -> String { "\(AnalysisCopy.decimal(perHour)) switches an hour" }

  /// "2 focus blocks", "1 focus block".
  public static func focusBlocks(_ n: Int) -> String { n == 1 ? "1 focus block" : "\(n) focus blocks" }

  // MARK: Grid

  public static let switchBursts = "Switch bursts"
  public static let other = "Other"
  public static let timeByKind = "Time by kind"

  /// A kind of work from the brain ("build", "agent_review") as a row name ("Build", "Agent review").
  public static func kindName(_ raw: String) -> String {
    let words = raw.replacingOccurrences(of: "_", with: " ")
    guard let first = words.first else { return raw }
    return first.uppercased() + words.dropFirst()
  }

  // MARK: What you did

  public static let whatYouDid = "What you did"

  /// "9:00a", "1:00p": the hour axis's style.
  public static func clock(_ date: Date, timeZone: TimeZone) -> String {
    let c = LocalDays.calendar(timeZone).dateComponents([.hour, .minute], from: date)
    let h = c.hour ?? 0
    let h12 = h % 12 == 0 ? 12 : h % 12
    return "\(h12):" + String(format: "%02ld", c.minute ?? 0) + (h < 12 ? "a" : "p")
  }

  /// "Xcode and github.com", or the app alone. Built from app and host names only, never from text.
  public static func sessionName(app: String, host: String?) -> String {
    guard let host, !host.isEmpty else { return app }
    return "\(app) and \(host)"
  }

  // MARK: Keeps coming back

  public static let keepsComingBack = "Keeps coming back this week"

  /// "3.1 h", "1 h", "0.8 h" from minutes.
  public static func hours(minutes: Double) -> String { "\(AnalysisCopy.decimal(minutes / 60)) h" }

  /// "6× · 3.1 h".
  public static func repeatCount(times: Int, minutes: Double) -> String { "\(times)× · \(hours(minutes: minutes))" }

  /// "1 time", "6 times".
  public static func times(_ n: Int) -> String { n == 1 ? "1 time" : "\(n) times" }

  /// The days of a Mon to Sun strip that hold any: "Mon–Thu" for a run, "Mon, Wed, Fri" otherwise, "Tue" for one.
  public static func weekdays(_ strip: [Int]) -> String? {
    let on = strip.indices.filter { strip[$0] > 0 && $0 < isoWeekdayNames.count }
    guard let first = on.first, let last = on.last else { return nil }
    if on.count == 1 { return isoWeekdayNames[first] }
    if on == Array(first...last) { return "\(isoWeekdayNames[first])–\(isoWeekdayNames[last])" }
    return on.map { isoWeekdayNames[$0] }.joined(separator: ", ")
  }

  /// "how: 6 times · 31 min median · 186 min = 3.1 h · Mon–Thu".
  public static func how(_ arithmetic: String, weekdays: String?) -> String {
    "how: " + arithmetic + (weekdays.map { " · \($0)" } ?? "")
  }

  // MARK: Suggested fix

  /// "You've done Xcode, then github.com in Safari, then Slack 6 times this week."
  public static func localFixTitle(name: String, times n: Int) -> String {
    n == 1 ? "You've done \(name) once this week." : "You've done \(name) \(n) times this week."
  }

  public static let topRepeatStatus = "Top repeat · counted on this Mac"
  public static let suggestedFix = "Suggested fix"

  /// "Suggested fix · ranked first for ship a product".
  public static func rankedFirst(goal: String) -> String { "\(suggestedFix) · ranked first for \(goal)" }

  /// "saves 1.4 h/wk".
  public static func saves(hoursPerWeek: Double) -> String { "saves \(AnalysisCopy.decimal(hoursPerWeek)) h/wk" }

  public static let recommended = "recommended"
  public static let okBuild = "OK, build"
  public static let notNow = "Not now"
  public static let leaveAlone = "Leave it alone"
  public static let leaveAloneDetail = "it's the job · stop suggesting this"
  public static let answerNotSaved = "Your answer could not be saved on this Mac."

  /// "1 / 2 / 3 to pick · ↵ to build"; with no options, "↵ to build".
  public static func keysHint(count: Int) -> String {
    guard count > 0 else { return "↵ to build" }
    return (1...count).map(String.init).joined(separator: " / ") + " to pick · ↵ to build"
  }

  // MARK: States

  public static let emptyTitle = "Nothing counted yet."
  public static let emptyBody = "Import a recordings folder, or keep working with capture on."
  public static let chooseRecordings = "Choose recordings"
  static let updatesWhenDone = "Today updates when it's done"

  /// "reading file 3 of 12 · Today updates when it's done"; before the first file, m3-05's "looking at the folder".
  public static func importing(file: Int, of total: Int) -> String {
    file == 0 ? "\(RecordingsCopy.starting) · \(updatesWhenDone)" : "reading file \(file) of \(total) · \(updatesWhenDone)"
  }

  /// While local insights are counting.
  public static let counting = "counting on this Mac · Today updates when it's done"
  public static let notRecorded = "Nothing recorded for this day yet."
  public static let signInAgain = "Sign in again to see Today."
  public static let offline = "Can't reach Offload. Showing nothing rather than old numbers."
  /// "Today could not load (server_error)."
  public static func couldNotLoad(_ code: String) -> String { "Today could not load (\(code))." }
  public static let tryAgain = "Try again"
  public static let loading = "reading Today"
  public static let previousDay = "Previous day"
  public static let nextDay = "Next day"

  // MARK: Menu bar

  /// "today · 3 h 10 m · mostly Xcode", or without the app.
  public static func menuLine(minutes: Int, app: String?) -> String {
    (["today", duration(minutes: minutes)] + (app.map { ["mostly \($0)"] } ?? [])).joined(separator: " · ")
  }

  // MARK: For the copy tests

  public static var all: [String] {
    [
      today, title(day: "2026-11-12", today: "2026-11-12", timeZone: TimeZone(identifier: "UTC")!),
      headline(minutes: 460), mostlyIn("Xcode"), longestFocus(minutes: 90), switchesAnHour(38), focusBlocks(1),
      focusBlocks(2), switchBursts, other, timeByKind, kindName("agent_review"), whatYouDid,
      sessionName(app: "Xcode", host: "github.com"), keepsComingBack, repeatCount(times: 6, minutes: 186), times(1),
      how("6 times · 31 min median · 186 min = 3.1 h", weekdays: "Mon–Thu"),
      localFixTitle(name: "Xcode, then Slack", times: 6), localFixTitle(name: "Xcode, then Slack", times: 1),
      topRepeatStatus, suggestedFix, rankedFirst(goal: "ship a product"), saves(hoursPerWeek: 1.4), recommended, okBuild,
      notNow, leaveAlone, leaveAloneDetail, answerNotSaved, keysHint(count: 3), keysHint(count: 0), emptyTitle, emptyBody,
      chooseRecordings, importing(file: 3, of: 12), importing(file: 0, of: 12), counting, notRecorded, signInAgain,
      offline, couldNotLoad("server_error"), tryAgain, loading, previousDay, nextDay,
      menuLine(minutes: 190, app: "Xcode"), menuLine(minutes: 190, app: nil),
    ]
  }

  /// Captions: lowercase (the names Today and Mac aside), facts as separate `·` items. App and weekday names in a
  /// caption keep their capitals, so the samples here leave them out.
  public static var captions: [String] {
    [
      longestFocus(minutes: 90), switchesAnHour(38), focusBlocks(2), repeatCount(times: 6, minutes: 186),
      how("6 times · 31 min median · 186 min = 3.1 h", weekdays: nil), saves(hoursPerWeek: 1.4), recommended,
      leaveAloneDetail, keysHint(count: 3), importing(file: 3, of: 12), importing(file: 0, of: 12), counting, loading,
      menuLine(minutes: 190, app: nil),
    ]
  }
}
