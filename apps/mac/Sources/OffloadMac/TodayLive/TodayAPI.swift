import Foundation

// The planned Today API (API.md "Today, records and review": `GET /v1/today?date=` → `{ day_grid: { categories[],
// cells[], switch_bursts[] }, what_you_did[], repeats[] (Figure each), suggested_fix: Opportunity | null }`), read by
// Today in `.cloud` once the server has it (m5-05's API half). The item shapes below are the Mac's reading of that
// line, in the brain records' style (snake_case, every number a Figure); SPEC m3-11 "Scope changes" lists them for the
// server slice. Unknown fields are ignored and an item that does not decode is left out, never read as zero.

/// The one switch for Today's cloud data. Off until the server's `GET /v1/today` lands: in `.cloud` Today then shows a
/// labelled sample ("Sample data: Today API not live yet") and sends no request. `.local` never reads it.
public enum TodayAPI {
  public static let available = false
}

/// One kind of work in the day grid (`day_grid.categories[]`).
public struct TodayGridCategory: Codable, Equatable, Sendable {
  /// The brain's work kind (`code`, `docs`, `email`, …).
  public var key: String
  /// A display name when the server sends one; else the kind's own name is shown.
  public var name: String?
  /// The kind's minutes that day.
  public var minutes: Figure?

  public init(key: String, name: String?, minutes: Figure?) {
    self.key = key
    self.name = name
    self.minutes = minutes
  }

  enum CodingKeys: String, CodingKey {
    case key, name, minutes
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    key = try c.decode(String.self, forKey: .key)
    name = c.lenient(String.self, forKey: .name)
    minutes = c.lenient(Figure.self, forKey: .minutes)
  }
}

/// One 15-minute cell (`day_grid.cells[]`): its start ("09:15", the member's local time) and the kind that held it,
/// null when none did.
public struct TodayGridCell: Codable, Equatable, Sendable {
  public var start: String
  public var category: String?

  public init(start: String, category: String?) {
    self.start = start
    self.category = category
  }

  enum CodingKeys: String, CodingKey {
    case start, category
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    start = try c.decode(String.self, forKey: .start)
    category = c.lenient(String.self, forKey: .category)
  }
}

/// A cell with a burst of app switches (`day_grid.switch_bursts[]`).
public struct TodaySwitchBurst: Codable, Equatable, Sendable {
  public var start: String
  public var switches: Figure?

  public init(start: String, switches: Figure?) {
    self.start = start
    self.switches = switches
  }

  enum CodingKeys: String, CodingKey {
    case start, switches
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    start = try c.decode(String.self, forKey: .start)
    switches = c.lenient(Figure.self, forKey: .switches)
  }
}

/// `day_grid`. Missing lists are empty.
public struct TodayDayGridPayload: Codable, Equatable, Sendable {
  public var categories: [TodayGridCategory]
  public var cells: [TodayGridCell]
  public var switchBursts: [TodaySwitchBurst]

  public init(categories: [TodayGridCategory], cells: [TodayGridCell], switchBursts: [TodaySwitchBurst]) {
    self.categories = categories
    self.cells = cells
    self.switchBursts = switchBursts
  }

  public static let empty = TodayDayGridPayload(categories: [], cells: [], switchBursts: [])

  enum CodingKeys: String, CodingKey {
    case categories, cells
    case switchBursts = "switch_bursts"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    categories = c.lossyList(TodayGridCategory.self, forKey: .categories)
    cells = c.lossyList(TodayGridCell.self, forKey: .cells)
    switchBursts = c.lossyList(TodaySwitchBurst.self, forKey: .switchBursts)
  }
}

/// One line of "What you did" (`what_you_did[]`): a task (or a session) with its minutes.
public struct TodayDidItem: Codable, Equatable, Sendable {
  public var taskKey: String?
  public var name: String
  /// "09:00" when the server knows when it started.
  public var start: String?
  public var minutes: Figure

