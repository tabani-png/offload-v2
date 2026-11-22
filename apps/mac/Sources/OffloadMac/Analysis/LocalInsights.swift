import CryptoKit
import Foundation
import OffloadImport

// Local insights: what the recordings and live capture show, counted in code on this Mac (ADR 0003). Active time per
// day and per app, sessions, focus blocks, switches, top apps and sites (host only), and the things you repeat with
// minutes per week. No model call, nothing sent. The rules are the SPEC's Design note, "Local insights rules".

/// One stretch of time on one app (title and host as given), from one origin.
public struct ActivitySpan: Equatable, Sendable {
  public var start: Date
  public var end: Date
  public var appBundleID: String
  public var appName: String
  public var title: String?
  public var host: String?
  /// The focus (or activity) event that opened the span: its evidence.
  public var firstEventID: String
  /// In Never watch now: counted as time, without a name, title or host, and never part of a repeat.
  public var excluded: Bool

  public init(start: Date, end: Date, appBundleID: String, appName: String, title: String?, host: String?,
              firstEventID: String, excluded: Bool = false) {
    self.start = start
    self.end = end
    self.appBundleID = appBundleID
    self.appName = appName
    self.title = title
    self.host = host
    self.firstEventID = firstEventID
    self.excluded = excluded
  }

  public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// One step of a session: the app, the title shape and the host.
public struct RepeatStep: Equatable, Hashable, Sendable {
  public var appBundleID: String
  public var appName: String
  public var titleShape: String?
  public var host: String?

  public init(appBundleID: String, appName: String, titleShape: String?, host: String?) {
    self.appBundleID = appBundleID
    self.appName = appName
    self.titleShape = titleShape
    self.host = host
  }

  public var key: String { [appBundleID, titleShape ?? "", host ?? ""].joined(separator: "\u{1F}") }

  /// "github.com in Safari", or the app name. Never text.
  public var label: String {
    if let host { return "\(host) in \(appName)" }
    return appName
  }
}

/// A step with its time in the session.
public struct TimedStep: Equatable, Sendable {
  public var step: RepeatStep
  public var start: Date
  public var end: Date
  public var firstObservationID: String
  /// A Never watch step: it breaks sequences and is never part of a repeat.
  public var excluded: Bool
}

/// A maximal run of spans with no idle gap of 300 s or more.
public struct Session: Equatable, Sendable {
  public var start: Date
  public var end: Date
  public var spans: [ActivitySpan]
  public var activeSeconds: TimeInterval
  public var switches: Int
  public var isFocusBlock: Bool
  public var steps: [TimedStep]

  public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }

  /// The app with the most time in the session (excluded apps by their stand-in name).
  public var topAppName: String? { LocalInsights.top(spans) { $0.appName } }
  /// The host with the most time in the session.
  public var topHost: String? { LocalInsights.top(spans.filter { $0.host != nil }) { $0.host ?? "" } }
}

public struct AppTime: Equatable, Sendable {
  public var appBundleID: String
  public var appName: String
  /// Seconds.
  public var seconds: Figure
}

public struct SiteTime: Equatable, Sendable {
  /// Host only: never a path.
  public var host: String
  public var seconds: Figure
}

/// One day of local insights.
public struct DayInsights: Equatable, Sendable {
  /// "2026-11-20" in `timeZone`.
  public var day: String
  public var timeZone: TimeZone
  public var spans: [ActivitySpan]
  public var sessions: [Session]
  public var activeSeconds: Figure
  /// Every app, most time first.
  public var perApp: [AppTime]
  public var topApps: [AppTime]
  public var topSites: [SiteTime]
  public var switches: Figure
  public var switchesPerActiveHour: Figure
  public var focusBlocks: Figure
  /// Seconds in focus blocks.
  public var focusSeconds: Figure
  public var longestFocus: Figure

  public var isEmpty: Bool { spans.isEmpty }
}

public enum RepeatConfidence: String, Equatable, Sendable {
  case high, medium, low

