import Foundation

// The brain's shapes, exactly as the brain port builds them (port/brain-user-model: profile/profile.ts,
// records/day-record.ts, records/week-record.ts, review/answers.ts, review/week-review.ts). Numbers are `Figure`s
// (ADR 0003). Unknown fields are ignored; unknown enum values decode to `.unknown(raw)`.

// MARK: Profile

/// A goal as the brain stores it (`g_` + 10 hex).
public struct BrainGoal: Codable, Equatable, Sendable {
  public var id: String
  public var text: String
  public var horizon: String
  public var createdAt: String?
  public var archivedAt: String?

  public init(id: String, text: String, horizon: String = "90d", createdAt: String? = nil, archivedAt: String? = nil) {
    self.id = id
    self.text = text
    self.horizon = horizon
    self.createdAt = createdAt
    self.archivedAt = archivedAt
  }

  enum CodingKeys: String, CodingKey {
    case id, text, horizon
    case createdAt = "created_at"
    case archivedAt = "archived_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    text = try c.decode(String.self, forKey: .text)
    horizon = c.lenient(String.self, forKey: .horizon) ?? "90d"
    createdAt = c.lenient(String.self, forKey: .createdAt)
    archivedAt = c.lenient(String.self, forKey: .archivedAt)
  }
}

/// Working days and hours. `days` are the brain's weekday words (`mon` ... `sun`), times `HH:MM`.
public struct BrainSchedule: Codable, Equatable, Sendable {
  public var days: [String]
  public var start: String
  public var end: String

  public init(days: [String], start: String, end: String) {
    self.days = days
    self.start = start
    self.end = end
  }

  var json: JSONValue {
    .object(["days": .array(days.map { .string($0) }), "start": .string(start), "end": .string(end)])
  }
}

/// When the weekly review is offered. `day` is a weekday word (`mon` ... `sun`), `time` is `HH:MM`.
public struct BrainReviewSlot: Codable, Equatable, Sendable {
  public var day: String
  public var time: String

  public init(day: String, time: String) {
    self.day = day
    self.time = time
  }

  var json: JSONValue { .object(["day": .string(day), "time": .string(time)]) }
}

/// `GET /v1/profile`. Fields the server leaves out take the brain's `defaultProfile()` values. Enum-like fields stay
/// the brain's words (`drains`, `autonomy`, `own_name_to_models`); the allowed values are listed below.
public struct BrainProfile: Codable, Equatable, Sendable {
  public static let drainValues = ["email", "meetings", "agent_babysitting", "reporting", "content", "admin", "context_switching"]
  public static let autonomyValues = ["suggest", "draft", "run_approved"]
  public static let weekdayValues = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
  public static let ownNameValues = ["mask", "keep"]

  public var version: Int
  public var role: String?
  public var industry: String?
  public var goals: [BrainGoal]
  public var drains: [String]
  public var schedule: BrainSchedule?
  public var timezone: String
  public var reviewSlot: BrainReviewSlot
  public var autonomy: String
  public var ownNameToModels: String
  public var keyframesToCloud: Bool
  public var learningPaused: Bool
  public var updatedAt: String?

  public init(
    version: Int = 0,
    role: String? = nil,
    industry: String? = nil,
    goals: [BrainGoal] = [],
    drains: [String] = [],
    schedule: BrainSchedule? = nil,
    timezone: String = "UTC",
    reviewSlot: BrainReviewSlot = BrainReviewSlot(day: "fri", time: "16:00"),
    autonomy: String = "suggest",
    ownNameToModels: String = "mask",
    keyframesToCloud: Bool = false,
    learningPaused: Bool = false,
    updatedAt: String? = nil
  ) {
    self.version = version
    self.role = role
    self.industry = industry
    self.goals = goals
    self.drains = drains
    self.schedule = schedule
    self.timezone = timezone
    self.reviewSlot = reviewSlot
    self.autonomy = autonomy
    self.ownNameToModels = ownNameToModels
    self.keyframesToCloud = keyframesToCloud
    self.learningPaused = learningPaused
    self.updatedAt = updatedAt
  }

  /// The brain's `defaultProfile()`.
  public static let defaults = BrainProfile()

