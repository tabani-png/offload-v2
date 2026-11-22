import Foundation

// The day grid of the mockup's Daily screen: 15-minute cells from the person's rhythm start to end, widened to whole
// hours to cover any activity outside it. On the Mac the rows are the day's top 5 apps (and Other), because no model
// names kinds of work here (ADR 0003, ADR 0005). Pure: views draw it.

/// One row of the grid: an app (or Other) and which cells it holds.
public struct DayGridRow: Equatable, Sendable, Identifiable {
  public var name: String
  /// sRGB hex.
  public var colorHex: UInt32
  public var cells: [Bool]
  /// The row's seconds that day (m3-10's per-app Figure; Other's is the sum of the rest).
  public var figure: Figure?

  public var id: String { name }

  public init(name: String, colorHex: UInt32, cells: [Bool], figure: Figure?) {
    self.name = name
    self.colorHex = colorHex
    self.cells = cells
    self.figure = figure
  }
}

public struct DayGrid: Equatable, Sendable {
  /// Minutes after the day's midnight.
  public var startMinute: Int
  public var endMinute: Int
  public var rows: [DayGridRow]
  /// The Switch bursts row: cells with `burstSwitches` or more app switches.
  public var bursts: [Bool]
  /// One label per whole hour: "9a", "10a", … "12p", "1p".
  public var hourLabels: [String]

  public var cellCount: Int { max(0, (endMinute - startMinute) / Self.cellMinutes) }

  public static let cellMinutes = 15
  /// A cell belongs to a row only with at least this many of its seconds.
  public static let minCellSeconds: TimeInterval = 60
  public static let burstSwitches = 4
  public static let rowCount = 5
  /// The mockup's row colours, in order: blue (working), cyan, amber (needs you), purple, green (done).
  public static let palette: [UInt32] = [Tokens.Palette.working, Tokens.Palette.cyan, Tokens.Palette.needsYou, 0xB48CFF,
                                         Tokens.Palette.done]
  /// Other: quiet, so the five named rows stay the story.
  public static let otherColor: UInt32 = Tokens.Palette.chromeFaint
  /// The default rhythm when the person gave none (m3-04's `Rhythm()`): 9:00 to 18:00.
  public static let defaultStart = 9 * 60
  public static let defaultEnd = 18 * 60

  public init(startMinute: Int, endMinute: Int, rows: [DayGridRow], bursts: [Bool], hourLabels: [String]) {
    self.startMinute = startMinute
    self.endMinute = endMinute
    self.rows = rows
    self.bursts = bursts
    self.hourLabels = hourLabels
  }

  /// "9a", "12p", "1p", "12a".
  public static func hourLabel(_ hour: Int) -> String {
    let h = ((hour % 24) + 24) % 24
    let h12 = h % 12 == 0 ? 12 : h % 12
    return "\(h12)" + (h < 12 ? "a" : "p")
  }

  /// Cells pop in on a stagger (14 ms a cell, 40 ms a row, the mockup's timing); Reduce Motion shows them at once.
  public static func appearDelay(cell: Int, row: Int, reduceMotion: Bool) -> Double {
    reduceMotion ? 0 : Double(cell) * 0.014 + Double(row) * 0.04
  }

  /// "09:00" → 540; nil for anything else.
  static func minutes(_ hhmm: String) -> Int? {
    let parts = hhmm.split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...24).contains(h), (0..<60).contains(m) else {
      return nil
    }
    return h * 60 + m
  }

  /// The grid of one day of local insights.
  public static func build(day: DayInsights, rhythm: Rhythm?) -> DayGrid {
    let tz = day.timeZone
    var start = rhythm.flatMap { minutes($0.start) } ?? defaultStart
    var end = rhythm.flatMap { minutes($0.end) } ?? defaultEnd
    if end <= start {
      start = defaultStart
      end = defaultEnd
    }
    // Whole hours, widened to cover every span of the day.
    start = start / 60 * 60
    end = (end + 59) / 60 * 60
    guard let midnight = LocalDays.start(of: day.day, timeZone: tz) else {
      return DayGrid(startMinute: start, endMinute: end, rows: [], bursts: [], hourLabels: [])
    }
    for s in day.spans {
      let a = s.start.timeIntervalSince(midnight) / 60
      let b = s.end.timeIntervalSince(midnight) / 60
      start = min(start, Int((a / 60).rounded(.down)) * 60)
      end = max(end, Int((b / 60).rounded(.up)) * 60)
    }
    start = max(0, start)
    end = min(24 * 60, max(end, start + 60))
    let cells = (end - start) / cellMinutes
    let gridStart = midnight.addingTimeInterval(TimeInterval(start * 60))

    // Rows: the top 5 apps by seconds, then Other for the rest.
    let top = Array(day.perApp.prefix(rowCount))
    let rest = Array(day.perApp.dropFirst(rowCount))
    var rowOf: [String: Int] = [:]
    for (i, a) in top.enumerated() { rowOf[a.appBundleID] = i }
    let otherRow = rest.isEmpty ? nil : top.count
    let rowTotal = top.count + (otherRow == nil ? 0 : 1)

    // Seconds per row per cell.
    var seconds = Array(repeating: Array(repeating: 0.0, count: cells), count: rowTotal)
    let cellSeconds = TimeInterval(cellMinutes * 60)
    for s in day.spans {
      guard let r = rowOf[s.appBundleID] ?? otherRow else { continue }
      let a = s.start.timeIntervalSince(gridStart)
      let b = s.end.timeIntervalSince(gridStart)
      guard b > a else { continue }
      let first = max(0, Int((a / cellSeconds).rounded(.down)))
      let last = min(cells - 1, Int(((b / cellSeconds).rounded(.up))) - 1)
      guard first <= last else { continue }
      for c in first...last {
        let cs = Double(c) * cellSeconds
        let overlap = min(b, cs + cellSeconds) - max(a, cs)
        if overlap > 0 { seconds[r][c] += overlap }
      }
    }
    var held = Array(repeating: Array(repeating: false, count: cells), count: rowTotal)
    for c in 0..<cells {
      var best = -1
      var bestSeconds = 0.0
      for r in 0..<rowTotal where seconds[r][c] > bestSeconds {
        best = r
        bestSeconds = seconds[r][c]
      }
      if best >= 0, bestSeconds >= minCellSeconds { held[best][c] = true }
    }

    // Switches: a span that starts in a cell on a different app than the span before it.
    var switchCount = Array(repeating: 0, count: cells)
    for i in day.spans.indices where i > 0 && day.spans[i - 1].appBundleID != day.spans[i].appBundleID {
      let c = Int((day.spans[i].start.timeIntervalSince(gridStart) / cellSeconds).rounded(.down))
      if c >= 0 && c < cells { switchCount[c] += 1 }
    }

    var rows: [DayGridRow] = top.enumerated().map { i, a in
      DayGridRow(name: a.appName, colorHex: palette[i % palette.count], cells: held[i], figure: a.seconds)
    }
    if let o = otherRow {
      let total = rest.reduce(0) { $0 + $1.seconds.value }
      let names = rest.map(\.appName)
      let figure = Figure.local(total, unit: "seconds",
                                arithmetic: "\(names.count) other apps (\(names.joined(separator: ", "))) added up = \(AnalysisCopy.duration(total))",
                                evidence: LocalInsights.dedupe(rest.flatMap(\.seconds.evidence)))
      rows.append(DayGridRow(name: TodayCopy.other, colorHex: otherColor, cells: held[o], figure: figure))
    }
    return DayGrid(startMinute: start, endMinute: end, rows: rows, bursts: switchCount.map { $0 >= burstSwitches },
                   hourLabels: stride(from: start / 60, to: end / 60, by: 1).map(hourLabel))
  }
}