  public var weight: Double {
    switch self {
    case .high: return 1.0
    case .medium: return 0.7
    case .low: return 0.4
    }
  }

  /// `high` with 4 or more days and 6 or more times; `medium` with 3 or more days or 4 or more times; else `low`.
  public static func of(days: Int, times: Int) -> RepeatConfidence {
    if days >= 4 && times >= 6 { return .high }
    if days >= 3 || times >= 4 { return .medium }
    return .low
  }
}

public struct RepeatOccurrence: Equatable, Sendable {
  public var day: String
  public var start: Date
  public var end: Date
  public var firstObservationID: String
  public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// A thing you repeat: the same 2 to 4 steps, on 2 or more days, 3 or more times.
public struct RepeatPattern: Equatable, Sendable, Identifiable {
  /// `k_` + first 12 hex of SHA-256 over the step keys (the brain's task key shape).
  public var key: String
  /// Built from app names and hosts only.
  public var name: String
  public var steps: [RepeatStep]
  public var occurrences: [RepeatOccurrence]
  public var days: [String]
  public var medianMinutes: Int
  public var totalMinutes: Int
  public var minutesPerWeek: Figure
  public var confidence: RepeatConfidence
  public var weeksPresent: Int
  public var weeksObserved: Int
  public var persistence: Double
  public var goalWeight: Double
  public var declinePenalty: Double
  public var score: Double

  public init(key: String, name: String, steps: [RepeatStep], occurrences: [RepeatOccurrence], days: [String],
              medianMinutes: Int, totalMinutes: Int, minutesPerWeek: Figure, confidence: RepeatConfidence,
              weeksPresent: Int, weeksObserved: Int, persistence: Double, goalWeight: Double, declinePenalty: Double,
              score: Double) {
    self.key = key
    self.name = name
    self.steps = steps
    self.occurrences = occurrences
    self.days = days
    self.medianMinutes = medianMinutes
    self.totalMinutes = totalMinutes
    self.minutesPerWeek = minutesPerWeek
    self.confidence = confidence
    self.weeksPresent = weeksPresent
    self.weeksObserved = weeksObserved
    self.persistence = persistence
    self.goalWeight = goalWeight
    self.declinePenalty = declinePenalty
    self.score = score
  }

  public var id: String { key }
  public var times: Int { occurrences.count }
  /// Declined (`never`, `leave_alone`, or `not_now` within 4 weeks) and not risen since: not shown.
  public var isDeclined: Bool { declinePenalty == 0 }
}

public enum LocalInsights {
  /// The idle threshold (m3-04's local now summary): a span with no activity for longer than `idleGap` ends here
  /// after its last activity.
  public static let idleThreshold: TimeInterval = 120
  public static let idleGap: TimeInterval = 300
  public static let minSession: TimeInterval = 60
  public static let focusBlockMin: TimeInterval = 25 * 60
  public static let foldUnder: TimeInterval = 10
  public static let topCount = 5
  public static let excludedAppID = "never-watch"

  // MARK: Spans

  /// The spans of one origin's events, in time order. `until` closes a span that is still open (live capture).
  ///
  /// `idleGapRule` is for live capture, whose stream has an event for every input: a gap of more than 300 s ends the
  /// span at the last activity plus 120 s. Imports carry their idleness explicitly (the readers write `idle_start`
  /// and `idle_end` from the rows and frames, and write a focus only when it changes), so silence in an import is
  /// not idleness and the rule is off for them (see the SPEC's Scope changes).
  public static func spans(_ events: [InsightEvent], until: Date? = nil, idleGapRule: Bool = true) -> [ActivitySpan] {
    let sorted = events.sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.id < $1.id }
    var out: [ActivitySpan] = []
    var cur: ActivitySpan?
    var lastFocus: InsightEvent?
    var lastActivity: Date?
    var paused = false

    func close(at t: Date) {
      guard var c = cur else { return }
      c.end = max(c.start, t)
      if c.end > c.start { out.append(c) }
      cur = nil
    }