  enum CodingKeys: String, CodingKey {
    case version, role, industry, goals, drains, schedule, timezone, autonomy
    case reviewSlot = "review_slot"
    case ownNameToModels = "own_name_to_models"
    case keyframesToCloud = "keyframes_to_cloud"
    case learningPaused = "learning_paused"
    case updatedAt = "updated_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = BrainProfile.defaults
    version = c.lenient(Int.self, forKey: .version) ?? d.version
    role = c.lenient(String.self, forKey: .role)
    industry = c.lenient(String.self, forKey: .industry)
    goals = c.lossyList(BrainGoal.self, forKey: .goals)
    drains = c.lenient([String].self, forKey: .drains) ?? d.drains
    schedule = c.lenient(BrainSchedule.self, forKey: .schedule)
    timezone = c.lenient(String.self, forKey: .timezone) ?? d.timezone
    reviewSlot = c.lenient(BrainReviewSlot.self, forKey: .reviewSlot) ?? d.reviewSlot
    autonomy = c.lenient(String.self, forKey: .autonomy) ?? d.autonomy
    ownNameToModels = c.lenient(String.self, forKey: .ownNameToModels) ?? d.ownNameToModels
    keyframesToCloud = c.lenient(Bool.self, forKey: .keyframesToCloud) ?? d.keyframesToCloud
    learningPaused = c.lenient(Bool.self, forKey: .learningPaused) ?? d.learningPaused
    updatedAt = c.lenient(String.self, forKey: .updatedAt)
  }
}

/// A `PATCH /v1/profile` body. Only the brain's PATCHABLE keys can be set; keys not set are not sent. `setRole(nil)`,
/// `setIndustry(nil)` and `setSchedule(nil)` send `null`, which clears the field.
public struct BrainProfilePatch: Equatable, Sendable {
  /// The brain port's `PATCHABLE`, in its order.
  public static let patchableKeys = [
    "role", "industry", "goals", "drains", "schedule", "timezone", "review_slot", "autonomy", "own_name_to_models",
    "keyframes_to_cloud",
  ]

  public private(set) var fields: [String: JSONValue] = [:]

  public init() {}

  public var isEmpty: Bool { fields.isEmpty }
  /// The body as a JSON object (written with `JCS.encode`).
  public var body: JSONValue { .object(fields) }

  public mutating func setRole(_ role: String?) { fields["role"] = Self.stringOrNull(role) }
  public mutating func setIndustry(_ industry: String?) { fields["industry"] = Self.stringOrNull(industry) }
  /// Goal texts in order (at most 3, one line, 80 characters each; the brain checks).
  public mutating func setGoals(_ texts: [String]) { fields["goals"] = .array(texts.map { .string($0) }) }
  public mutating func setDrains(_ drains: [String]) { fields["drains"] = .array(drains.map { .string($0) }) }
  public mutating func setSchedule(_ schedule: BrainSchedule?) {
    if let schedule {
      fields["schedule"] = schedule.json
    } else {
      fields["schedule"] = JSONValue.null
    }
  }
  public mutating func setTimezone(_ timezone: String) { fields["timezone"] = .string(timezone) }
  public mutating func setReviewSlot(_ slot: BrainReviewSlot) { fields["review_slot"] = slot.json }
  public mutating func setAutonomy(_ autonomy: String) { fields["autonomy"] = .string(autonomy) }
  public mutating func setOwnNameToModels(_ value: String) { fields["own_name_to_models"] = .string(value) }
  public mutating func setKeyframesToCloud(_ value: Bool) { fields["keyframes_to_cloud"] = .bool(value) }

  static func stringOrNull(_ s: String?) -> JSONValue {
    if let s { return .string(s) }
    return .null
  }
}

// MARK: Day record

public struct DayTotals: Codable, Equatable, Sendable {
  public var activeMinutes: Figure
  public var switches: Figure
  public var switchesPerActiveHour: Figure
  public var focusBlocks: Figure
  public var focusMinutes: Figure
  public var meetingMinutes: Figure

  public init(
    activeMinutes: Figure, switches: Figure, switchesPerActiveHour: Figure, focusBlocks: Figure, focusMinutes: Figure,
    meetingMinutes: Figure
  ) {
    self.activeMinutes = activeMinutes
    self.switches = switches
    self.switchesPerActiveHour = switchesPerActiveHour
    self.focusBlocks = focusBlocks
    self.focusMinutes = focusMinutes
    self.meetingMinutes = meetingMinutes
  }

