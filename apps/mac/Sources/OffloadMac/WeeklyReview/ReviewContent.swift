import Foundation

// What the weekly review screen shows, as plain values (SPEC m3-12 Contract): built by `ReviewContent.local` from
// m3-10's local insights or by `ReviewContent.cloud` from the brain's WeekReview. Every number shown is a Figure's
// value (ADR 0003); `figures` lists them so each can open to its arithmetic.

public enum ReviewTone: String, Equatable, Sendable {
  case good
  case needsYou
  /// Nothing to compare: a first week, Saved by fixes, every cloud tile.
  case neutral
}

public struct ReviewTile: Equatable, Sendable, Identifiable {
  public enum Kind: String, Equatable, Sendable {
    case active, deepWork, switches, savedByFixes, cloud
  }

  public var kind: Kind
  public var label: String
  /// Nil for Saved by fixes on the Mac (no fix runs here).
  public var value: Figure?
  public var valueText: String
  /// "−2% vs your usual", "down 3 weeks running", "first week"; nil when there is nothing to say.
  public var deltaLine: String?
  /// The median of up to 8 earlier weeks with data.
  public var usual: Figure?
  /// Percent against the usual, a whole number.
  public var delta: Figure?
  /// Changes in a row the same way (3 or more), when the line shows it.
  public var run: Figure?
  public var tone: ReviewTone

  public init(kind: Kind, label: String, value: Figure?, valueText: String, deltaLine: String? = nil, usual: Figure? = nil,
              delta: Figure? = nil, run: Figure? = nil, tone: ReviewTone = .neutral) {
    self.kind = kind
    self.label = label
    self.value = value
    self.valueText = valueText
    self.deltaLine = deltaLine
    self.usual = usual
    self.delta = delta
    self.run = run
    self.tone = tone
  }

  public var id: String { label }
  public var figures: [Figure] { [value, usual, delta, run].compactMap { $0 } }

  /// The SPEC's tone rules. `percent` is against your usual (nil when there is none); `run` is signed (+3 three rises,
  /// −3 three falls, 0 none). Deep work up is good; Switches / hour up needs you; Active within 10% of usual is good.
  public static func tone(for kind: Kind, percent: Int?, run: Int) -> ReviewTone {
    switch kind {
    case .savedByFixes, .cloud:
      return .neutral
    case .active:
      guard let p = percent else { return .neutral }
      return abs(p) <= 10 ? .good : .needsYou
    case .deepWork, .switches:
      guard percent != nil || run != 0 else { return .neutral }
      let way = run != 0 ? run : (percent ?? 0)
      if kind == .deepWork { return way < 0 ? .needsYou : .good }
      return way > 0 ? .needsYou : .good
    }
  }
}

public struct GoalRow: Equatable, Sendable, Identifiable {
  public var id: String
  public var text: String
  /// Hours this week of the repeats linked to the goal; nil while none is linked (and in the cloud).
  public var hours: Figure?
  /// "14.2 h", "not linked yet"; nil in the cloud (the brain sends goal text only).
  public var hoursText: String?
  public var linked: Bool
  /// Changes in a row the same way (2 or more).
  public var trend: Figure?
  /// ["↑ 4 weeks"] or ["↓ 3 weeks", "drifting"], separate items.
  public var trendItems: [String]
  public var tone: ReviewTone

  public init(id: String, text: String, hours: Figure? = nil, hoursText: String? = nil, linked: Bool = false,
              trend: Figure? = nil, trendItems: [String] = [], tone: ReviewTone = .neutral) {
    self.id = id
    self.text = text
    self.hours = hours
    self.hoursText = hoursText
    self.linked = linked
    self.trend = trend
    self.trendItems = trendItems
    self.tone = tone
  }

  public var figures: [Figure] { [hours, trend].compactMap { $0 } }
}

/// One tap answer.
public struct ReviewChip: Equatable, Sendable, Identifiable {
  public var label: String
  public var answer: ReviewAnswerKind
  /// The goal the answer names (Yes names the asked goal).
  public var goalID: String?
  /// "It's for another goal": the goals to pick from.
  public var goalChoices: [ReviewGoal]

