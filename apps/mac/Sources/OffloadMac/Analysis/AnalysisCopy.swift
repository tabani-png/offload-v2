import Foundation
import OffloadImport

// Every local insights string in one place, so the copy tests see them. Facts are separate items, never one
// middle-dot string; views draw the dots.

public enum AnalysisCopy {
  /// The stand-in name for time in an app or site on the Never watch list.
  public static let neverWatchApp = "Never watch app"
  public static let nothingCounted = "nothing counted"
  /// Shown in the done line while the days of a finished import are being counted.
  public static let counting = "counting on this Mac"

  /// "9 things you repeat", "1 thing you repeat"; nil for none (the count is left out).
  public static func repeatsItem(_ n: Int) -> String? {
    guard n > 0 else { return nil }
    return n == 1 ? "1 thing you repeat" : "\(RecordingsCopy.grouped(n)) things you repeat"
  }

  /// The done line: m3-05's "done", "1,284 moments read", plus "9 things you repeat" once counted; "No new
  /// recordings." unchanged. `repeats` nil while the import's days are being counted.
  public static func doneItems(_ report: ImportReport, repeats: Int?) -> [String] {
    let base = RecordingsCopy.doneItems(report)
    guard report.filesRead > 0 else { return base }
    guard let repeats else { return base + [counting] }
    return base + (repeatsItem(repeats).map { [$0] } ?? [])
  }

  /// "1 h 10 m", "45 m", "40 s" (seconds under a minute).
  public static func duration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 60 { return "\(s) s" }
    return RecordingsCopy.length(seconds: TimeInterval(s))
  }

  /// "1.2 h".
  public static func hours(_ seconds: TimeInterval) -> String { "\(decimal((seconds / 360).rounded() / 10)) h" }

  /// One decimal, without a trailing ".0": 2.5 → "2.5", 3.0 → "3".
  public static func decimal(_ v: Double) -> String {
    let r = (v * 10).rounded() / 10
    if r == r.rounded() { return String(Int(r)) }
    return String(format: "%.1f", r)
  }

  /// Every fixed string and samples of the built ones, for the copy tests.
  public static var all: [String] {
    let report = ImportReport(space: nil, filesRead: 11, skipped: 0, failed: 1, stillWriting: 0, moments: 1284,
                              observations: 0, firstDay: nil, lastDay: nil)
    return [neverWatchApp, nothingCounted, counting, repeatsItem(1) ?? "", repeatsItem(9) ?? "", duration(40),
            duration(4200), hours(4320)]
      + doneItems(report, repeats: 9) + doneItems(report, repeats: nil)
  }

  /// Captions (lowercase, `·` items separate).
  public static var captions: [String] { [nothingCounted, counting] }
}