  enum CodingKeys: String, CodingKey {
    case switches
    case activeMinutes = "active_minutes"
    case switchesPerActiveHour = "switches_per_active_hour"
    case focusBlocks = "focus_blocks"
    case focusMinutes = "focus_minutes"
    case meetingMinutes = "meeting_minutes"
  }
}

/// Minutes of one work kind (`by_kind`).
public struct KindMinutes: Codable, Equatable, Sendable {
  public var kind: String
  public var minutes: Figure
  public init(kind: String, minutes: Figure) {
    self.kind = kind
    self.minutes = minutes
  }
}

/// Minutes in one app (`by_app`, the bundle id).
public struct AppMinutes: Codable, Equatable, Sendable {
  public var app: String
  public var minutes: Figure
  public init(app: String, minutes: Figure) {
    self.app = app
    self.minutes = minutes
  }
}

/// One task on one day (`by_task`).
public struct DayTask: Codable, Equatable, Sendable {
  public var taskKey: String
  public var name: String
  public var minutes: Figure
  public var instances: Figure
  public var medianMinutes: Figure

  public init(taskKey: String, name: String, minutes: Figure, instances: Figure, medianMinutes: Figure) {
    self.taskKey = taskKey
    self.name = name
    self.minutes = minutes
    self.instances = instances
    self.medianMinutes = medianMinutes
  }

  enum CodingKeys: String, CodingKey {
    case name, minutes, instances
    case taskKey = "task_key"
    case medianMinutes = "median_minutes"
  }
}

/// `GET /v1/records/days/{date}`.
public struct DayRecord: Codable, Equatable, Sendable {
  public var day: String
  public var generatedAt: String
  public var totals: DayTotals
  public var byKind: [KindMinutes]
  public var byApp: [AppMinutes]
  public var byTask: [DayTask]
  public var episodeIDs: [String]
  public var sourcePurgedAt: String?

  public init(
    day: String, generatedAt: String, totals: DayTotals, byKind: [KindMinutes], byApp: [AppMinutes],
    byTask: [DayTask], episodeIDs: [String], sourcePurgedAt: String?
  ) {
    self.day = day
    self.generatedAt = generatedAt
    self.totals = totals
    self.byKind = byKind
    self.byApp = byApp
    self.byTask = byTask
    self.episodeIDs = episodeIDs
    self.sourcePurgedAt = sourcePurgedAt
  }

  enum CodingKeys: String, CodingKey {
    case day, totals
    case generatedAt = "generated_at"
    case byKind = "by_kind"
    case byApp = "by_app"
    case byTask = "by_task"
    case episodeIDs = "episode_ids"
    case sourcePurgedAt = "source_purged_at"
  }
}

// MARK: Week record

public enum WeekTaskStatus: Equatable, Hashable, Sendable, Codable {
  case new, recurring, gone
  case unknown(String)

  public init(raw: String) {
    switch raw {
    case "new": self = .new
    case "recurring": self = .recurring
    case "gone": self = .gone
    default: self = .unknown(raw)
    }
  }

  public var raw: String {
    switch self {
    case .new: return "new"
    case .recurring: return "recurring"
    case .gone: return "gone"
    case .unknown(let raw): return raw
    }
  }

  public init(from decoder: any Decoder) throws {
    self.init(raw: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(raw)
  }
}

public struct WeekTask: Codable, Equatable, Sendable {
  public var taskKey: String
  public var name: String
  public var minutes: Figure
  public var instances: Figure
  public var medianMinutes: Figure
  /// Null when the task was not present in the 8 calendar weeks before.
  public var baselineMinutes: Figure?
  /// Percent against the baseline; null without one.
  public var vsBaseline: Figure?
  public var status: WeekTaskStatus

  public init(
    taskKey: String, name: String, minutes: Figure, instances: Figure, medianMinutes: Figure,
    baselineMinutes: Figure?, vsBaseline: Figure?, status: WeekTaskStatus
  ) {
    self.taskKey = taskKey
    self.name = name
    self.minutes = minutes
    self.instances = instances
    self.medianMinutes = medianMinutes
    self.baselineMinutes = baselineMinutes
    self.vsBaseline = vsBaseline
    self.status = status
  }

