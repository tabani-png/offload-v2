import Foundation

// What the live Today screen shows, built in code from local insights (`.local`) or the brain's day record and the
// planned `GET /v1/today` payload (`.cloud`). Every number on the screen is one of these Figures (ADR 0003); the builders are pure and
// never read the clock.

/// A caption item with the Figure it says ("longest focus 1 h 30 m").
public struct TodayItem: Equatable, Sendable {
  public var text: String
  public var figure: Figure
  public init(text: String, figure: Figure) {
    self.text = text
    self.figure = figure
  }
}

/// One line of "What you did".
public struct DidRow: Equatable, Sendable, Identifiable {
  public var id: String
  /// "9:00a" (local sessions); nil for the brain's tasks, which have no start time.
  public var start: String?
  /// App and host names ("Xcode and github.com") or the brain's task name.
  public var name: String
  /// "1 h 05 m".
  public var duration: String
  public var figure: Figure
}

/// One line of "Keeps coming back this week".
public struct RepeatRow: Equatable, Sendable, Identifiable {
  /// The `k_` key.
  public var key: String
  public var name: String
  /// Occurrences per day, Mon to Sun (local); nil from the brain's week record.
  public var strip: [Int]?
  public var times: Figure
  public var minutes: Figure
  /// "6× · 3.1 h".
  public var count: String
  /// "how: 6 times · 31 min median · 186 min = 3.1 h · Mon–Thu".
  public var how: String

  public var id: String { key }
}

/// One line of "Time by kind" (`.cloud`, instead of the grid).
public struct KindRow: Equatable, Sendable, Identifiable {
  public var kind: String
  public var colorHex: UInt32
  public var figure: Figure
  public var duration: String
  public var id: String { kind }
}

/// One numbered choice on the suggested fix card.
public struct FixOptionRow: Equatable, Sendable, Identifiable {
  /// The fix id (`option_id`), or `leave_alone` for the card's own Leave it alone.
  public var id: String
  public var number: Int
  public var title: String
  public var detail: String?
  /// "saves 1.4 h/wk" from `saving`.
  public var saves: String?
  public var saving: Figure?
  public var recommended: Bool
  /// Picking it makes the primary button Leave it alone.
  public var leavesAlone: Bool
  /// "how: …" of the saving, shown under the picked option.
  public var how: String?
}

/// The one suggested fix.
public struct FixCard: Equatable, Sendable {
  public enum Source: Equatable, Sendable {
    /// A repeat counted on this Mac: answers go to LocalAnswerStore under this key and ISO week.
    case localRepeat(key: String, name: String, minutesPerWeek: Int, isoWeek: String)
    /// A cloud opportunity.
    case opportunity(id: String)
    /// The labelled sample shown while the Today API is not live: no answer is sent and nothing is built from it.
    case sample
  }

  public var source: Source
  /// "Top repeat · counted on this Mac", "Suggested fix · ranked first for <goal>".
  public var status: String
  public var title: String
  /// The count in the title, when it has one.
  public var figure: Figure?
  /// "how: …" of that count, one click on the title away.
  public var how: String?
  public var options: [FixOptionRow]
  /// The option picked at first (the recommended one); nil without options.
  public var defaultSelection: Int?

  /// "Leave it alone" when the picked option is Leave it alone, else "OK, build".
  public func primaryLabel(selected: Int?) -> String {
    leavesAlone(selected: selected) ? TodayCopy.leaveAlone : TodayCopy.okBuild
  }

  /// The sample's card: its buttons and keys do nothing.
  public var isSample: Bool {
    if case .sample = source { return true }
    return false
  }

  public func leavesAlone(selected: Int?) -> Bool {
    guard let s = selected, options.indices.contains(s) else { return false }
    return options[s].leavesAlone
  }

  /// Identifies the card, so a new card starts with its own default pick.
  var identity: String {
    switch source {
    case .localRepeat(let key, _, _, let week): return "local:\(key):\(week)"
    case .opportunity(let id): return "cloud:\(id)"
    case .sample: return "sample"
    }
  }
}

