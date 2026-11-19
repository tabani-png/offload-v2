import Foundation

// Which files in a folder are screen recordings or screenshots, and when they were made. Ported from PR #44
// (engine/Sources/OffloadCore/Recordings/RecordingName.swift) and wip/s34-brain (brain/src/import/timestamps.ts).

public enum RecordingName {
  /// Video containers AVFoundation reads that screen recorders write.
  public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
  /// Screenshot formats ImageIO reads.
  public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]

  /// A video that is not hidden (macOS writes in-progress recordings as dot files) and not a partial download.
  public static func isVideo(_ name: String) -> Bool {
    guard !name.hasPrefix(".") else { return false }
    return videoExtensions.contains((name as NSString).pathExtension.lowercased())
  }

  /// A screenshot that is not hidden.
  public static func isImage(_ name: String) -> Bool {
    guard !name.hasPrefix(".") else { return false }
    return imageExtensions.contains((name as NSString).pathExtension.lowercased())
  }

  /// Times outside 2000-01-01 to 2100-01-01 are not timestamps.
  static let earliest = Date(timeIntervalSince1970: 946_684_800)
  static let latest = Date(timeIntervalSince1970: 4_102_444_800)

  // "Screen Recording 2026-11-13 at 9.41.07 AM.mov" (macOS 13 and later put U+202F before AM/PM), "... at 21.41.07"
  // (24-hour locales), "... AM (2).mov" (copies), "Screenshot ...", "Screen Shot ...", "CleanShot ... at 09.41.07@2x".
  private static let space = "[\\s\\x{00A0}\\x{202F}]"
  // NSRegularExpression is immutable and safe to share; it is not marked Sendable in every SDK.
  nonisolated(unsafe) private static let atPattern = try! NSRegularExpression(
    pattern: "(\\d{4})-(\\d{2})-(\\d{2})\(space)+at\(space)+(\\d{1,2})[.:](\\d{2})[.:](\\d{2})(?:\(space)*([AaPp])\\.?[Mm]\\.?)?")
  /// ISO-ish, as QuickTime and many tools write: 2026-10-20T10-15-32, 2026-10-20 10:15:32, 2026-11-13 09.41.07.
  nonisolated(unsafe) private static let isoPattern = try! NSRegularExpression(
    pattern: "(\\d{4})-(\\d{2})-(\\d{2})[T _-](\\d{2})[-:.](\\d{2})[-:.](\\d{2})")
  /// Compact: 20261020_101532, 20261020-101532, 20261020T101532.
  nonisolated(unsafe) private static let compactPattern = try! NSRegularExpression(
    pattern: "(?<!\\d)(\\d{4})(\\d{2})(\\d{2})[_T-]?(\\d{2})(\\d{2})(\\d{2})(?!\\d)")
  /// Unix seconds (10 digits) or milliseconds (13 digits), alone in the name.
  nonisolated(unsafe) private static let unixPattern = try! NSRegularExpression(pattern: "(?<!\\d)(\\d{13}|\\d{10})(?!\\d)")
  nonisolated(unsafe) private static let extensionPattern = try! NSRegularExpression(pattern: "\\.[A-Za-z0-9]{2,5}$")

  /// The time a file name carries, on the Mac's local clock (`timeZone`); nil when the name has none or it is not a
  /// real date (2026-13-40 and 2026-02-31 are nil, never rolled over).
  public static func date(fromName name: String, timeZone: TimeZone = .current) -> Date? {
    let base = extensionPattern.stringByReplacingMatches(
      in: name, range: NSRange(location: 0, length: (name as NSString).length), withTemplate: "")
    let ns = base as NSString
    let all = NSRange(location: 0, length: ns.length)
    func int(_ m: NSTextCheckingResult, _ i: Int) -> Int? {
      let r = m.range(at: i)
      return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
    }
    if let m = atPattern.firstMatch(in: base, range: all) {
      guard var h = int(m, 4) else { return nil }
      let ampm = m.range(at: 7)
      if ampm.location != NSNotFound {
        guard (1...12).contains(h) else { return nil }
        let pm = ns.substring(with: ampm).lowercased() == "p"
        h = pm ? (h % 12) + 12 : h % 12
      }
      return local(int(m, 1), int(m, 2), int(m, 3), h, int(m, 5), int(m, 6), timeZone)
    }
    if let m = isoPattern.firstMatch(in: base, range: all) ?? compactPattern.firstMatch(in: base, range: all) {
      return local(int(m, 1), int(m, 2), int(m, 3), int(m, 4), int(m, 5), int(m, 6), timeZone)
    }
    if let m = unixPattern.firstMatch(in: base, range: all) {
      let digits = ns.substring(with: m.range(at: 1))
      guard let v = Double(digits) else { return nil }
      let date = Date(timeIntervalSince1970: digits.count == 13 ? v / 1000 : v)
      return date >= earliest && date <= latest ? date : nil
    }
    return nil
  }

  private static func local(_ y: Int?, _ mo: Int?, _ d: Int?, _ h: Int?, _ mi: Int?, _ s: Int?, _ tz: TimeZone) -> Date? {
    guard let y, let mo, let d, let h, let mi, let s else { return nil }
    guard (1...12).contains(mo), (1...31).contains(d), (0...23).contains(h), (0...59).contains(mi), (0...60).contains(s) else {
      return nil
    }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    guard let date = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: min(s, 59))) else {
      return nil
    }
    // Calendar rolls 2026-02-31 over to March; a real date round-trips.
    let back = cal.dateComponents([.year, .month, .day], from: date)
    guard back.year == y, back.month == mo, back.day == d else { return nil }
    return date >= earliest && date <= latest ? date : nil
  }
}

/// When to take frames out of a recording.
public enum SamplePlan {
  /// Seconds between frames.
  public static let interval: TimeInterval = 5
  /// At most this many frames per recording (one hour at 5 s); longer clips are spread evenly.
  public static let maxFrames = 720

  /// Every `interval` seconds from 0 while before `duration`; at most `maxFrames`, spread evenly when a long clip
  /// would need more. A clip shorter than one interval still gives its first frame; an empty one gives none.
  public static func times(duration: TimeInterval, interval: TimeInterval = SamplePlan.interval,
                           maxFrames: Int = SamplePlan.maxFrames) -> [TimeInterval] {
    guard duration > 0, interval > 0, maxFrames > 0 else { return [] }
    let wanted = Int((duration / interval).rounded(.up))
    if wanted <= maxFrames { return (0..<wanted).map { TimeInterval($0) * interval } }
    let step = duration / TimeInterval(maxFrames)
    return (0..<maxFrames).map { TimeInterval($0) * step }
  }
}