    func open(_ f: InsightEvent, at t: Date, by eventID: String) {
      let app = f.appBundleID ?? f.appName ?? "unknown"
      cur = ActivitySpan(start: t, end: t, appBundleID: app, appName: f.appName ?? app, title: f.title, host: f.host,
                         firstEventID: eventID)
    }

    for e in sorted {
      // A gap of more than 300 s without activity: the span ended at the last activity plus the idle threshold.
      if idleGapRule, cur != nil, let last = lastActivity, e.ts.timeIntervalSince(last) > idleGap {
        close(at: min(e.ts, last.addingTimeInterval(idleThreshold)))
      }
      switch e.kind {
      case .focus:
        close(at: e.ts)
        lastFocus = e
        if !paused { open(e, at: e.ts, by: e.id) }
        lastActivity = e.ts
      case .idleStart:
        // Readers already place idle_start at the last activity plus the threshold.
        close(at: e.ts)
      case .pause:
        close(at: e.ts)
        paused = true
        lastFocus = nil
      case .resume:
        paused = false
        lastActivity = e.ts
      case .idleEnd, .textSnapshot:
        if cur == nil, !paused, let f = lastFocus { open(f, at: e.ts, by: e.id) }
        lastActivity = e.ts
      }
    }
    if cur != nil, let last = lastActivity {
      var end = last.addingTimeInterval(idleThreshold)
      if let until { end = min(end, until) }
      close(at: end)
    }
    return out
  }

  /// Spans in Never watch now keep their time and lose their name, title and host.
  public static func applyExclusions(_ spans: [ActivitySpan], rules: [ImportExclusionRule]) -> [ActivitySpan] {
    spans.map { s in
      guard ImportExclusions.isExcluded(bundleID: s.appBundleID, appName: s.appName, title: s.title, host: s.host, rules: rules) else {
        return s
      }
      return ActivitySpan(start: s.start, end: s.end, appBundleID: excludedAppID, appName: AnalysisCopy.neverWatchApp,
                          title: nil, host: nil, firstEventID: s.firstEventID, excluded: true)
    }
  }

  /// Spans clipped to `[interval.start, interval.end)`: a span across midnight is split at the day boundary.
  public static func clip(_ spans: [ActivitySpan], to interval: DateInterval) -> [ActivitySpan] {
    spans.compactMap { s in
      let start = max(s.start, interval.start)
      let end = min(s.end, interval.end)
      guard end > start else { return nil }
      var c = s
      c.start = start
      c.end = end
      return c
    }
  }

  // MARK: One day

  /// One day of insights from events of any origins (each origin is read on its own, then counted together).
  public static func day(_ events: [InsightEvent], day label: String, timeZone: TimeZone,
                         exclusions: [ImportExclusionRule], until: Date? = nil) -> DayInsights {
    guard let interval = LocalDays.interval(of: label, timeZone: timeZone) else {
      return dayInsights(spans: [], day: label, timeZone: timeZone)
    }
    var byOrigin: [InsightEvent.Origin: [InsightEvent]] = [:]
    var originOrder: [InsightEvent.Origin] = []
    for e in events {
      if byOrigin[e.origin] == nil { originOrder.append(e.origin) }
      byOrigin[e.origin, default: []].append(e)
    }
    var all: [ActivitySpan] = []
    for origin in originOrder {
      let live = origin == .live
      all += spans(byOrigin[origin] ?? [], until: live ? until : nil, idleGapRule: live)
    }
    let clipped = clip(applyExclusions(all, rules: exclusions), to: interval)
      .sorted { $0.start != $1.start ? $0.start < $1.start : $0.firstEventID < $1.firstEventID }
    return dayInsights(spans: clipped, day: label, timeZone: timeZone)
  }