public struct TodayContent: Equatable, Sendable {
  /// "Today · Thu, Nov 12" or "Thu, Nov 5".
  public var title: String
  /// "7 h 40 m of work."
  public var headline: String
  /// "Most of it in Xcode." when the top app holds 40% or more of the active time.
  public var headlineMost: String?
  public var headlineFigure: Figure
  public var subtitleItems: [TodayItem]
  /// `.local` from the day's apps; `.cloud` from `GET /v1/today`'s `day_grid`.
  public var grid: DayGrid?
  /// `.cloud` only, when `day_grid` has no cells: Time by kind from the day record.
  public var kinds: [KindRow]
  public var did: [DidRow]
  public var repeats: [RepeatRow]
  public var fix: FixCard?
  public var provenance: DataProvenance

  /// A repeat stays in the list while it has occurrences that week; at most this many.
  public static let repeatCount = 5
  /// "What you did" lists sessions of at least this long (local).
  public static let didMinSeconds: TimeInterval = 600
  /// "Most of it in X." from this share of the active time.
  public static let mostShare = 0.4
  public static let maxOptions = 3

  /// Every Figure the content shows, once each.
  public var figures: [Figure] {
    var all: [Figure] = [headlineFigure] + subtitleItems.map(\.figure)
    all += grid?.rows.compactMap(\.figure) ?? []
    all += kinds.map(\.figure) + did.map(\.figure)
    all += repeats.flatMap { [$0.times, $0.minutes] }
    if let f = fix?.figure { all.append(f) }
    all += fix?.options.compactMap(\.saving) ?? []
    var seen = Set<Figure>()
    return all.filter { seen.insert($0).inserted }
  }

  // MARK: Local

  /// Today from local insights. Nil when nothing was counted that day (the empty state; never "0 h").
  ///
  /// `answers` are the weekly review answers on this Mac: a repeat they decline now is left out at once, before the
  /// store re-ranks. `now` names the day shown as "Today" and dates the decline rule.
  public static func local(snapshot: InsightsSnapshot, day label: String, rhythm: Rhythm?, timeZone: TimeZone,
                           answers: [LocalReviewAnswer], now: Date) -> TodayContent? {
    guard let d = snapshot.day(label), d.activeSeconds.value > 0 else { return nil }
    let today = LocalDays.label(now, timeZone: timeZone)

    // Header.
    let active = d.activeSeconds.value
    var most: String?
    if let lead = d.topApps.first, lead.appBundleID != LocalInsights.excludedAppID, lead.seconds.value >= mostShare * active {
      most = TodayCopy.mostlyIn(lead.appName)
    }
    var subtitle: [TodayItem] = []
    if d.longestFocus.value > 0 {
      subtitle.append(TodayItem(text: TodayCopy.longestFocus(minutes: TodayCopy.minutes(seconds: d.longestFocus.value)),
                                figure: d.longestFocus))
    }
    subtitle.append(TodayItem(text: TodayCopy.switchesAnHour(d.switchesPerActiveHour.value), figure: d.switchesPerActiveHour))

    // What you did: sessions of 10 minutes or more, named by app and host.
    let did: [DidRow] = d.sessions.filter { $0.activeSeconds >= didMinSeconds }.map { s in
      let n = s.spans.count
      let from = TodayCopy.clock(s.start, timeZone: timeZone)
      let to = TodayCopy.clock(s.end, timeZone: timeZone)
      let figure = Figure.local(s.activeSeconds.rounded(), unit: "seconds",
                                arithmetic: "\(n) \(n == 1 ? "span" : "spans") from \(from) to \(to) added up = \(AnalysisCopy.duration(s.activeSeconds))",
                                evidence: LocalInsights.uniqueEvidence(s.spans))
      return DidRow(id: "\(label)-\(Int(s.start.timeIntervalSince1970))", start: from,
                    name: TodayCopy.sessionName(app: s.topAppName ?? AnalysisCopy.neverWatchApp, host: s.topHost),
                    duration: TodayCopy.paddedDuration(minutes: TodayCopy.minutes(seconds: figure.value)), figure: figure)
    }

    // Keeps coming back this week, and the card.
    let week = TodayWeek(day: label, timeZone: timeZone)
    let adjustments = RankingAdjustments(answers: answers)
    var repeats: [RepeatRow] = []
    var top: (pattern: RepeatPattern, row: RepeatRow)?
    for p in snapshot.repeats where !p.isDeclined {
      guard adjustments.declinePenalty(key: p.key, minutesPerWeek: Int(p.minutesPerWeek.value), now: now) > 0,
            let row = week.row(for: p) else { continue }
      if top == nil { top = (p, row) }
      repeats.append(row)
      if repeats.count == repeatCount { break }
    }
    let fix = top.map { t in
      FixCard(source: .localRepeat(key: t.pattern.key, name: t.pattern.name, minutesPerWeek: Int(t.pattern.minutesPerWeek.value),
                                   isoWeek: week.isoWeek),
              status: TodayCopy.topRepeatStatus, title: TodayCopy.localFixTitle(name: t.pattern.name, times: Int(t.row.times.value)),
              figure: t.row.times, how: TodayCopy.how(t.row.times.arithmetic, weekdays: nil), options: [], defaultSelection: nil)
    }

    return TodayContent(title: TodayCopy.title(day: label, today: today, timeZone: timeZone),
                        headline: TodayCopy.headline(minutes: TodayCopy.minutes(seconds: active)), headlineMost: most,
                        headlineFigure: d.activeSeconds, subtitleItems: subtitle, grid: DayGrid.build(day: d, rhythm: rhythm),
                        kinds: [], did: did, repeats: repeats, fix: fix, provenance: .onDevice)
  }

