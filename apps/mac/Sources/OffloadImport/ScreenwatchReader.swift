import Foundation

// Ported from wip/s34-brain (brain/src/import/screenwatch.ts `parseLog`, `activityRuns`, and folder.ts `focusOf`):
// a screenwatch archive (`days/YYYY-MM-DD/log.jsonl`, rows `{t, epoch, app?, window?, url?, img?}` about every 5 s).
// Rows with app, window and URL become masked focus observations (title masked, URL reduced to its host); rows
// without app fields get one synthetic app. The archive's screenshots are not read: the rows carry the focus.

public struct ScreenwatchRow: Equatable, Sendable {
  /// "HH-MM-SS", the screenshot's file stem.
  public var t: String
  public var ts: Date
  public var app: String?
  public var window: String?
  public var url: String?
  public var img: Bool

  public init(t: String, ts: Date, app: String?, window: String?, url: String?, img: Bool) {
    self.t = t
    self.ts = ts
    self.app = app
    self.window = window
    self.url = url
    self.img = img
  }
}

public enum ScreenwatchReader {
  public static let syntheticAppID = "screenwatch.screen"
  public static let syntheticAppName = "Screen"

  /// Parses `log.jsonl`. Bad lines are counted; rows are unique by epoch (two writers can log the same second) and
  /// come back sorted.
  public static func parse(_ text: String) -> (rows: [ScreenwatchRow], bad: Int, duplicates: Int) {
    var byMs: [Int64: ScreenwatchRow] = [:]
    var bad = 0
    var duplicates = 0
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let t = object["t"] as? String, t.range(of: #"^\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
            let epoch = (object["epoch"] as? NSNumber)?.doubleValue, epoch.isFinite
      else {
        bad += 1
        continue
      }
      let ms = Int64((epoch * 1000).rounded())
      let img = (object["img"] as? Bool) ?? false
      if var prev = byMs[ms] {
        duplicates += 1
        if img { prev.img = true }
        byMs[ms] = prev
        continue
      }
      func field(_ key: String) -> String? {
        guard let v = object[key] as? String else { return nil }
        let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
      }
      byMs[ms] = ScreenwatchRow(t: t, ts: Date(timeIntervalSince1970: TimeInterval(ms) / 1000), app: field("app"),
                                window: field("window"), url: field("url"), img: img)
    }
    return (byMs.values.sorted { $0.ts < $1.ts }, bad, duplicates)
  }

  /// Sorted rows to observations. Activity runs are rows at most `gap` apart; each run opens with `idle_end` and a
  /// focus, has a focus whenever the app, title or host changes, and closes with `idle_start` `idleThreshold` after its
  /// last row (readers backdate it).
  public static func observations(rows: [ScreenwatchRow], importID: String, masker: any ImportTextMasker,
                                  exclusions: [ImportExclusionRule], ids: ULIDGenerator,
                                  idleThreshold: TimeInterval = 120, gap: TimeInterval = 120) -> [ImportObservation] {
    var out: [ImportObservation] = []
    var lastRowAt: Date?
    var lastKey: String?
    for row in rows {
      if let prev = lastRowAt, row.ts.timeIntervalSince(prev) > gap {
        out.append(.idle(.idleStart, id: ids.next(at: prev.addingTimeInterval(idleThreshold)),
                         ts: prev.addingTimeInterval(idleThreshold), importID: importID))
        lastKey = nil
      }
      if lastKey == nil { out.append(.idle(.idleEnd, id: ids.next(at: row.ts), ts: row.ts, importID: importID)) }
      let focus = Self.focus(of: row, masker: masker, exclusions: exclusions)
      let key = "\(focus.app)\u{0}\(focus.title ?? "")\u{0}\(focus.host ?? "")"
      if key != lastKey {
        out.append(.focus(id: ids.next(at: row.ts), ts: row.ts, importID: importID, appBundleID: focus.app,
                          appName: focus.appName, title: focus.title, host: focus.host))
        lastKey = key
      }
      lastRowAt = row.ts
    }
    if let prev = lastRowAt {
      out.append(.idle(.idleStart, id: ids.next(at: prev.addingTimeInterval(idleThreshold)),
                       ts: prev.addingTimeInterval(idleThreshold), importID: importID))
    }
    return out
  }

  struct Focus {
    var app: String
    var appName: String
    var title: String?
    var host: String?
  }

  /// What a row says was on screen, masked. An excluded app (password manager, banking, private window, the
  /// person's Never watch list) keeps its name only.
  static func focus(of row: ScreenwatchRow, masker: any ImportTextMasker, exclusions: [ImportExclusionRule]) -> Focus {
    guard let raw = row.app else { return Focus(app: syntheticAppID, appName: syntheticAppName) }
    let isBundle = raw.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil
    let app = isBundle ? raw : MenuBarApp.bundleID(for: raw)
    let appName = isBundle ? (raw.split(separator: ".").last.map(String.init) ?? raw) : raw
    let host = row.url.flatMap(Self.host(of:))
    if ImportExclusions.isExcluded(bundleID: app, appName: appName, title: row.window, host: host, rules: exclusions) {
      return Focus(app: app, appName: appName)
    }
    let title = row.window.map { masker.mask($0) }.flatMap { $0.isEmpty ? nil : $0 }
    return Focus(app: app, appName: appName, title: title, host: host)
  }

  /// The host of an http(s) URL, lowercased; nil for anything else. Paths, queries and fragments are dropped.
  static func host(of raw: String) -> String? {
    let withScheme = raw.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil ? raw : "https://" + raw
    guard let c = URLComponents(string: withScheme), let scheme = c.scheme?.lowercased(),
          scheme == "http" || scheme == "https", let host = c.host?.lowercased(), !host.isEmpty else { return nil }
    return host
  }
}