  enum CodingKeys: String, CodingKey {
    case name, minutes, instances, status
    case taskKey = "task_key"
    case medianMinutes = "median_minutes"
    case baselineMinutes = "baseline_minutes"
    case vsBaseline = "vs_baseline"
  }
}

public struct KindHours: Codable, Equatable, Sendable {
  public var kind: String
  public var hours: Figure
  public init(kind: String, hours: Figure) {
    self.kind = kind
    self.hours = hours
  }
}

public struct AppHours: Codable, Equatable, Sendable {
  public var app: String
  public var hours: Figure
  public init(app: String, hours: Figure) {
    self.app = app
    self.hours = hours
  }
}

public struct WeekHours: Codable, Equatable, Sendable {
  public var total: Figure
  public var byKind: [KindHours]
  public var byApp: [AppHours]

  public init(total: Figure, byKind: [KindHours], byApp: [AppHours]) {
    self.total = total
    self.byKind = byKind
    self.byApp = byApp
  }

  enum CodingKeys: String, CodingKey {
    case total
    case byKind = "by_kind"
    case byApp = "by_app"
  }
}

public struct WeekFocus: Codable, Equatable, Sendable {
  public var blocks: Figure
  public var minutes: Figure
  public var switchesPerActiveHour: Figure
  public var meetingHours: Figure

  public init(blocks: Figure, minutes: Figure, switchesPerActiveHour: Figure, meetingHours: Figure) {
    self.blocks = blocks
    self.minutes = minutes
    self.switchesPerActiveHour = switchesPerActiveHour
    self.meetingHours = meetingHours
  }

  enum CodingKeys: String, CodingKey {
    case blocks, minutes
    case switchesPerActiveHour = "switches_per_active_hour"
    case meetingHours = "meeting_hours"
  }
}

/// Estimated against measured savings of shipped fixes (filled from M4).
public struct WeekFixes: Codable, Equatable, Sendable {
  public var estimated: [Figure]
  public var measured: [Figure]
  public init(estimated: [Figure], measured: [Figure]) {
    self.estimated = estimated
    self.measured = measured
  }
}

/// `GET /v1/records/weeks/{iso_week}` (404, `APIError.notFound`, for a future week).
public struct WeekRecord: Codable, Equatable, Sendable {
  public var isoWeek: String
  public var from: String
  public var to: String
  public var daysRecorded: [String]
  public var hours: WeekHours
  public var focus: WeekFocus
  public var tasks: [WeekTask]
  public var fixes: WeekFixes
  public var weeksObserved: Int
  /// The weekly sentence; null until written.
  public var narrative: String?
  public var generatedAt: String

  public init(
    isoWeek: String, from: String, to: String, daysRecorded: [String], hours: WeekHours, focus: WeekFocus,
    tasks: [WeekTask], fixes: WeekFixes, weeksObserved: Int, narrative: String?, generatedAt: String
  ) {
    self.isoWeek = isoWeek
    self.from = from
    self.to = to
    self.daysRecorded = daysRecorded
    self.hours = hours
    self.focus = focus
    self.tasks = tasks
    self.fixes = fixes
    self.weeksObserved = weeksObserved
    self.narrative = narrative
    self.generatedAt = generatedAt
  }

  enum CodingKeys: String, CodingKey {
    case from, to, hours, focus, tasks, fixes, narrative
    case isoWeek = "iso_week"
    case daysRecorded = "days_recorded"
    case weeksObserved = "weeks_observed"
    case generatedAt = "generated_at"
  }
}

// MARK: Review

/// The brain's answer enum (`ANSWERS`). The weekly review offers the first six for opportunities.
public enum ReviewAnswerKind: Equatable, Hashable, Sendable, Codable {
  case keep, notNow, build, never, leaveAlone, otherGoal
  case yes, no, confirmName, dontTrack, undo
  case unknown(String)

  /// The answers an opportunity question offers (`OPPORTUNITY_ANSWERS`), in the brain's order.
  public static let opportunityAnswers: [ReviewAnswerKind] = [.keep, .notNow, .build, .never, .leaveAlone, .otherGoal]
  /// Answers that may name a goal (`GOAL_ANSWERS`).
  public static let goalAnswers: [ReviewAnswerKind] = [.keep, .build, .otherGoal]

  public init(raw: String) {
    switch raw {
    case "keep": self = .keep
    case "not_now": self = .notNow
    case "build": self = .build
    case "never": self = .never
    case "leave_alone": self = .leaveAlone
    case "other_goal": self = .otherGoal
    case "yes": self = .yes
    case "no": self = .no
    case "confirm_name": self = .confirmName
    case "dont_track": self = .dontTrack
    case "undo": self = .undo
    default: self = .unknown(raw)
    }
  }