  // MARK: Cloud

  /// Today from the brain's day record (the header) and the planned `GET /v1/today` payload (the grid, What you did,
  /// the repeats and the suggested fix). Nil when the day counted nothing.
  public static func cloud(day record: DayRecord, payload: TodayPayload, rhythm: Rhythm?, today: String,
                           timeZone: TimeZone) -> TodayContent? {
    let t = record.totals
    guard t.activeMinutes.value > 0 else { return nil }
    let activeMinutes = max(1, Int(t.activeMinutes.value.rounded()))

    let subtitle = [
      TodayItem(text: TodayCopy.focusBlocks(Int(t.focusBlocks.value.rounded())), figure: t.focusBlocks),
      TodayItem(text: TodayCopy.switchesAnHour(t.switchesPerActiveHour.value), figure: t.switchesPerActiveHour),
    ]
    let grid = DayGrid.cloud(payload.dayGrid, rhythm: rhythm)
    var kinds: [KindRow] = []
    if grid == nil {
      // No cells from the server: Time by kind from the day record instead of an empty grid.
      for k in descending(record.byKind.filter { $0.minutes.value > 0 }, by: { $0.minutes.value }) {
        kinds.append(KindRow(kind: TodayCopy.kindName(k.kind), colorHex: kindColor(k.kind),
                             figure: k.minutes, duration: TodayCopy.duration(minutes: Int(k.minutes.value.rounded()))))
      }
    }
    let did: [DidRow] = payload.whatYouDid.enumerated().filter { $0.element.minutes.value > 0 }.map { i, item in
      DidRow(id: "\(i)-\(item.taskKey ?? item.name)", start: item.start.flatMap { TodayCopy.clock(hhmm: $0) }, name: item.name,
             duration: TodayCopy.paddedDuration(minutes: Int(item.minutes.value.rounded())), figure: item.minutes)
    }
    let repeatList = descending(payload.repeats.filter { $0.instances.value >= 2 }, by: { $0.minutes.value }).prefix(repeatCount)
    let repeats: [RepeatRow] = repeatList.map { task in
      RepeatRow(key: task.taskKey, name: task.name, strip: nil, times: task.instances, minutes: task.minutes,
                count: TodayCopy.repeatCount(times: Int(task.instances.value.rounded()), minutes: task.minutes.value),
                how: TodayCopy.how(task.instances.arithmetic + " · " + task.minutes.arithmetic, weekdays: nil))
    }
    let fix = payload.suggestedFix.flatMap { $0.state == .open ? cloudCard($0, repeats: payload.repeats) : nil }

    return TodayContent(title: TodayCopy.title(day: record.day, today: today, timeZone: timeZone),
                        headline: TodayCopy.headline(minutes: activeMinutes), headlineMost: nil, headlineFigure: t.activeMinutes,
                        subtitleItems: subtitle, grid: grid, kinds: kinds, did: did, repeats: repeats, fix: fix,
                        provenance: .cloud)
  }