  public init(label: String, answer: ReviewAnswerKind, goalID: String? = nil, goalChoices: [ReviewGoal] = []) {
    self.label = label
    self.answer = answer
    self.goalID = goalID
    self.goalChoices = goalChoices
  }

  public var id: String { answer.raw + "|" + (goalID ?? "") }
  public var needsGoal: Bool { answer == .otherGoal && goalID == nil }
}

/// One review question. Named `WeekQuestion` because `ReviewQuestion` is the brain's wire shape (m3-10).
public struct WeekQuestion: Equatable, Sendable, Identifiable {
  public enum Kind: String, Equatable, Sendable {
    /// "Is <repeat> part of <goal>?"
    case goal
    /// "Build something for <repeat> next?"
    case build
    /// The brain's question: one chip per answer it lists.
    case cloud
  }

  public var subjectKey: String
  public var questionKind: String
  public var kind: Kind
  public var name: String
  public var text: String
  public var whyLine: String?
  /// The figures behind the why line: minutes per week, weeks present, weeks observed.
  public var why: [Figure]
  public var chips: [ReviewChip]
  public var answered: ReviewAnswerKind?
  public var answeredGoalID: String?
  /// The repeat's minutes per week (0 in the cloud), kept with a local answer.
  public var minutesPerWeek: Int

  public init(subjectKey: String, questionKind: String = "opportunity", kind: Kind, name: String, text: String,
              whyLine: String? = nil, why: [Figure] = [], chips: [ReviewChip], answered: ReviewAnswerKind? = nil,
              answeredGoalID: String? = nil, minutesPerWeek: Int = 0) {
    self.subjectKey = subjectKey
    self.questionKind = questionKind
    self.kind = kind
    self.name = name
    self.text = text
    self.whyLine = whyLine
    self.why = why
    self.chips = chips
    self.answered = answered
    self.answeredGoalID = answeredGoalID
    self.minutesPerWeek = minutesPerWeek
  }

  public var id: String { subjectKey }
  public var isAnswered: Bool { answered != nil }

  /// The line after an answer: OK, build is queued; Never stays away unless the hours rise by half.
  public var noteItems: [String] {
    switch answered {
    case .build?: return ReviewCopy.buildNoteItems
    case .never?: return [ReviewCopy.neverNote]
    default: return []
    }
  }

  /// The chip that shows as chosen: the answer, and for Yes or No the goal it named.
  public func isOn(_ chip: ReviewChip) -> Bool {
    guard let a = answered, chip.answer == a else { return false }
    if a == .keep { return chip.goalID == answeredGoalID }
    return true
  }
}

public struct ReviewContent: Equatable, Sendable {
  public var week: ISOWeek
  public var titleItems: [String]
  public var sentence: String
  /// The figures the sentence was filled from (beyond the tiles').
  public var sentenceFigures: [Figure]
  public var subtitleItems: [String]
  /// Weeks from the first week with data to this one ("week 8 of what Offload knows about you").
  public var weeksKnown: Figure?
  public var tiles: [ReviewTile]
  public var goals: [GoalRow]
  /// At most 4.
  public var questions: [WeekQuestion]
  public var provenance: DataProvenance
  /// Names shown as given (repeats and goals): they may hold digits that are not numbers of the review.
  public var names: [String]

  public init(week: ISOWeek, titleItems: [String], sentence: String, sentenceFigures: [Figure], subtitleItems: [String],
              weeksKnown: Figure?, tiles: [ReviewTile], goals: [GoalRow], questions: [WeekQuestion],
              provenance: DataProvenance, names: [String]) {
    self.week = week
    self.titleItems = titleItems
    self.sentence = sentence
    self.sentenceFigures = sentenceFigures
    self.subtitleItems = subtitleItems
    self.weeksKnown = weeksKnown
    self.tiles = tiles
    self.goals = goals
    self.questions = questions
    self.provenance = provenance
    self.names = names
  }