  /// Every figure of a day from its (clipped, sorted) spans.
  public static func dayInsights(spans: [ActivitySpan], day: String, timeZone: TimeZone) -> DayInsights {
    let evidence = uniqueEvidence(spans)
    let active = spans.reduce(0) { $0 + $1.seconds }
    let activeFigure = spans.isEmpty ? Figure.nothing(unit: "seconds")
      : Figure.local(active.rounded(), unit: "seconds",
                     arithmetic: "\(spans.count) \(spans.count == 1 ? "span" : "spans") added up = \(AnalysisCopy.duration(active))",
                     evidence: evidence)

    // Per app, most time first; ties by first seen.
    var order: [String] = []
    var byApp: [String: Tally] = [:]
    for s in spans {
      if byApp[s.appBundleID] == nil {
        order.append(s.appBundleID)
        byApp[s.appBundleID] = Tally(name: s.appName)
      }
      byApp[s.appBundleID]?.add(s)
    }
    let perApp: [AppTime] = order.enumerated().sorted { a, b in
      let sa = byApp[a.element]?.seconds ?? 0
      let sb = byApp[b.element]?.seconds ?? 0
      return sa != sb ? sa > sb : a.offset < b.offset
    }.compactMap { pair in
      guard let a = byApp[pair.element] else { return nil }
      return AppTime(appBundleID: pair.element, appName: a.name,
                     seconds: Figure.local(a.seconds.rounded(), unit: "seconds",
                                           arithmetic: "\(a.name): \(a.spans.count) \(a.spans.count == 1 ? "span" : "spans") = \(AnalysisCopy.duration(a.seconds))",
                                           evidence: uniqueEvidence(a.spans)))
    }

    // Sites by host only.
    var hostOrder: [String] = []
    var byHost: [String: Tally] = [:]
    for s in spans {
      guard let host = s.host?.lowercased(), !host.isEmpty, !s.excluded else { continue }
      if byHost[host] == nil {
        hostOrder.append(host)
        byHost[host] = Tally(name: host)
      }
      byHost[host]?.add(s)
    }
    let topSites: [SiteTime] = hostOrder.enumerated().sorted { a, b in
      let sa = byHost[a.element]?.seconds ?? 0
      let sb = byHost[b.element]?.seconds ?? 0
      return sa != sb ? sa > sb : a.offset < b.offset
    }.prefix(topCount).compactMap { pair in
      guard let h = byHost[pair.element] else { return nil }
      return SiteTime(host: pair.element,
                      seconds: Figure.local(h.seconds.rounded(), unit: "seconds",
                                            arithmetic: "\(pair.element): \(h.spans.count) \(h.spans.count == 1 ? "span" : "spans") = \(AnalysisCopy.duration(h.seconds))",
                                            evidence: uniqueEvidence(h.spans)))
    }

    // Switches: focus moving to a different app.
    var switchCount = 0
    var switchEvidence: [EvidenceRef] = []
    for (i, s) in spans.enumerated() where i > 0 && spans[i - 1].appBundleID != s.appBundleID {
      switchCount += 1
      switchEvidence.append(.observation(s.firstEventID))
    }
    let switchesFigure = spans.isEmpty ? Figure.nothing(unit: "count")
      : Figure.local(Double(switchCount), unit: "count", arithmetic: "\(switchCount) changes to a different app",
                     evidence: dedupe(switchEvidence))
    let perHour: Double = active > 0 ? (Double(switchCount) / (active / 3600) * 10).rounded() / 10 : 0
    let perHourFigure = active > 0
      ? Figure.local(perHour, unit: "per_hour",
                     arithmetic: "\(switchCount) switches ÷ \(AnalysisCopy.hours(active)) active = \(AnalysisCopy.decimal(perHour)) an hour",
                     evidence: dedupe(switchEvidence))
      : Figure.nothing(unit: "per_hour")

    let sessionList = sessions(spans)
    let blocks = sessionList.filter(\.isFocusBlock)
    let focusTotal = blocks.reduce(0) { $0 + $1.seconds }
    let blockEvidence = dedupe(blocks.flatMap { uniqueEvidence($0.spans) })
    let blocksFigure = spans.isEmpty ? Figure.nothing(unit: "count")
      : Figure.local(Double(blocks.count), unit: "count",
                     arithmetic: "\(blocks.count) sessions of 25 min or more with at most 2 switches per 10 min",
                     evidence: blockEvidence)
    let focusSecondsFigure = blocks.isEmpty ? Figure.nothing(unit: "seconds")
      : Figure.local(focusTotal.rounded(), unit: "seconds",
                     arithmetic: "\(blocks.count) focus \(blocks.count == 1 ? "block" : "blocks") added up = \(AnalysisCopy.duration(focusTotal))",
                     evidence: blockEvidence)
    let longest = blocks.max { $0.seconds < $1.seconds }
    let longestFigure = longest.map { b in
      Figure.local(b.seconds.rounded(), unit: "seconds",
                   arithmetic: "longest of \(blocks.count) focus \(blocks.count == 1 ? "block" : "blocks") = \(AnalysisCopy.duration(b.seconds))",
                   evidence: uniqueEvidence(b.spans))
    } ?? Figure.nothing(unit: "seconds")

    return DayInsights(day: day, timeZone: timeZone, spans: spans, sessions: sessionList, activeSeconds: activeFigure,
                       perApp: perApp, topApps: Array(perApp.prefix(topCount)), topSites: topSites,
                       switches: switchesFigure, switchesPerActiveHour: perHourFigure, focusBlocks: blocksFigure,
                       focusSeconds: focusSecondsFigure, longestFocus: longestFigure)
  }

