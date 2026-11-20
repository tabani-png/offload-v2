import Foundation

// Ported from s33 (release/mac-testable, Core/MetaText.swift): facts are separate items, never middle-dot strings,
// and a sentence never ends on a lone word. Pure, so it is tested; views use it.

public enum MetaItems {
  /// "Watching · Day 7 of 7" → ["Watching", "Day 7 of 7"]. Empty pieces are dropped.
  public static func split(_ s: String) -> [String] {
    s.components(separatedBy: "·")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

public enum OrphanGuard {
  /// The no-break space that keeps the last two words on one line.
  public static let noBreakSpace = "\u{00A0}"

  /// "Nothing to do until then." → "Nothing to do until\u{00A0}then." (4 words or more; shorter lines are left alone).
  /// For drawing only: copy keeps plain spaces so tests and VoiceOver read it as it is.
  public static func glue(_ s: String) -> String {
    let words = s.split(separator: " ", omittingEmptySubsequences: false)
    guard words.count >= 4, let last = s.range(of: " ", options: .backwards) else { return s }
    return s.replacingCharacters(in: last, with: noBreakSpace)
  }
}

/// The typed invitation on screen 3: about 28 ms a character, or the final text at once with Reduce Motion.
public enum TypedText {
  public static let secondsPerCharacter: Double = 0.028

  public static func visible(_ text: String, elapsed: Double, reduceMotion: Bool,
                             perCharacter: Double = secondsPerCharacter) -> String {
    if reduceMotion || perCharacter <= 0 { return text }
    guard elapsed > 0 else { return "" }
    // A small epsilon so 4 × 0.028 s shows 4 characters despite floating point.
    let count = Int(elapsed / perCharacter + 1e-9)
    return String(text.prefix(max(0, count)))
  }

  /// Seconds until the whole text is shown.
  public static func duration(_ text: String, reduceMotion: Bool) -> Double {
    reduceMotion ? 0 : Double(text.count) * secondsPerCharacter
  }
}

/// What moves. Reduce Motion: final states, fades only.
public struct MotionPolicy: Equatable, Sendable {
  public var reduceMotion: Bool
  public init(reduceMotion: Bool) { self.reduceMotion = reduceMotion }

  /// The in-window pointer flies to the line once; with Reduce Motion it does not move.
  public var pointerFlies: Bool { !reduceMotion }
  /// Text types character by character; with Reduce Motion it appears whole.
  public var textTypes: Bool { !reduceMotion }
  /// Entrance offset in points (0 with Reduce Motion).
  public var riseOffset: Double { reduceMotion ? 0 : 7 }
}
