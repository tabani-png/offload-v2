import Foundation

// The six one-tap questions (ONBOARDING section 7). Stored as DATA_MODEL `profiles` fields via `PATCH /v1/profile`.
// Context only: they never change a counted hour (ADR 0003).

public enum Drain: String, Codable, CaseIterable, Hashable, Sendable {
  case email
  case meetings
  case agentBabysitting = "agent_babysitting"
  case reporting
  case content
  case admin
  case contextSwitching = "context_switching"

  public var label: String {
    switch self {
    case .email: return "Email"
    case .meetings: return "Meetings"
    case .agentBabysitting: return "Coding-agent babysitting"
    case .reporting: return "Reporting"
    case .content: return "Content"
    case .admin: return "Admin"
    case .contextSwitching: return "Context switching"
    }
  }
}

public enum Autonomy: String, Codable, CaseIterable, Hashable, Sendable {
  case suggest
  case draft
  case runApproved = "run_approved"

  public var label: String {
    switch self {
    case .suggest: return "Suggest only"
    case .draft: return "Draft for me"
    case .runApproved: return "Run fixes I've approved"
    }
  }

  public var detail: String {
    switch self {
    case .suggest: return "Show me what repeats. I'll decide."
    case .draft: return "Prepare the fix. I say OK before anything runs."
    case .runApproved: return "Once I've said OK to a fix, run it without asking."
    }
  }
}

public enum Weekday: String, Codable, CaseIterable, Hashable, Sendable {
  case mon, tue, wed, thu, fri, sat, sun

  public var short: String {
    switch self {
    case .mon: return "Mon"
    case .tue: return "Tue"
    case .wed: return "Wed"
    case .thu: return "Thu"
    case .fri: return "Fri"
    case .sat: return "Sat"
    case .sun: return "Sun"
    }
  }

  public var full: String {
    switch self {
    case .mon: return "Monday"
    case .tue: return "Tuesday"
    case .wed: return "Wednesday"
    case .thu: return "Thursday"
    case .fri: return "Friday"
    case .sat: return "Saturday"
    case .sun: return "Sunday"
    }
  }
}

/// Q4 "When do you work?": `profiles.schedule`, `timezone`, `review_slot`. Times are 24-hour "HH:mm".
public struct Rhythm: Codable, Equatable, Sendable {
  public var days: [Weekday]
  public var start: String
  public var end: String
  public var reviewDay: Weekday
  public var reviewTime: String
  public var timezone: String

  public init(days: [Weekday] = [.mon, .tue, .wed, .thu, .fri], start: String = "09:00", end: String = "18:00",
              reviewDay: Weekday = .fri, reviewTime: String = "16:00", timezone: String = TimeZone.current.identifier) {
    self.days = days
    self.start = start
    self.end = end
    self.reviewDay = reviewDay
    self.reviewTime = reviewTime
    self.timezone = timezone
  }

  /// "Mon to Fri" for a run of days, else the days listed.
  public var daysText: String {
    let all = Weekday.allCases
    let idx = days.compactMap { all.firstIndex(of: $0) }.sorted()
    guard let first = idx.first, let last = idx.last else { return "No days" }
    if idx.count > 2 && idx == Array(first...last) { return "\(all[first].short) to \(all[last].short)" }
    return idx.map { all[$0].short }.joined(separator: ", ")
  }

  public var hoursText: String { "\(Self.clock(start)) to \(Self.clock(end))" }
  public var reviewText: String { "\(reviewDay.short) \(Self.clock(reviewTime))" }
  public var reviewLong: String { "\(reviewDay.full) at \(Self.clock(reviewTime))" }

  /// "16:00" → "4:00 PM"; anything unreadable is returned as given.
  public static func clock(_ hhmm: String) -> String {
    let parts = hhmm.split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return hhmm }
    let hour12 = h % 12 == 0 ? 12 : h % 12
    let suffix = h < 12 ? "AM" : "PM"
    let minutes = m < 10 ? "0\(m)" : "\(m)"
    return "\(hour12):\(minutes) \(suffix)"
  }
}

/// Q2 rules: up to 3 goals, each one line of at most 80 characters.
public enum Goals {
  public static let max = 3
  public static let maxLength = 80
  public static let choices = ["Ship a product", "More deep work", "Close customers", "Less admin", "Learn something new"]

  public static func clean(_ goals: [String]) -> [String] {
    var out: [String] = []
    for g in goals {
      let firstLine = g.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
      let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      out.append(String(trimmed.prefix(maxLength)))
      if out.count == max { break }
    }
    return out
  }
}

/// Q1 choices.
public enum Roles {
  public static let choices = ["Founder", "Engineer", "Designer", "Sales", "Operations", "Creator"]
}

/// What the person answered. Empty until answered; skipping leaves a field empty.
public struct ProfileAnswers: Codable, Equatable, Sendable {
  public var role: String?
  public var goals: [String] = []
  public var drains: [Drain] = []
  public var rhythm: Rhythm?
  public var autonomy: Autonomy?
  public init() {}
}

/// One answer, as given on its screen.
public enum ProfileAnswer: Equatable, Sendable {
  case role(String)
  case goals([String])
  case drains([Drain])
  case rhythm(Rhythm)
  case autonomy(Autonomy)
}

/// A partial `PATCH /v1/profile` body: only the answered field is present.
public struct ProfileUpdate: Equatable, Sendable {
  public var role: String?
  public var goals: [String]?
  public var drains: [Drain]?
  public var rhythm: Rhythm?
  public var autonomy: Autonomy?

  public init(role: String? = nil, goals: [String]? = nil, drains: [Drain]? = nil, rhythm: Rhythm? = nil, autonomy: Autonomy? = nil) {
    self.role = role
    self.goals = goals
    self.drains = drains
    self.rhythm = rhythm
    self.autonomy = autonomy
  }

  /// The `profiles` fields this update writes.
  public var fieldNames: [String] {
    var f: [String] = []
    if role != nil { f.append("role") }
    if goals != nil { f.append("goals") }
    if drains != nil { f.append("drains") }
    if rhythm != nil { f += ["schedule", "timezone", "review_slot"] }
    if autonomy != nil { f.append("autonomy") }
    return f
  }
}