  /// The open opportunity ranked first (no rank last, then by id), leaving out `excluding`: the card after an answer,
  /// from `GET /v1/opportunities?state=open`.
  public static func nextOpportunity(_ opportunities: [Opportunity], excluding: Set<String>) -> Opportunity? {
    var first: Opportunity?
    for o in opportunities where o.state == .open && !excluding.contains(o.id) {
      guard let cur = first else {
        first = o
        continue
      }
      let ro = o.rank ?? Int.max
      let rc = cur.rank ?? Int.max
      if ro < rc || (ro == rc && o.id < cur.id) { first = o }
    }
    return first
  }

  /// The labelled sample `.cloud` shows while `TodayAPI.available` is off: the same builder over `TodaySample`, every
  /// Figure marked sample, provenance `.sample`, and a card whose buttons do nothing.
  public static func sample(today: String, timeZone: TimeZone) -> TodayContent? {
    guard var c = cloud(day: TodaySample.day(today), payload: TodaySample.payload, rhythm: nil, today: today,
                        timeZone: timeZone) else { return nil }
    c.provenance = .sample
    if var card = c.fix {
      card.source = .sample
      card.status = TodayCopy.sampleFixStatus
      c.fix = card
    }
    return c
  }

  /// The card of an opportunity: up to 3 options by number, then Leave it alone.
  /// The title's count opens to the repeat's `instances` when the opportunity names a task repeated this week (review 2,
  /// finding 2); otherwise the title has no how line and is drawn as plain text.
  static func cloudCard(_ o: Opportunity, repeats: [TodayRepeatItem]) -> FixCard {
    let candidates = o.options.filter { $0.kind != "leave_alone" }
    var order = Array(candidates.indices)
    order.sort { a, b in
      let na = candidates[a].optionNo ?? Int.max
      let nb = candidates[b].optionNo ?? Int.max
      return na != nb ? na < nb : a < b
    }
    let real = order.prefix(maxOptions).map { candidates[$0] }
    var rows: [FixOptionRow] = real.enumerated().map { i, f in
      FixOptionRow(id: f.id, number: i + 1, title: f.title, detail: f.detail,
                   saves: f.estimate.map { TodayCopy.saves(hoursPerWeek: hoursPerWeek($0)) }, saving: f.estimate,
                   recommended: f.recommended, leavesAlone: false,
                   how: f.estimate.map { TodayCopy.how($0.arithmetic, weekdays: nil) })
    }
    let leave = o.options.first { $0.kind == "leave_alone" }
    rows.append(FixOptionRow(id: leave?.id ?? "leave_alone", number: rows.count + 1,
                             title: (leave?.title.isEmpty == false ? leave?.title : nil) ?? TodayCopy.leaveAlone,
                             detail: leave?.detail ?? TodayCopy.leaveAloneDetail, saves: nil, saving: nil, recommended: false,
                             leavesAlone: true, how: nil))
    let status = o.goal.map { TodayCopy.rankedFirst(goal: $0.text) } ?? TodayCopy.suggestedFix
    let count = o.taskKey.flatMap { key in repeats.first { $0.taskKey == key }?.instances }
    return FixCard(source: .opportunity(id: o.id), status: status, title: o.title, figure: count,
                   how: count.map { TodayCopy.how($0.arithmetic, weekdays: nil) }, options: rows,
                   defaultSelection: rows.firstIndex { $0.recommended } ?? 0)
  }