  public static let maxQuestions = 4

  /// "Week of Nov 9 · review".
  public var title: String { titleItems.joined(separator: " \u{00B7} ") }
  public var answeredCount: Int { questions.filter(\.isAnswered).count }
  public var counterItems: [String] { ReviewCopy.counterItems(answered: answeredCount, total: questions.count) }

  /// Every figure behind a number on the screen.
  public var figures: [Figure] {
    sentenceFigures + [weeksKnown].compactMap { $0 } + tiles.flatMap(\.figures) + goals.flatMap(\.figures)
      + questions.flatMap(\.why)
  }
}

/// How a figure's value is written on the screen.
enum ReviewFormat {
  /// "2.7", "2", "5.21": the value as a figure holds it.
  static func number(_ v: Double) -> String { FigureCanon.number(v) }

  /// "2.7 h", "71 min", "10.9".
  static func value(_ f: Figure) -> String {
    switch f.unit {
    case "hours": return number(f.value) + " h"
    case "minutes": return number(f.value) + " min"
    case "minutes_per_week": return number(f.value) + " min/week"
    default: return number(f.value)
    }
  }
}

/// The weekly review's sentence: a closed set of templates filled only with numbers from Figures and names as given.
public enum ReviewSentence: Equatable, Sendable {
  case grew(name: String, weeks: Figure)
  case firstWeek(hours: Figure)
  case aboutUsual(hours: Figure)
  case more(hours: Figure, percent: Figure)
  case less(hours: Figure, percent: Figure)

  public static let fallback = ReviewCopy.sentenceFallback

  public var text: String {
    switch self {
    case .grew(let name, let weeks): return ReviewCopy.grew(name, weeks: ReviewFormat.number(abs(weeks.value)))
    case .firstWeek(let h): return ReviewCopy.firstWeekSentence(hours: ReviewFormat.number(h.value))
    case .aboutUsual(let h): return ReviewCopy.aboutUsual(hours: ReviewFormat.number(h.value))
    case .more(let h, let p):
      return ReviewCopy.moreThanUsual(hours: ReviewFormat.number(h.value), percent: ReviewFormat.number(abs(p.value)))
    case .less(let h, let p):
      return ReviewCopy.lessThanUsual(hours: ReviewFormat.number(h.value), percent: ReviewFormat.number(abs(p.value)))
    }
  }

  public var figures: [Figure] {
    switch self {
    case .grew(_, let w): return [w]
    case .firstWeek(let h), .aboutUsual(let h): return [h]
    case .more(let h, let p), .less(let h, let p): return [h, p]
    }
  }

  /// The numbers written in `s` ("41.2", "3"), signs left out.
  public static func numbers(in s: String) -> [String] {
    guard let regex = try? Regex("[0-9]+(?:\\.[0-9]+)?") else { return [] }
    return s.matches(of: regex).map { String(s[$0.range]) }
  }

  /// The ways a figure's value may be written: as the figure holds it, with one decimal, without its sign.
  public static func spellings(_ v: Double) -> Set<String> {
    let a = abs(v)
    return [FigureCanon.number(a), AnalysisCopy.decimal(a)]
  }

  /// True when every number in `sentence`, once the given names are taken out, is the value of one of `figures`
  /// (ROADMAP M5's narrative rule, done on the Mac).
  public static func check(_ sentence: String, figures: [Figure], names: [String] = []) -> Bool {
    var s = sentence
    for n in names.sorted(by: { $0.count > $1.count }) where !n.isEmpty {
      s = s.replacingOccurrences(of: n, with: " ")
    }
    let allowed = Set(figures.flatMap { spellings($0.value) })
    return numbers(in: s).allSatisfy { allowed.contains($0) }
  }

  /// The sentence's text when it passes the check, else the fallback.
  public func checked(names: [String]) -> String {
    Self.check(text, figures: figures, names: names) ? text : Self.fallback
  }
}