  public var raw: String {
    switch self {
    case .keep: return "keep"
    case .notNow: return "not_now"
    case .build: return "build"
    case .never: return "never"
    case .leaveAlone: return "leave_alone"
    case .otherGoal: return "other_goal"
    case .yes: return "yes"
    case .no: return "no"
    case .confirmName: return "confirm_name"
    case .dontTrack: return "dont_track"
    case .undo: return "undo"
    case .unknown(let raw): return raw
    }
  }

  public init(from decoder: any Decoder) throws {
    self.init(raw: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(raw)
  }
}

/// An active goal as the review lists it.
public struct ReviewGoal: Codable, Equatable, Sendable {
  public var id: String
  public var text: String
  public init(id: String, text: String) {
    self.id = id
    self.text = text
  }
}

/// One review question (v1 asks about opportunities only).
public struct ReviewQuestion: Codable, Equatable, Sendable {
  public var subjectKey: String
  public var questionKind: String
  public var name: String
  public var answers: [ReviewAnswerKind]
  public var answered: ReviewAnswerKind?

  public init(
    subjectKey: String, questionKind: String = "opportunity", name: String, answers: [ReviewAnswerKind],
    answered: ReviewAnswerKind?
  ) {
    self.subjectKey = subjectKey
    self.questionKind = questionKind
    self.name = name
    self.answers = answers
    self.answered = answered
  }

  enum CodingKeys: String, CodingKey {
    case name, answers, answered
    case subjectKey = "subject_key"
    case questionKind = "question_kind"
  }
}

/// `GET /v1/review/week?w=` (404, `APIError.notFound`, for a future week).
public struct WeekReview: Codable, Equatable, Sendable {
  public var isoWeek: String
  public var sentence: String
  /// Four tiles: hours, focus minutes, meeting hours, switches per active hour.
  public var tiles: [Figure]
  public var goals: [ReviewGoal]
  public var questions: [ReviewQuestion]

  public init(isoWeek: String, sentence: String, tiles: [Figure], goals: [ReviewGoal], questions: [ReviewQuestion]) {
    self.isoWeek = isoWeek
    self.sentence = sentence
    self.tiles = tiles
    self.goals = goals
    self.questions = questions
  }

  enum CodingKeys: String, CodingKey {
    case sentence, tiles, goals, questions
    case isoWeek = "iso_week"
  }
}

/// The `POST /v1/review/answers` body: `{ iso_week, subject_key, question_kind, answer, goal_id? }`, `goal_id`
/// left out when nil.
public struct ReviewAnswerRequest: Equatable, Sendable {
  public var isoWeek: String
  public var subjectKey: String
  public var questionKind: String
  public var answer: ReviewAnswerKind
  public var goalID: String?

  public init(isoWeek: String, subjectKey: String, answer: ReviewAnswerKind, goalID: String? = nil) {
    self.isoWeek = isoWeek
    self.subjectKey = subjectKey
    self.questionKind = "opportunity"
    self.answer = answer
    self.goalID = goalID
  }

  public var body: JSONValue {
    var o: [String: JSONValue] = [
      "iso_week": .string(isoWeek),
      "subject_key": .string(subjectKey),
      "question_kind": .string(questionKind),
      "answer": .string(answer.raw),
    ]
    if let goalID { o["goal_id"] = .string(goalID) }
    return .object(o)
  }
}

/// The stored answer the brain returns.
public struct ReviewAnswer: Codable, Equatable, Sendable {
  public var isoWeek: String
  public var subjectKey: String
  public var questionKind: String
  public var answer: ReviewAnswerKind
  public var goalID: String?
  public var answeredAt: String

  public init(
    isoWeek: String, subjectKey: String, questionKind: String = "opportunity", answer: ReviewAnswerKind,
    goalID: String?, answeredAt: String
  ) {
    self.isoWeek = isoWeek
    self.subjectKey = subjectKey
    self.questionKind = questionKind
    self.answer = answer
    self.goalID = goalID
    self.answeredAt = answeredAt
  }

  enum CodingKeys: String, CodingKey {
    case answer
    case isoWeek = "iso_week"
    case subjectKey = "subject_key"
    case questionKind = "question_kind"
    case goalID = "goal_id"
    case answeredAt = "answered_at"
  }
}