extension DayGrid {
  /// The grid of `GET /v1/today`'s `day_grid`: the same 15-minute cells from the rhythm (9:00 to 18:00 by default),
  /// widened to whole hours around every cell the server sent. Rows are the kinds of work by minutes, the top 5 in
  /// their kind's colour (a kind keeps its colour from day to day), then Other for the rest and for a cell of a kind
  /// the categories do not name. Nil when no cell is held by a kind.
  public static func cloud(_ payload: TodayDayGridPayload, rhythm: Rhythm?) -> DayGrid? {
    var held: [(minute: Int, kind: String)] = []
    for cell in payload.cells {
      guard let kind = cell.category, !kind.isEmpty, let m = minutes(cell.start), m < 24 * 60 else { continue }
      held.append((m, kind))
    }
    guard !held.isEmpty else { return nil }
    var start = rhythm.flatMap { minutes($0.start) } ?? defaultStart
    var end = rhythm.flatMap { minutes($0.end) } ?? defaultEnd
    if end <= start {
      start = defaultStart
      end = defaultEnd
    }
    start = start / 60 * 60
    end = (end + 59) / 60 * 60
    for h in held {
      start = min(start, h.minute / 60 * 60)
      end = max(end, (h.minute + cellMinutes + 59) / 60 * 60)
    }
    start = max(0, start)
    end = min(24 * 60, max(end, start + 60))
    let count = (end - start) / cellMinutes

    // Rows: kinds by minutes (the server's order between equals), the top 5 named.
    var order = Array(payload.categories.indices)
    order.sort { a, b in
      let ma = payload.categories[a].minutes?.value ?? 0
      let mb = payload.categories[b].minutes?.value ?? 0
      return ma != mb ? ma > mb : a < b
    }
    let named = order.prefix(rowCount).map { payload.categories[$0] }
    var rowOf: [String: Int] = [:]
    for (i, k) in named.enumerated() where rowOf[k.key] == nil { rowOf[k.key] = i }
    let needsOther = order.count > rowCount || held.contains { rowOf[$0.kind] == nil }
    let otherRow: Int? = needsOther ? named.count : nil
    let rowTotal = named.count + (needsOther ? 1 : 0)
    var cells = Array(repeating: Array(repeating: false, count: count), count: rowTotal)
    for h in held {
      guard let r = rowOf[h.kind] ?? otherRow else { continue }
      let i = (h.minute - start) / cellMinutes
      if i >= 0 && i < count { cells[r][i] = true }
    }
    var bursts = Array(repeating: false, count: count)
    for b in payload.switchBursts {
      guard let m = minutes(b.start) else { continue }
      let i = (m - start) / cellMinutes
      if m >= start && i < count { bursts[i] = true }
    }
    var rows: [DayGridRow] = named.enumerated().map { i, k in
      DayGridRow(name: k.name ?? TodayCopy.kindName(k.key), colorHex: TodayContent.kindColor(k.key), cells: cells[i],
                 figure: k.minutes)
    }
    if let o = otherRow {
      rows.append(DayGridRow(name: TodayCopy.other, colorHex: otherColor, cells: cells[o], figure: nil))
    }
    return DayGrid(startMinute: start, endMinute: end, rows: rows, bursts: bursts,
                   hourLabels: stride(from: start / 60, to: end / 60, by: 1).map(hourLabel))
  }
}
