import Foundation

// Opportunities, fixes, builds and outcomes as API.md "Opportunities, fixes and builds" and the build-loop port
// (port/build-loop: services/builder/src/http.ts `buildView`, store.ts) define them. Unknown fields are ignored;
// unknown enum values decode to `.unknown(raw)` and are never treated as success.

// MARK: Opportunities

public enum OpportunityState: Equatable, Hashable, Sendable, Codable {
  case open, chosen, needsConnection, capturingFixtures, designing, needsYou, readyForApproval, building, readyToShip
  case buildFailed, shipped, notNow, never, leftAlone
  case unknown(String)

  public init(raw: String) {
    switch raw {
    case "open": self = .open
    case "chosen": self = .chosen
    case "needs_connection": self = .needsConnection
    case "capturing_fixtures": self = .capturingFixtures
    case "designing": self = .designing
    case "needs_you": self = .needsYou
    case "ready_for_approval": self = .readyForApproval
    case "building": self = .building
    case "ready_to_ship": self = .readyToShip
    case "build_failed": self = .buildFailed
    case "shipped": self = .shipped
    case "not_now": self = .notNow
    case "never": self = .never
    case "left_alone": self = .leftAlone
    default: self = .unknown(raw)
    }
  }

  public var raw: String {
    switch self {
    case .open: return "open"
    case .chosen: return "chosen"
    case .needsConnection: return "needs_connection"
    case .capturingFixtures: return "capturing_fixtures"
    case .designing: return "designing"
    case .needsYou: return "needs_you"
    case .readyForApproval: return "ready_for_approval"
    case .building: return "building"
    case .readyToShip: return "ready_to_ship"
    case .buildFailed: return "build_failed"
    case .shipped: return "shipped"
    case .notNow: return "not_now"
    case .never: return "never"
    case .leftAlone: return "left_alone"
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

/// The answers `POST /v1/opportunities/{id}/answer` takes.
public enum OpportunityAnswer: String, Equatable, Hashable, Sendable, CaseIterable {
  case build
  case notNow = "not_now"
  case never
  case leaveAlone = "leave_alone"
}

/// One way to fix an opportunity (a `fixes` row: option 1 to 3).
public struct FixOption: Codable, Equatable, Sendable {
  /// The fix id (`GET /v1/fixes/{id}`).
  public var id: String
  public var optionNo: Int?
  public var title: String
  public var detail: String?
  public var recommended: Bool
  /// Hours per week the fix would save, when estimated.
  public var estimate: Figure?
  /// The fix kind.
  public var kind: String?

  public init(
    id: String, optionNo: Int? = nil, title: String, detail: String? = nil, recommended: Bool = false,
    estimate: Figure? = nil, kind: String? = nil
  ) {
    self.id = id
    self.optionNo = optionNo
    self.title = title
    self.detail = detail
    self.recommended = recommended
    self.estimate = estimate
    self.kind = kind
  }

  enum CodingKeys: String, CodingKey {
    case id, title, detail, recommended, estimate, kind
    case optionNo = "option_no"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    optionNo = c.lenient(Int.self, forKey: .optionNo)
    title = c.lenient(String.self, forKey: .title) ?? ""
    detail = c.lenient(String.self, forKey: .detail)
    recommended = c.lenient(Bool.self, forKey: .recommended) ?? false
    estimate = c.lenient(Figure.self, forKey: .estimate)
    kind = c.lenient(String.self, forKey: .kind)
  }
}

/// The goal an opportunity is linked to.
public struct OpportunityGoal: Codable, Equatable, Sendable {
  public var id: String
  public var text: String
  public init(id: String, text: String) {
    self.id = id
    self.text = text
  }
}

/// `GET /v1/opportunities?state=open` items and `GET /v1/opportunities/{id}`.
public struct Opportunity: Codable, Equatable, Sendable {
  public var id: String
  /// `finder`, `manual`, `instant_read` or `agent`.
  public var source: String
  public var taskKey: String?
  public var title: String
  public var description: String?
  public var isoWeek: String?
  public var rank: Int?
  public var state: OpportunityState
  /// Ranking factors by name (weekly hours saved, persistence, goal weight, ...), each a Figure. Entries that are not
  /// Figures are left out.
  public var factors: [String: Figure]
  public var options: [FixOption]
  /// Providers to connect, in `needs_connection`.
  public var missingConnections: [String]
  public var goal: OpportunityGoal?

  public init(
    id: String, source: String = "finder", taskKey: String? = nil, title: String, description: String? = nil,
    isoWeek: String? = nil, rank: Int? = nil, state: OpportunityState, factors: [String: Figure] = [:],
    options: [FixOption] = [], missingConnections: [String] = [], goal: OpportunityGoal? = nil
  ) {
    self.id = id
    self.source = source
    self.taskKey = taskKey
    self.title = title
    self.description = description
    self.isoWeek = isoWeek
    self.rank = rank
    self.state = state
    self.factors = factors
    self.options = options
    self.missingConnections = missingConnections
    self.goal = goal
  }

  enum CodingKeys: String, CodingKey {
    case id, source, title, description, rank, state, factors, options, goal
    case taskKey = "task_key"
    case isoWeek = "iso_week"
    case missingConnections = "missing_connections"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    source = c.lenient(String.self, forKey: .source) ?? "finder"
    taskKey = c.lenient(String.self, forKey: .taskKey)
    title = c.lenient(String.self, forKey: .title) ?? ""
    description = c.lenient(String.self, forKey: .description)
    isoWeek = c.lenient(String.self, forKey: .isoWeek)
    rank = c.lenient(Int.self, forKey: .rank)
    state = c.lenient(OpportunityState.self, forKey: .state) ?? .unknown("")
    var figures: [String: Figure] = [:]
    if let nested = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .factors) {
      for key in nested.allKeys {
        if let f = try? nested.decode(Figure.self, forKey: key) { figures[key.stringValue] = f }
      }
    }
    factors = figures
    options = c.lossyList(FixOption.self, forKey: .options)
    missingConnections = c.lenient([String].self, forKey: .missingConnections) ?? []
    goal = c.lenient(OpportunityGoal.self, forKey: .goal)
  }
}

// MARK: Fixes

/// `GET /v1/fixes/{id}`. `brief` is kept as it came.
public struct Fix: Codable, Equatable, Sendable {
  public var id: String
  public var brief: JSONValue
  public var briefHash: String
  public var checkSetHash: String
  public var heldOutHash: String
  public var fixtureSetHash: String
  public var estimate: Figure?
  public var capUSD: Double

  public init(
    id: String, brief: JSONValue, briefHash: String, checkSetHash: String, heldOutHash: String,
    fixtureSetHash: String, estimate: Figure?, capUSD: Double
  ) {
    self.id = id
    self.brief = brief
    self.briefHash = briefHash
    self.checkSetHash = checkSetHash
    self.heldOutHash = heldOutHash
    self.fixtureSetHash = fixtureSetHash
    self.estimate = estimate
    self.capUSD = capUSD
  }

  enum CodingKeys: String, CodingKey {
    case id, brief, estimate
    case briefHash = "brief_hash"
    case checkSetHash = "check_set_hash"
    case heldOutHash = "held_out_hash"
    case fixtureSetHash = "fixture_set_hash"
    case capUSD = "cap_usd"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    brief = c.lenient(JSONValue.self, forKey: .brief) ?? .null
    briefHash = try c.decode(String.self, forKey: .briefHash)
    checkSetHash = try c.decode(String.self, forKey: .checkSetHash)
    heldOutHash = try c.decode(String.self, forKey: .heldOutHash)
    fixtureSetHash = try c.decode(String.self, forKey: .fixtureSetHash)
    estimate = c.lenient(Figure.self, forKey: .estimate)
    capUSD = c.lenient(Double.self, forKey: .capUSD) ?? FixHashes.defaultCapUSD
  }

  /// The hashes the OK, build approval binds.
  public var hashes: FixHashes {
    FixHashes(briefHash: briefHash, checkSetHash: checkSetHash, heldOutHash: heldOutHash, fixtureSetHash: fixtureSetHash)
  }
}

/// The `POST /v1/fixes/{id}/build-approvals` body: the four hashes the person reviewed and the cap (4 USD).
public struct FixHashes: Equatable, Sendable {
  public static let defaultCapUSD: Double = 4

  public var briefHash: String
  public var checkSetHash: String
  public var heldOutHash: String
  public var fixtureSetHash: String
  public var capUSD: Double

  public init(
    briefHash: String, checkSetHash: String, heldOutHash: String, fixtureSetHash: String,
    capUSD: Double = FixHashes.defaultCapUSD
  ) {
    self.briefHash = briefHash
    self.checkSetHash = checkSetHash
    self.heldOutHash = heldOutHash
    self.fixtureSetHash = fixtureSetHash
    self.capUSD = capUSD
  }

  /// `{"brief_hash":…,"cap_usd":4,"check_set_hash":…,"fixture_set_hash":…,"held_out_hash":…}` once JCS-encoded.
  public var body: JSONValue {
    .object([
      "brief_hash": .string(briefHash),
      "check_set_hash": .string(checkSetHash),
      "held_out_hash": .string(heldOutHash),
      "fixture_set_hash": .string(fixtureSetHash),
      "cap_usd": .number(capUSD),
    ])
  }
}

/// 202 from OK, build.
public struct BuildStarted: Codable, Equatable, Sendable {
  public var buildID: String
  public init(buildID: String) { self.buildID = buildID }
  enum CodingKeys: String, CodingKey { case buildID = "build_id" }
}

// MARK: Builds

public enum BuildState: Equatable, Hashable, Sendable, Codable {
  case queued, building, verifying, fanningOut, repairing, ready, failed, capped, tampered, cancelled, infraFailed
  case unknown(String)

  public init(raw: String) {
    switch raw {
    case "queued": self = .queued
    case "building": self = .building
    case "verifying": self = .verifying
    case "fanning_out": self = .fanningOut
    case "repairing": self = .repairing
    case "ready": self = .ready
    case "failed": self = .failed
    case "capped": self = .capped
    case "tampered": self = .tampered
    case "cancelled": self = .cancelled
    case "infra_failed": self = .infraFailed
    default: self = .unknown(raw)
    }
  }

  public var raw: String {
    switch self {
    case .queued: return "queued"
    case .building: return "building"
    case .verifying: return "verifying"
    case .fanningOut: return "fanning_out"
    case .repairing: return "repairing"
    case .ready: return "ready"
    case .failed: return "failed"
    case .capped: return "capped"
    case .tampered: return "tampered"
    case .cancelled: return "cancelled"
    case .infraFailed: return "infra_failed"
    case .unknown(let raw): return raw
    }
  }

  /// Still running (the build loop's `LIVE_STATES`).
  public var isLive: Bool {
    switch self {
    case .queued, .building, .verifying, .fanningOut, .repairing: return true
    default: return false
    }
  }

  /// Only `ready` is a success; an unknown state never is.
  public var isReady: Bool { self == .ready }

  public init(from decoder: any Decoder) throws {
    self.init(raw: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(raw)
  }
}

public enum BuildStageState: Equatable, Hashable, Sendable, Codable {
  case running, done, failed
  case unknown(String)

  public init(raw: String) {
    switch raw {
    case "running": self = .running
    case "done": self = .done
    case "failed": self = .failed
    default: self = .unknown(raw)
    }
  }

  public var raw: String {
    switch self {
    case .running: return "running"
    case .done: return "done"
    case .failed: return "failed"
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

public enum AttemptOutcome: Equatable, Hashable, Sendable, Codable {
  case running, pass, fail, cap, tamper, error
  case unknown(String)

  public init(raw: String) {
    switch raw {
    case "running": self = .running
    case "pass": self = .pass
    case "fail": self = .fail
    case "cap": self = .cap
    case "tamper": self = .tamper
    case "error": self = .error
    default: self = .unknown(raw)
    }
  }

  public var raw: String {
    switch self {
    case .running: return "running"
    case .pass: return "pass"
    case .fail: return "fail"
    case .cap: return "cap"
    case .tamper: return "tamper"
    case .error: return "error"
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

public enum CheckGroupName: Equatable, Hashable, Sendable, Codable {
  case frozen, heldOut
  case unknown(String)

  public init(raw: String) {
    switch raw {
    case "frozen": self = .frozen
    case "held_out": self = .heldOut
    default: self = .unknown(raw)
    }
  }

  public var raw: String {
    switch self {
    case .frozen: return "frozen"
    case .heldOut: return "held_out"
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

public struct BuildStage: Codable, Equatable, Sendable {
  public var name: String
  public var state: BuildStageState
  public var startedAt: String?
  public var endedAt: String?
  /// Fixed plain words chosen by the build loop.
  public var note: String?

  public init(name: String, state: BuildStageState, startedAt: String?, endedAt: String?, note: String?) {
    self.name = name
    self.state = state
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.note = note
  }

  enum CodingKeys: String, CodingKey {
    case name, state, note
    case startedAt = "started_at"
    case endedAt = "ended_at"
  }
}

public struct CheckGroup: Codable, Equatable, Sendable {
  public var name: CheckGroupName
  public var passed: Int
  public var failed: Int
  public init(name: CheckGroupName, passed: Int, failed: Int) {
    self.name = name
    self.passed = passed
    self.failed = failed
  }
}

public struct BuildAttempt: Codable, Equatable, Sendable {
  public var id: String
  public var ordinal: Int
  public var outcome: AttemptOutcome
  public var spentUSD: Double
  public var tries: Int
  public var turns: Int
  public var frozenPass: Bool?
  public var heldOutPass: Bool?
  public var checkGroups: [CheckGroup]
  public var artifactSHA256: String?
  public var artifactBytes: Int
  public var artifactFiles: [String]
  public var note: String?

  public init(
    id: String, ordinal: Int, outcome: AttemptOutcome, spentUSD: Double, tries: Int, turns: Int, frozenPass: Bool?,
    heldOutPass: Bool?, checkGroups: [CheckGroup], artifactSHA256: String?, artifactBytes: Int,
    artifactFiles: [String], note: String?
  ) {
    self.id = id
    self.ordinal = ordinal
    self.outcome = outcome
    self.spentUSD = spentUSD
    self.tries = tries
    self.turns = turns
    self.frozenPass = frozenPass
    self.heldOutPass = heldOutPass
    self.checkGroups = checkGroups
    self.artifactSHA256 = artifactSHA256
    self.artifactBytes = artifactBytes
    self.artifactFiles = artifactFiles
    self.note = note
  }

  enum CodingKeys: String, CodingKey {
    case id, ordinal, outcome, tries, turns, note
    case spentUSD = "spent_usd"
    case frozenPass = "frozen_pass"
    case heldOutPass = "held_out_pass"
    case checkGroups = "check_groups"
    case artifactSHA256 = "artifact_sha256"
    case artifactBytes = "artifact_bytes"
    case artifactFiles = "artifact_files"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    ordinal = c.lenient(Int.self, forKey: .ordinal) ?? 0
    outcome = c.lenient(AttemptOutcome.self, forKey: .outcome) ?? .unknown("")
    spentUSD = c.lenient(Double.self, forKey: .spentUSD) ?? 0
    tries = c.lenient(Int.self, forKey: .tries) ?? 0
    turns = c.lenient(Int.self, forKey: .turns) ?? 0
    frozenPass = c.lenient(Bool.self, forKey: .frozenPass)
    heldOutPass = c.lenient(Bool.self, forKey: .heldOutPass)
    checkGroups = c.lossyList(CheckGroup.self, forKey: .checkGroups)
    artifactSHA256 = c.lenient(String.self, forKey: .artifactSHA256)
    artifactBytes = c.lenient(Int.self, forKey: .artifactBytes) ?? 0
    artifactFiles = c.lenient([String].self, forKey: .artifactFiles) ?? []
    note = c.lenient(String.self, forKey: .note)
  }
}

/// `GET /v1/builds/{id}` and `POST /v1/builds/{id}/cancel`: the build loop's `buildView`.
public struct Build: Codable, Equatable, Sendable {
  public var id: String
  public var state: BuildState
  public var capUSD: Double
  public var spentUSD: Double
  public var fanoutWorkers: Int
  public var stages: [BuildStage]
  public var attempts: [BuildAttempt]
  public var winnerAttemptID: String?
  public var artifactSHA256: String?
  public var receiptHash: String?
  public var definitionHash: String?
  public var deployed: Bool
  public var startedAt: String?
  public var endedAt: String?

  public init(
    id: String, state: BuildState, capUSD: Double, spentUSD: Double, fanoutWorkers: Int, stages: [BuildStage],
    attempts: [BuildAttempt], winnerAttemptID: String?, artifactSHA256: String?, receiptHash: String?,
    definitionHash: String?, deployed: Bool, startedAt: String?, endedAt: String?
  ) {
    self.id = id
    self.state = state
    self.capUSD = capUSD
    self.spentUSD = spentUSD
    self.fanoutWorkers = fanoutWorkers
    self.stages = stages
    self.attempts = attempts
    self.winnerAttemptID = winnerAttemptID
    self.artifactSHA256 = artifactSHA256
    self.receiptHash = receiptHash
    self.definitionHash = definitionHash
    self.deployed = deployed
    self.startedAt = startedAt
    self.endedAt = endedAt
  }

  enum CodingKeys: String, CodingKey {
    case id, state, stages, attempts, deployed
    case capUSD = "cap_usd"
    case spentUSD = "spent_usd"
    case fanoutWorkers = "fanout_workers"
    case winnerAttemptID = "winner_attempt_id"
    case artifactSHA256 = "artifact_sha256"
    case receiptHash = "receipt_hash"
    case definitionHash = "definition_hash"
    case startedAt = "started_at"
    case endedAt = "ended_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    state = c.lenient(BuildState.self, forKey: .state) ?? .unknown("")
    capUSD = c.lenient(Double.self, forKey: .capUSD) ?? FixHashes.defaultCapUSD
    spentUSD = c.lenient(Double.self, forKey: .spentUSD) ?? 0
    fanoutWorkers = c.lenient(Int.self, forKey: .fanoutWorkers) ?? 0
    stages = c.lossyList(BuildStage.self, forKey: .stages)
    attempts = c.lossyList(BuildAttempt.self, forKey: .attempts)
    winnerAttemptID = c.lenient(String.self, forKey: .winnerAttemptID)
    artifactSHA256 = c.lenient(String.self, forKey: .artifactSHA256)
    receiptHash = c.lenient(String.self, forKey: .receiptHash)
    definitionHash = c.lenient(String.self, forKey: .definitionHash)
    deployed = c.lenient(Bool.self, forKey: .deployed) ?? false
    startedAt = c.lenient(String.self, forKey: .startedAt)
    endedAt = c.lenient(String.self, forKey: .endedAt)
  }

  /// The hashes a deploy approval binds, when the build has all three.
  public var deployHashes: DeployHashes? {
    guard let artifactSHA256, let receiptHash, let definitionHash else { return nil }
    return DeployHashes(artifactSHA256: artifactSHA256, receiptHash: receiptHash, definitionHash: definitionHash)
  }
}

/// `GET /v1/builds/{id}/definition`: the routine definition as it came, its hash, and the words shown before deploy.
public struct BuildDefinition: Codable, Equatable, Sendable {
  public var definition: JSONValue
  public var definitionHash: String
  public var words: [String]

  public init(definition: JSONValue, definitionHash: String, words: [String]) {
    self.definition = definition
    self.definitionHash = definitionHash
    self.words = words
  }

  enum CodingKeys: String, CodingKey {
    case definition, words
    case definitionHash = "definition_hash"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    definition = c.lenient(JSONValue.self, forKey: .definition) ?? .null
    definitionHash = try c.decode(String.self, forKey: .definitionHash)
    words = c.lenient([String].self, forKey: .words) ?? []
  }
}

/// The `POST /v1/builds/{id}/deploy` body: exactly these three hashes.
public struct DeployHashes: Equatable, Sendable {
  public var artifactSHA256: String
  public var receiptHash: String
  public var definitionHash: String

  public init(artifactSHA256: String, receiptHash: String, definitionHash: String) {
    self.artifactSHA256 = artifactSHA256
    self.receiptHash = receiptHash
    self.definitionHash = definitionHash
  }

  public var body: JSONValue {
    .object([
      "artifact_sha256": .string(artifactSHA256),
      "receipt_hash": .string(receiptHash),
      "definition_hash": .string(definitionHash),
    ])
  }
}

/// 201 from deploy.
public struct Deployed: Codable, Equatable, Sendable {
  public var routineID: String
  public var version: Int
  public init(routineID: String, version: Int) {
    self.routineID = routineID
    self.version = version
  }
  enum CodingKeys: String, CodingKey {
    case version
    case routineID = "routine_id"
  }
}

// MARK: Outcomes

public enum OutcomeFlag: Equatable, Hashable, Sendable, Codable {
  case pending, onTrack, partial, under, unmeasured
  case unknown(String)

  public init(raw: String) {
    switch raw {
    case "pending": self = .pending
    case "on_track": self = .onTrack
    case "partial": self = .partial
    case "under": self = .under
    case "unmeasured": self = .unmeasured
    default: self = .unknown(raw)
    }
  }

  public var raw: String {
    switch self {
    case .pending: return "pending"
    case .onTrack: return "on_track"
    case .partial: return "partial"
    case .under: return "under"
    case .unmeasured: return "unmeasured"
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

/// `GET /v1/outcomes?month=` items (DATA_MODEL `fix_outcomes`). Numbers may come plain or as Figures; `weeks` (4
/// weeks: measured minutes or `source_purged`) is kept as it came.
public struct FixOutcome: Codable, Equatable, Sendable {
  public var routineID: String
  public var shippedAt: String?
  public var estimatedMinutesPerWeek: NumberOrFigure?
  public var baselineMinutesPerWeek: NumberOrFigure?
  public var weeks: [JSONValue]
  public var flag: OutcomeFlag
  public var ratio: NumberOrFigure?
  public var arithmetic: String?

  public init(
    routineID: String, shippedAt: String?, estimatedMinutesPerWeek: NumberOrFigure?,
    baselineMinutesPerWeek: NumberOrFigure?, weeks: [JSONValue], flag: OutcomeFlag, ratio: NumberOrFigure?,
    arithmetic: String?
  ) {
    self.routineID = routineID
    self.shippedAt = shippedAt
    self.estimatedMinutesPerWeek = estimatedMinutesPerWeek
    self.baselineMinutesPerWeek = baselineMinutesPerWeek
    self.weeks = weeks
    self.flag = flag
    self.ratio = ratio
    self.arithmetic = arithmetic
  }

  enum CodingKeys: String, CodingKey {
    case weeks, flag, ratio, arithmetic
    case routineID = "routine_id"
    case shippedAt = "shipped_at"
    case estimatedMinutesPerWeek = "estimated_minutes_per_week"
    case baselineMinutesPerWeek = "baseline_minutes_per_week"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    routineID = try c.decode(String.self, forKey: .routineID)
    shippedAt = c.lenient(String.self, forKey: .shippedAt)
    estimatedMinutesPerWeek = c.lenient(NumberOrFigure.self, forKey: .estimatedMinutesPerWeek)
    baselineMinutesPerWeek = c.lenient(NumberOrFigure.self, forKey: .baselineMinutesPerWeek)
    weeks = c.lenient([JSONValue].self, forKey: .weeks) ?? []
    flag = c.lenient(OutcomeFlag.self, forKey: .flag) ?? .unknown("")
    ratio = c.lenient(NumberOrFigure.self, forKey: .ratio)
    arithmetic = c.lenient(String.self, forKey: .arithmetic)
  }
}
