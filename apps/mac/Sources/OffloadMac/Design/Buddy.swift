import Foundation

// Ported from s33 (release/mac-testable, Core/Buddy.swift): the buddy is the menu bar mark with a face. Resting when
// watching is off, half up while it watches, all the way up when it has found something. It speaks in short
// lowercase lines, never shouts, and never uses a status colour.

/// What the observer is doing, as the menu bar sees it (m3-02 reports it; until then the app reports noData).
public enum ObserverState: String, CaseIterable, Sendable {
  case watching, noData, paused, stale
}

public enum BuddyEyes: String, Sendable {
  case open, wide, closed
}

public enum BuddyMood: String, CaseIterable, Sendable {
  case watching
  case foundSomething
  case quiet

  /// How far the block is lifted: 0 resting, 1 all the way up.
  public var lift: Double {
    switch self {
    case .quiet: return 0
    case .watching: return 0.55
    case .foundSomething: return 1
    }
  }

  /// Only finding something earns the highlight, so it stays rare.
  public var highlightsBlock: Bool { self == .foundSomething }

  public var eyes: BuddyEyes {
    switch self {
    case .watching: return .open
    case .foundSomething: return .wide
    case .quiet: return .closed
    }
  }

  /// Its one line, for a tooltip or under the mark.
  public var line: String {
    switch self {
    case .watching: return "watching quietly."
    case .foundSomething: return "found something for you."
    case .quiet: return "resting for now."
    }
  }

  /// Something waiting wins; then paused or stale is quiet.
  public static func of(observer: ObserverState, waiting: Int) -> BuddyMood {
    if waiting > 0 { return .foundSomething }
    switch observer {
    case .paused, .stale: return .quiet
    case .watching, .noData: return .watching
    }
  }
}

public enum BuddyLine {
  /// A workday, for the plain line under a weekly figure.
  public static let workdayHours: Double = 8

  /// "about two workdays back, every week." A friendly reading of hours; the number itself sits above it.
  public static func weekly(hours h: Double) -> String {
    "\(amount(h)) back, every week."
  }

  private static func amount(_ h: Double) -> String {
    if h < 2 { return "a little time" }
    if h < 6 { return "about an afternoon" }
    if h < 12 { return "about a workday" }
    if h < 36 {
      let n = min(4, max(2, Int((h / workdayHours).rounded())))
      switch n {
      case 3: return "about three workdays"
      case 4: return "about four workdays"
      default: return "about two workdays"
      }
    }
    return "about a whole workweek"
  }
}