  public init(taskKey: String?, name: String, start: String?, minutes: Figure) {
    self.taskKey = taskKey
    self.name = name
    self.start = start
    self.minutes = minutes
  }

  enum CodingKeys: String, CodingKey {
    case name, start, minutes
    case taskKey = "task_key"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    minutes = try c.decode(Figure.self, forKey: .minutes)
    taskKey = c.lenient(String.self, forKey: .taskKey)
    start = c.lenient(String.self, forKey: .start)
  }
}

/// One thing you repeat this week (`repeats[]`), the week record's task shape.
public struct TodayRepeatItem: Codable, Equatable, Sendable {
  public var taskKey: String
  public var name: String
  public var instances: Figure
  public var minutes: Figure
  public var medianMinutes: Figure?

  public init(taskKey: String, name: String, instances: Figure, minutes: Figure, medianMinutes: Figure?) {
    self.taskKey = taskKey
    self.name = name
    self.instances = instances
    self.minutes = minutes
    self.medianMinutes = medianMinutes
  }

  enum CodingKeys: String, CodingKey {
    case name, instances, minutes
    case taskKey = "task_key"
    case medianMinutes = "median_minutes"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    taskKey = try c.decode(String.self, forKey: .taskKey)
    name = try c.decode(String.self, forKey: .name)
    instances = try c.decode(Figure.self, forKey: .instances)
    minutes = try c.decode(Figure.self, forKey: .minutes)
    medianMinutes = c.lenient(Figure.self, forKey: .medianMinutes)
  }
}

/// `GET /v1/today?date=`.
public struct TodayPayload: Codable, Equatable, Sendable {
  /// The day, when the server echoes it.
  public var date: String?
  public var dayGrid: TodayDayGridPayload
  public var whatYouDid: [TodayDidItem]
  public var repeats: [TodayRepeatItem]
  /// The one suggested fix (an open opportunity), or nil.
  public var suggestedFix: Opportunity?

  public init(date: String?, dayGrid: TodayDayGridPayload, whatYouDid: [TodayDidItem], repeats: [TodayRepeatItem],
              suggestedFix: Opportunity?) {
    self.date = date
    self.dayGrid = dayGrid
    self.whatYouDid = whatYouDid
    self.repeats = repeats
    self.suggestedFix = suggestedFix
  }

  enum CodingKeys: String, CodingKey {
    case date, repeats
    case dayGrid = "day_grid"
    case whatYouDid = "what_you_did"
    case suggestedFix = "suggested_fix"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    date = c.lenient(String.self, forKey: .date)
    dayGrid = c.lenient(TodayDayGridPayload.self, forKey: .dayGrid) ?? .empty
    whatYouDid = c.lossyList(TodayDidItem.self, forKey: .whatYouDid)
    repeats = c.lossyList(TodayRepeatItem.self, forKey: .repeats)
    suggestedFix = c.lenient(Opportunity.self, forKey: .suggestedFix)
  }
}

/// Reads Today. The opportunity routes the card answers through are m3-10's `BuildsClient`.
public protocol TodayClient: Sendable {
  /// `GET /v1/today?date={day}`, `day` as `YYYY-MM-DD`. No record of the day is `APIError.notFound`.
  func today(date: String) async throws -> TodayPayload
}

public struct HTTPTodayClient: TodayClient {
  public let core: APIClientCore

  public init(core: APIClientCore) {
    self.core = core
  }

  public func today(date: String) async throws -> TodayPayload {
    guard APIClientCore.isDay(date) else { throw APIError.refusedPath }
    return try await core.send(TodayPayload.self, .get, [.fixed("today")], query: [URLQueryItem(name: "date", value: date)])
  }

  /// The client over the brain's connection in `.cloud` (same base URL, token and transport); nil in `.local` or
  /// without the HTTP brain client, so no request can be built there.
  public static func from(_ backends: Backends) -> (any TodayClient)? {
    guard !backends.mode.isLocal, let brain = backends.brain as? HTTPBrainClient else { return nil }
    return HTTPTodayClient(core: brain.core)
  }
}
