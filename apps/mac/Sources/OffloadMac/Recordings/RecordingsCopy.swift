import Foundation
import OffloadImport

// Every recordings string (screen 11, Settings, Recordings, the progress panel) in one place, so the copy tests see
// them. Facts are separate items, never one middle-dot string (MetaItems); views draw the dots.

public enum RecordingsCopy {
  public static let notReady = "Reading recordings needs on-device text reading, which comes with screen capture in a later update. Nothing was read."
  public static let needsSending = "Importing recordings starts once you're signed in and sending. Nothing was read."
  public static let settingsTitle = "Recordings"
  public static let settingsHelp = "Pick the folder your screen recordings are saved in. Offload reads them on this Mac into their own space, kept apart from what it watches live, and never changes the files."
  public static let menuItem = "Recordings…"
  public static let folderLabel = "Folder"
  public static let noImports = "Nothing imported yet."
  public static let removeImported = "Remove imported data"
  public static let removeFailed = "Couldn't remove it. Try again."
  public static let panelTitle = "Importing recordings"
  public static let close = "Close"
  public static let starting = "looking at the folder"
  public static let noNew = "No new recordings."
  public static let done = "done"

  /// Screen 11: "12 files", ".mov", "6 h 10 m", "Nov 5 to 11".
  public static func summaryItems(_ s: FolderSummary, timeZone: TimeZone = .current) -> [String] {
    var items: [String] = []
    if s.sourceKind == .screenwatch {
      items.append(count(s.files, "day", "days"))
      items.append("screenwatch archive")
    } else {
      items.append(count(s.files, "file", "files"))
      if !s.extensions.isEmpty { items.append(s.extensions.map { "." + $0 }.joined(separator: ", ")) }
      if let total = s.totalSeconds { items.append(length(seconds: total)) }
    }
    if let range = dateRange(s.first, s.last, timeZone: timeZone) { items.append(range) }
    return items
  }

  /// "reading file 3 of 12".
  public static func reading(file: Int, of total: Int) -> String { "reading file \(max(1, file)) of \(total)" }

  /// "done", "1,284 moments read"; or "No new recordings." when nothing new was read.
  public static func doneItems(_ r: ImportReport) -> [String] {
    r.filesRead == 0 ? [noNew] : [done, "\(grouped(r.moments)) moments read"]
  }

  public static func warning(_ w: ImportWarning) -> String {
    switch w {
    case .stillWriting(let n):
      return n == 1 ? "1 file is still being written. Import again when it's finished."
                    : "\(n) files are still being written. Import again when they're finished."
    case .unreadable(let file): return "Couldn't read \(file)."
    case .futureTime(let file): return "\(file) has a time in the future, so it was skipped."
    }
  }

  /// Settings, Recordings: one import space. "Recordings from Desktop", "Nov 5 to 11", "1,284 moments read".
  public static func pill(_ r: ImportRecord, timeZone: TimeZone = .current) -> [String] {
    var items = ["Recordings from \(r.folderName)"]
    if let range = dateRange(r.first, r.last, timeZone: timeZone) { items.append(range) }
    items.append("\(grouped(r.moments)) moments read")
    return items
  }

  /// "Nov 5", "Nov 5 to 11", "Oct 30 to Nov 2"; nil without dates.
  public static func dateRange(_ first: Date?, _ last: Date?, timeZone: TimeZone = .current) -> String? {
    guard let first = first ?? last, let last = last ?? first else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let a = cal.dateComponents([.year, .month, .day], from: min(first, last))
    let b = cal.dateComponents([.year, .month, .day], from: max(first, last))
    let start = "\(month(a.month)) \(a.day ?? 1)"
    if a.year == b.year && a.month == b.month {
      return a.day == b.day ? start : "\(start) to \(b.day ?? 1)"
    }
    return "\(start) to \(month(b.month)) \(b.day ?? 1)"
  }

  /// "6 h 10 m", "45 m"; at least "1 m".
  public static func length(seconds: TimeInterval) -> String {
    let minutes = max(1, Int((seconds / 60).rounded()))
    let h = minutes / 60
    let m = minutes % 60
    if h == 0 { return "\(m) m" }
    return m == 0 ? "\(h) h" : "\(h) h \(m) m"
  }

  /// 1284 → "1,284" (fixed, not the locale's grouping, so the copy is the same on every Mac).
  public static func grouped(_ n: Int) -> String {
    let digits = String(abs(n))
    var out = ""
    for (i, ch) in digits.enumerated() {
      if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
      out.append(ch)
    }
    return n < 0 ? "-" + out : out
  }

  static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

  static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  static func month(_ m: Int?) -> String { months[max(1, min(12, m ?? 1)) - 1] }

  /// Every fixed string, plus samples of the built ones, for the copy tests.
  public static var all: [String] {
    let sample = FolderSummary(sourceKind: .videos, files: 12, extensions: ["mov"], totalSeconds: 22_200,
                               first: Date(timeIntervalSince1970: 1_794_000_000), last: Date(timeIntervalSince1970: 1_794_500_000))
    let report = ImportReport(space: nil, filesRead: 11, skipped: 0, failed: 1, stillWriting: 0, moments: 1284,
                              observations: 0, firstDay: nil, lastDay: nil)
    return [notReady, needsSending, settingsTitle, settingsHelp, menuItem, folderLabel, noImports, removeImported, removeFailed,
            panelTitle, close, starting, noNew, done, reading(file: 3, of: 12),
            warning(.stillWriting(files: 1)), warning(.stillWriting(files: 2)), warning(.unreadable(file: "a.mov")),
            warning(.futureTime(file: "a.mov"))]
      + summaryItems(sample) + doneItems(report)
  }
}