  // MARK: Sessions and steps

  /// Sessions of sorted spans: a new one after an idle gap of 300 s or more; sessions under 60 s are dropped.
  public static func sessions(_ spans: [ActivitySpan]) -> [Session] {
    var groups: [[ActivitySpan]] = []
    var lastEnd: Date?
    for s in spans {
      if let end = lastEnd, s.start.timeIntervalSince(end) < idleGap, !groups.isEmpty {
        groups[groups.count - 1].append(s)
      } else {
        groups.append([s])
      }
      lastEnd = max(lastEnd ?? s.end, s.end)
    }
    return groups.compactMap { g -> Session? in
      guard let first = g.first else { return nil }
      let end = g.map(\.end).max() ?? first.end
      let duration = end.timeIntervalSince(first.start)
      guard duration >= minSession else { return nil }
      var switches = 0
      for i in g.indices where i > 0 && g[i - 1].appBundleID != g[i].appBundleID { switches += 1 }
      let focus = duration >= focusBlockMin && Double(switches) * 600 <= 2 * duration
      return Session(start: first.start, end: end, spans: g, activeSeconds: g.reduce(0) { $0 + $1.seconds },
                     switches: switches, isFocusBlock: focus, steps: steps(g))
    }
  }

  /// A session's steps: spans under 10 s folded into the step before them, equal steps in a row collapsed.
  public static func steps(_ spans: [ActivitySpan]) -> [TimedStep] {
    var out: [TimedStep] = []
    for s in spans {
      if s.seconds < foldUnder {
        if !out.isEmpty { out[out.count - 1].end = max(out[out.count - 1].end, s.end) }
        continue
      }
      let step = RepeatStep(appBundleID: s.appBundleID, appName: s.appName, titleShape: s.excluded ? nil : titleShape(s.title),
                            host: s.excluded ? nil : s.host?.lowercased())
      if let last = out.last, last.step == step, last.excluded == s.excluded {
        out[out.count - 1].end = max(last.end, s.end)
      } else {
        out.append(TimedStep(step: step, start: s.start, end: s.end, firstObservationID: s.firstEventID, excluded: s.excluded))
      }
    }
    return out
  }

