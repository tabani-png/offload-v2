import Foundation

// The weekly review answers kept on this Mac (m3-12 writes them through LocalAnswerStore) and what they do to local
// ranking: ARCHITECTURE section 6's goal weight and decline penalty, done in code. Latest answer per
// (iso_week, subject_key) wins, as DATA_MODEL `review_answers`.

/// The brain's opportunity answers (services/brain review/answers.ts `OPPORTUNITY_ANSWERS`).
public enum LocalAnswer: String, Codable, CaseIterable, Sendable {
  case keep
  case notNow = "not_now"
  case build
  case never
  case leaveAlone = "leave_alone"
  case otherGoal = "other_goal"

  /// Answers that may name a goal.
  public var canLinkGoal: Bool { self == .keep || self == .build || self == .otherGoal }
}

public struct LocalReviewAnswer: Codable, Equatable, Sendable {
  public var isoWeek: String
  /// The repeat's `k_` key.
  public var subjectKey: String
  public var questionKind: String
  public var answer: LocalAnswer
  public var goalID: String?
  public var answeredAt: Date
  /// The repeat's minutes per week when it was answered (a declined repeat returns when this rises by half).
  public var minutesPerWeek: Int

  public init(isoWeek: String, subjectKey: String, answer: LocalAnswer, goalID: String? = nil, answeredAt: Date,
              minutesPerWeek: Int, questionKind: String = "opportunity") {
    self.isoWeek = isoWeek
    self.subjectKey = subjectKey
    self.questionKind = questionKind
    self.answer = answer
    self.goalID = goalID
    self.answeredAt = answeredAt
    self.minutesPerWeek = minutesPerWeek
  }

  enum CodingKeys: String, CodingKey {
    case isoWeek = "iso_week"
    case subjectKey = "subject_key"
    case questionKind = "question_kind"
    case answer
    case goalID = "goal_id"
    case answeredAt = "answered_at"
    case minutesPerWeek = "minutes_per_week"
  }
}

public protocol LocalAnswerStore: Sendable {
  /// The latest answer per (iso_week, subject_key).
  func answers() -> [LocalReviewAnswer]
  func record(_ answer: LocalReviewAnswer) throws
}

enum LocalAnswers {
  /// Latest wins per (iso_week, subject_key); a tie keeps the later one recorded. Sorted by week, then subject.
  static func latest(_ all: [LocalReviewAnswer]) -> [LocalReviewAnswer] {
    var out: [String: LocalReviewAnswer] = [:]
    for a in all {
      let k = a.isoWeek + "|" + a.subjectKey
      if let cur = out[k], a.answeredAt < cur.answeredAt { continue }
      out[k] = a
    }
    return out.values.sorted { $0.isoWeek != $1.isoWeek ? $0.isoWeek < $1.isoWeek : $0.subjectKey < $1.subjectKey }
  }
}

public final class MemoryLocalAnswerStore: LocalAnswerStore, @unchecked Sendable {
  private let lock = NSLock()
  private var all: [LocalReviewAnswer]

  public init(_ answers: [LocalReviewAnswer] = []) { all = answers }

  public func answers() -> [LocalReviewAnswer] {
    lock.lock()
    defer { lock.unlock() }
    return LocalAnswers.latest(all)
  }

  public func record(_ answer: LocalReviewAnswer) throws {
    lock.lock()
    defer { lock.unlock() }
    all.append(answer)
  }
}

public struct LocalAnswerWriteError: Error, Equatable {
  public let step: String
}

/// `Application Support/Offload/OnDevice/answers.json`: one JSON file, 0600 in a 0700 folder, replaced atomically.
public final class FileLocalAnswerStore: LocalAnswerStore, @unchecked Sendable {
  struct File: Codable {
    var schemaVersion = 1
    var answers: [LocalReviewAnswer] = []
  }

  public let file: URL
  private let lock = NSLock()
  private var state: File

  public init(file: URL) {
    self.file = file
    if let data = try? Data(contentsOf: file), let f = try? Self.decoder.decode(File.self, from: data), f.schemaVersion == 1 {
      state = f
    } else {
      state = File()
    }
  }

  public func answers() -> [LocalReviewAnswer] {
    lock.lock()
    defer { lock.unlock() }
    return LocalAnswers.latest(state.answers)
  }

  public func record(_ answer: LocalReviewAnswer) throws {
    lock.lock()
    defer { lock.unlock() }
    var next = state
    // Only the latest per week and subject is kept.
    next.answers = LocalAnswers.latest(next.answers + [answer])
    try OnDeviceFiles.writeAtomically(try Self.encoder.encode(next), to: file)
    state = next
  }

  static var decoder: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .millisecondsSince1970
    return d
  }

  static var encoder: JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    e.dateEncodingStrategy = .millisecondsSince1970
    return e
  }
}

/// What the answers do to ranking, per subject key: the latest answer of any week.
public struct RankingAdjustments: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public var answer: LocalAnswer
    public var goalID: String?
    public var answeredAt: Date
    public var minutesPerWeek: Int
  }

  public static let none = RankingAdjustments(entries: [:])
  /// `not_now` hides a repeat for this long.
  public static let notNowFor: TimeInterval = 28 * 24 * 3600

  public var entries: [String: Entry]

  public init(entries: [String: Entry]) { self.entries = entries }

  public init(answers: [LocalReviewAnswer]) {
    var out: [String: Entry] = [:]
    for a in answers {
      if let cur = out[a.subjectKey], a.answeredAt < cur.answeredAt { continue }
      out[a.subjectKey] = Entry(answer: a.answer, goalID: a.goalID, answeredAt: a.answeredAt, minutesPerWeek: a.minutesPerWeek)
    }
    entries = out
  }

  public init(store: any LocalAnswerStore) { self.init(answers: store.answers()) }

  /// 1.5 when the latest answer linked the repeat to one of the person's goals (`keep`, `build` or `other_goal`
  /// with a goal id), else 1. With no goals given, any linked goal counts.
  public func goalWeight(key: String, goals: [String]) -> Double {
    guard let e = entries[key], e.answer.canLinkGoal, let goal = e.goalID else { return 1 }
    return goals.isEmpty || goals.contains(goal) ? 1.5 : 1
  }

  /// 0 after `never` or `leave_alone`, or `not_now` within 4 weeks, unless the minutes per week rose by half or more
  /// over the value at the answer; else 1.
  public func declinePenalty(key: String, minutesPerWeek: Int, now: Date) -> Double {
    guard let e = entries[key] else { return 1 }
    let declined: Bool
    switch e.answer {
    case .never, .leaveAlone: declined = true
    case .notNow: declined = now.timeIntervalSince(e.answeredAt) < Self.notNowFor
    case .keep, .build, .otherGoal: declined = false
    }
    guard declined else { return 1 }
    let rose = e.minutesPerWeek > 0 ? 2 * minutesPerWeek >= 3 * e.minutesPerWeek : minutesPerWeek > 0
    return rose ? 1 : 0
  }
}
