import Foundation

// Reduced port of s33 (release/mac-testable, Core/TimeHeadline.swift): the week leads with one sentence, then what
// could be faster, then where the time goes. The maths behind each finding sits behind a link, as separate items.
// The figures come from code (ADR 0003); this type only words them.

public enum HoursFormat {
  /// "31.5 h", one decimal.
  public static func display(hours: Double) -> String {
    String(format: "%.1f h", locale: Locale(identifier: "en_US_POSIX"), max(0, hours))
  }
}

public struct TimeHeadline: Equatable, Sendable {
  public enum Block: String, Equatable, Sendable { case headline, findings, detail }

  public struct Finding: Equatable, Sendable, Identifiable {
    public var id: String
    public var hoursFreed: Double
    /// The arithmetic, as counted ("6 times · 15 min each").
    public var arithmetic: String
    public init(id: String, hoursFreed: Double, arithmetic: String) {
      self.id = id
      self.hoursFreed = hoursFreed
      self.arithmetic = arithmetic
    }
  }

  public var totalHours: Double
  public var findings: [Finding]
  public var isDay: Bool

  public init(totalHours: Double, findings: [Finding], isDay: Bool = false) {
    self.totalHours = totalHours
    self.findings = findings
    self.isDay = isDay
  }

  public static let detailTitle = "Where the time goes"
  public static let findingsTitle = "What could be faster"
  public static let mathsTitle = "How these are worked out"
  public static let findingsFooter = "Hours freed are per week, at the pace Offload measured. Nothing is drafted until you open one."
  public static let emptyLine = "Nothing tracked yet."

  private var isEmptyWindow: Bool { totalHours <= 0 && findings.isEmpty }

  /// An empty window is the headline only.
  public var blocks: [Block] { isEmptyWindow ? [.headline] : (findings.isEmpty ? [.headline, .detail] : [.headline, .findings, .detail]) }

  public var headlineWorked: String {
    let total = HoursFormat.display(hours: totalHours)
    return isDay ? "You worked \(total) on this day." : "You worked \(total) this week."
  }

  /// The findings' hours freed added up; nil when nothing could be faster.
  public var freedTotal: String? {
    guard !findings.isEmpty else { return nil }
    return HoursFormat.display(hours: findings.reduce(0.0) { $0 + $1.hoursFreed })
  }

  public var headlineFreed: String? {
    guard let freed = freedTotal else { return nil }
    return isDay ? "At this pace, about \(freed) a week could run without you." : "About \(freed) a week of it could run without you."
  }

  public var headlineNone: String {
    isEmptyWindow ? Self.emptyLine : "Nothing repeats enough to hand off yet."
  }

  /// A finding's arithmetic as separate items, for the maths disclosure.
  public static func mathsItems(_ arithmetic: String) -> [String] {
    let items = MetaItems.split(arithmetic)
    return items.isEmpty ? [arithmetic].filter { !$0.isEmpty } : items
  }
}