  /// The masked title lowercased, pseudonyms to their kind, digit runs to `#`, first 6 words. Nil without a title.
  public static func titleShape(_ title: String?) -> String? {
    guard let title, !title.isEmpty else { return nil }
    var s = title.lowercased()
    s = s.replacingOccurrences(of: "<([a-z]+):h_[0-9a-f]+>", with: "<$1>", options: .regularExpression)
    s = s.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
    let words = s.split(whereSeparator: { $0.isWhitespace }).prefix(6)
    let shape = words.joined(separator: " ")
    return shape.isEmpty ? nil : shape
  }

  // MARK: Things you repeat

  public static let minDays = 2
  public static let minTimes = 3
  public static let rankWeeks = 8

  /// The things you repeat over these days, ranked (declined ones stay in the list with score 0).
  public static func repeats(days: [DayInsights], now: Date, timeZone: TimeZone,
                             adjustments: RankingAdjustments = .none, goals: [String] = []) -> [RepeatPattern] {
    struct Found {
      var steps: [RepeatStep]
      var occurrences: [RepeatOccurrence] = []
    }
    var found: [String: Found] = [:]
    for d in days.sorted(by: { $0.day < $1.day }) {
      for session in d.sessions {
        let st = session.steps
        var nextAllowed: [String: Int] = [:]
        for n in 2...4 where st.count >= n {
          for i in 0...(st.count - n) {
            let window = Array(st[i..<(i + n)])
            if window.contains(where: \.excluded) { continue }
            let apps = Set(window.map(\.step.appBundleID))
            let hosts = Set(window.compactMap(\.step.host))
            guard apps.count >= 2 || hosts.count >= 2 else { continue }
            let steps = window.map(\.step)
            let k = steps.map(\.key).joined(separator: "\n")
            if let allowed = nextAllowed[k], i < allowed { continue }
            nextAllowed[k] = i + n
            let occ = RepeatOccurrence(day: d.day, start: window[0].start, end: window[n - 1].end,
                                       firstObservationID: window[0].firstObservationID)
            found[k, default: Found(steps: steps)].occurrences.append(occ)
          }
        }
      }
    }
    var kept = found.filter { _, f in Set(f.occurrences.map(\.day)).count >= minDays && f.occurrences.count >= minTimes }
    // A sequence inside a longer one seen as often adds nothing.
    for (k, f) in kept {
      let contained = kept.contains { other, o in
        other != k && o.steps.count > f.steps.count && o.occurrences.count == f.occurrences.count && contains(o.steps, f.steps)
      }
      if contained { kept[k] = nil }
    }

    let observed = days.filter { !$0.isEmpty }.map(\.day)
    let span = LocalDays.span(observed, timeZone: timeZone)
    let weeks = recentWeeks(now: now, timeZone: timeZone)
    let observedWeeks = Set(observed.compactMap { label in
      LocalDays.start(of: label, timeZone: timeZone).map { LocalDays.isoWeek($0, timeZone: timeZone) }
    }).intersection(weeks)

    var out: [RepeatPattern] = []
    for f in kept.values {
      let occ = f.occurrences.sorted { $0.start < $1.start }
      let dayList = Array(Set(occ.map(\.day))).sorted()
      let totalSeconds = occ.reduce(0) { $0 + $1.seconds }
      let totalMinutes = Int((totalSeconds / 60).rounded())
      let median = medianMinutes(occ.map(\.seconds))
      let divisor = max(7, span)
      let perWeek = Int((Double(totalMinutes) * 7 / Double(divisor)).rounded())
      let arithmetic = "\(occ.count) times · \(median) min median · \(totalMinutes) min over \(span) days × 7 ÷ \(divisor) = \(perWeek) min/week"
      let minutesPerWeek = Figure.local(Double(perWeek), unit: "minutes_per_week", arithmetic: arithmetic,
                                        evidence: dedupe(occ.map { .observation($0.firstObservationID) }))
      let presentWeeks = Set(occ.map { LocalDays.isoWeek($0.start, timeZone: timeZone) }).intersection(weeks)
      let persistence = observedWeeks.isEmpty ? 0 : Double(presentWeeks.count) / Double(observedWeeks.count)
      let key = taskKey(f.steps)
      let confidence = RepeatConfidence.of(days: dayList.count, times: occ.count)
      let goalWeight = adjustments.goalWeight(key: key, goals: goals)
      let penalty = adjustments.declinePenalty(key: key, minutesPerWeek: perWeek, now: now)
      let score = (Double(perWeek) / 60) * persistence * goalWeight * confidence.weight * penalty
      out.append(RepeatPattern(key: key, name: name(f.steps), steps: f.steps, occurrences: occ, days: dayList,
                               medianMinutes: median, totalMinutes: totalMinutes, minutesPerWeek: minutesPerWeek,
                               confidence: confidence, weeksPresent: presentWeeks.count,
                               weeksObserved: observedWeeks.count, persistence: persistence, goalWeight: goalWeight,
                               declinePenalty: penalty, score: score))
    }
    return rank(out)
  }

