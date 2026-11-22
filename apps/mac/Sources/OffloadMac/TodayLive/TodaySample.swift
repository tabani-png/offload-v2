import Foundation

// The sample Today shows in `.cloud` while `TodayAPI.available` is off (the server's `GET /v1/today` is not live yet).
// It is drawn by the same builder as real cloud data so the screen can be tried, under the amber label "Sample data:
// Today API not live yet". Nothing here is counted: every Figure's arithmetic starts with "sample: " and its evidence
// is of kind `sample`, so no sample number can pass for a counted one (ADR 0003), and the card's buttons do nothing.

enum TodaySample {
  static let evidence = [EvidenceRef(kind: "sample", id: "sample")]

  /// A sample Figure: "sample: " before the arithmetic, sample evidence.
  static func fig(_ value: Double, _ unit: String, _ arithmetic: String) -> Figure {
    Figure.local(value, unit: unit, arithmetic: "sample: " + arithmetic, evidence: evidence)
  }

  /// The header's record, dated `day` so the title reads as today.
  static func day(_ day: String) -> DayRecord {
    DayRecord(
      day: day, generatedAt: "", totals: DayTotals(
        activeMinutes: fig(460, "minutes", "41 spans of active time = 460 min"),
        switches: fig(57, "count", "57 app switches"),
        switchesPerActiveHour: fig(7.4, "per_hour", "57 switches / 7.7 h = 7.4 an hour"),
        focusBlocks: fig(2, "count", "2 runs of one task of 25 min or more"),
        focusMinutes: fig(150, "minutes", "90 + 60 = 150 min"),
        meetingMinutes: fig(45, "minutes", "1 meeting = 45 min")),
      byKind: [], byApp: [], byTask: [], episodeIDs: [], sourcePurgedAt: nil)
  }

  /// One character a cell from 9:00 to 18:00: c code, d docs, e email, m meeting, b browse, space idle.
  static let cellPattern = "cccccccddeeemmm cccccbb  ddddeecccc "

  static let kinds: [(key: String, minutes: Double)] = [
    ("code", 200), ("docs", 90), ("email", 75), ("meeting", 45), ("browse", 30),
  ]

  static var payload: TodayPayload {
    let letters: [Character: String] = ["c": "code", "d": "docs", "e": "email", "m": "meeting", "b": "browse"]
    let cells: [TodayGridCell] = cellPattern.enumerated().map { i, ch in
      let m = DayGrid.defaultStart + i * DayGrid.cellMinutes
      return TodayGridCell(start: String(format: "%02ld:%02ld", m / 60, m % 60), category: letters[ch])
    }
    let categories = kinds.map { k in
      TodayGridCategory(key: k.key, name: nil, minutes: fig(k.minutes, "minutes", "\(k.key) cells added up = \(Int(k.minutes)) min"))
    }
    let bursts = ["10:45", "11:00", "15:30"].map { TodaySwitchBurst(start: $0, switches: fig(5, "count", "5 app switches in 15 min")) }
    let did = [
      TodayDidItem(taskKey: nil, name: "Review pull requests", start: "09:00", minutes: fig(105, "minutes", "3 spans = 105 min")),
      TodayDidItem(taskKey: nil, name: "Write the weekly update", start: "10:45", minutes: fig(40, "minutes", "2 spans = 40 min")),
      TodayDidItem(taskKey: nil, name: "Team meeting", start: "11:30", minutes: fig(45, "minutes", "1 span = 45 min")),
      TodayDidItem(taskKey: nil, name: "Reconcile invoices", start: "14:00", minutes: fig(65, "minutes", "4 spans = 65 min")),
    ]
    let repeats = [
      TodayRepeatItem(taskKey: "k_000000000001", name: "Review pull requests",
                      instances: fig(6, "count", "Mon 1 + Tue 1 + Wed 2 + Thu 2 = 6 times"),
                      minutes: fig(186, "minutes", "6 times · 31 min median · 186 min = 3.1 h"),
                      medianMinutes: fig(31, "minutes", "median of 6 = 31 min")),
      TodayRepeatItem(taskKey: "k_000000000002", name: "Reconcile invoices",
                      instances: fig(4, "count", "Mon 1 + Wed 1 + Thu 2 = 4 times"),
                      minutes: fig(130, "minutes", "4 times · 32 min median · 130 min = 2.2 h"), medianMinutes: nil),
      TodayRepeatItem(taskKey: "k_000000000003", name: "Copy figures into the weekly update",
                      instances: fig(3, "count", "Tue 1 + Thu 2 = 3 times"),
                      minutes: fig(54, "minutes", "3 times · 18 min median · 54 min = 0.9 h"), medianMinutes: nil),
    ]
    let fix = Opportunity(
      id: "sample", taskKey: "k_000000000001", title: "You've reviewed pull requests 6 times this week.", rank: 1,
      state: .open,
      options: [
        FixOption(id: "sample_1", optionNo: 1, title: "A checklist tool that pre-reads each pull request",
                  detail: "tool · flags missing tests and risky files", recommended: true,
                  estimate: fig(1.4, "hours_per_week", "31 min × 6 × 0.45 = 1.4 h/wk")),
        FixOption(id: "sample_2", optionNo: 2, title: "Batch reviews into one 45-min block",
                  detail: "setup · a calendar block and one notification a day",
                  estimate: fig(0.6, "hours_per_week", "0.6 h/wk")),
      ])
    return TodayPayload(date: nil, dayGrid: TodayDayGridPayload(categories: categories, cells: cells, switchBursts: bursts),
                        whatYouDid: did, repeats: repeats, suggestedFix: fix)
  }
}