  /// One colour per kind of work (the brain's `WORK_KINDS`), so a kind keeps its colour whatever its rank that day: the
  /// mockup's coding blue, email amber and meetings purple; an unknown kind and `other` take Other's colour.
  public static let kindColors: [String: UInt32] = [
    "code": Tokens.Palette.working, "docs": Tokens.Palette.cyan, "email": Tokens.Palette.needsYou, "meeting": 0xB48CFF,
    "browse": Tokens.Palette.done, "chat": 0xFF8FA3, "sheet": 0xE8D67A,
  ]

  public static func kindColor(_ kind: String) -> UInt32 { kindColors[kind] ?? DayGrid.otherColor }

  /// Highest `key` first; equal keys keep their order.
  static func descending<T>(_ items: [T], by key: (T) -> Double) -> [T] {
    var order = Array(items.indices)
    order.sort { a, b in
      let ka = key(items[a])
      let kb = key(items[b])
      return ka != kb ? ka > kb : a < b
    }
    return order.map { items[$0] }
  }

  /// A saving Figure in hours per week (the brain sends `hours_per_week`; minutes are converted).
  static func hoursPerWeek(_ f: Figure) -> Double {
    f.unit.contains("minute") ? f.value / 60 : f.value
  }
}

/// The ISO week of a shown day, Monday first, and a repeat's share of it.
struct TodayWeek {
  /// The seven days, Mon to Sun ("2026-11-09" …).
  let days: [String]
  /// "2026-W46".
  let isoWeek: String

  init(day label: String, timeZone: TimeZone) {
    var cal = Calendar(identifier: .iso8601)
    cal.timeZone = timeZone
    guard let start = LocalDays.start(of: label, timeZone: timeZone),
          let monday = cal.dateInterval(of: .weekOfYear, for: start)?.start else {
      days = []
      isoWeek = ""
      return
    }
    isoWeek = LocalDays.isoWeek(start, timeZone: timeZone)
    days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday).map { LocalDays.label($0, timeZone: timeZone) } }
  }

  /// The repeat's row for this week, or nil when it has no occurrence in it.
  func row(for p: RepeatPattern) -> RepeatRow? {
    let occ = p.occurrences.filter { days.contains($0.day) }
    guard !occ.isEmpty else { return nil }
    let strip = days.map { d in occ.filter { $0.day == d }.count }
    let n = occ.count
    let evidence = LocalInsights.dedupe(occ.map { .observation($0.firstObservationID) })
    let perDay = zip(TodayCopy.isoWeekdayNames, strip).filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
    let times = Figure.local(Double(n), unit: "count", arithmetic: perDay.joined(separator: " + ") + " = " + TodayCopy.times(n),
                             evidence: evidence)
    let total = Int((occ.reduce(0) { $0 + $1.seconds } / 60).rounded())
    let median = LocalInsights.medianMinutes(occ.map(\.seconds))
    let arithmetic = "\(TodayCopy.times(n)) · \(median) min median · \(total) min = \(TodayCopy.hours(minutes: Double(total)))"
    let minutes = Figure.local(Double(total), unit: "minutes", arithmetic: arithmetic, evidence: evidence)
    return RepeatRow(key: p.key, name: p.name, strip: strip, times: times, minutes: minutes,
                     count: TodayCopy.repeatCount(times: n, minutes: Double(total)),
                     how: TodayCopy.how(arithmetic, weekdays: TodayCopy.weekdays(strip)))
  }
}