  /// Highest score first, ties by key.
  public static func rank(_ patterns: [RepeatPattern]) -> [RepeatPattern] {
    patterns.sorted { $0.score != $1.score ? $0.score > $1.score : $0.key < $1.key }
  }

  /// The top 5 not declined: "things you repeat".
  public static func top(_ ranked: [RepeatPattern]) -> [RepeatPattern] {
    Array(ranked.filter { !$0.isDeclined }.prefix(topCount))
  }

  /// `k_` + first 12 hex of SHA-256 over the step keys.
  public static func taskKey(_ steps: [RepeatStep]) -> String {
    let digest = SHA256.hash(data: Data(steps.map(\.key).joined(separator: "\n").utf8))
    return "k_" + String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
  }

  /// "Xcode, then github.com in Safari, then Slack".
  public static func name(_ steps: [RepeatStep]) -> String {
    var labels: [String] = []
    for s in steps where labels.last != s.label { labels.append(s.label) }
    return labels.joined(separator: ", then ")
  }

  /// The ISO weeks of the last 8 weeks up to `now`.
  public static func recentWeeks(now: Date, timeZone: TimeZone) -> Set<String> {
    let cal = LocalDays.calendar(timeZone)
    var out = Set<String>()
    for back in 0..<rankWeeks {
      if let d = cal.date(byAdding: .day, value: -7 * back, to: now) { out.insert(LocalDays.isoWeek(d, timeZone: timeZone)) }
    }
    return out
  }

  static func contains(_ long: [RepeatStep], _ short: [RepeatStep]) -> Bool {
    guard short.count <= long.count else { return false }
    for i in 0...(long.count - short.count) where Array(long[i..<(i + short.count)]) == short { return true }
    return false
  }

  static func medianMinutes(_ seconds: [TimeInterval]) -> Int {
    let s = seconds.sorted()
    guard !s.isEmpty else { return 0 }
    let mid = s.count / 2
    let m = s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    return Int((m / 60).rounded())
  }

  static func top(_ spans: [ActivitySpan], by name: (ActivitySpan) -> String) -> String? {
    var order: [String] = []
    var total: [String: TimeInterval] = [:]
    for s in spans {
      let n = name(s)
      if total[n] == nil { order.append(n) }
      total[n, default: 0] += s.seconds
    }
    return order.enumerated().max { a, b in
      let ta = total[a.element] ?? 0
      let tb = total[b.element] ?? 0
      return ta != tb ? ta < tb : a.offset > b.offset
    }?.element
  }

  /// Time and spans per app or host.
  struct Tally {
    var name: String
    var seconds: TimeInterval = 0
    var spans: [ActivitySpan] = []

    mutating func add(_ s: ActivitySpan) {
      seconds += s.seconds
      spans.append(s)
    }
  }

  static func uniqueEvidence(_ spans: [ActivitySpan]) -> [EvidenceRef] {
    dedupe(spans.map { .observation($0.firstEventID) })
  }

  static func dedupe(_ refs: [EvidenceRef]) -> [EvidenceRef] {
    var seen = Set<EvidenceRef>()
    return refs.filter { seen.insert($0).inserted }
  }
}
