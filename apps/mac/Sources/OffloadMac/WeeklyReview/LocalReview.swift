import Foundation

// The weekly review counted on this Mac (SPEC m3-12 ".local content"): tiles against your usual week, one sentence from
// a closed set, goals with the hours of the repeats linked to them, and up to 4 questions. Pure: the same snapshot and
// answers give the same content. No model is involved; every number is a Figure.

extension ReviewContent {
  /// The review of `week` from a snapshot of local insights, its weeks computed from the snapshot's days.
  public static func local(snapshot: InsightsSnapshot, week: ISOWeek, goals: [String],
                           answers: [LocalReviewAnswer]) -> ReviewContent? {
    local(snapshot: snapshot, week: week, history: WeekStats.weeks(snapshot.days, timeZone: week.timeZone), goals: goals,
          answers: answers)
  }

  /// The review of `week`; nil when nothing was counted in it. `history` holds the weeks with data, oldest first.
  public static func local(snapshot: InsightsSnapshot, week: ISOWeek, history: [WeekStats], goals: [String],
                           answers: [LocalReviewAnswer]) -> ReviewContent? {
    guard let this = history.first(where: { $0.week.id == week.id }), this.hasData else { return nil }
    let earlier = history.filter { $0.week < week && $0.hasData }
    let usualWeeks = Array(earlier.suffix(LocalReview.usualWeeks))
    let chain = WeekStats.chain(history, endingAt: week)

    let active = LocalReview.tile(.active, label: ReviewCopy.activeLabel, unit: "hours", suffix: " h", this: this,
                                  usualWeeks: usualWeeks, chain: chain, value: { $0.activeHours },
                                  arithmetic: LocalReview.activeArithmetic, evidence: { $0.activeEvidence })
    let deep = LocalReview.tile(.deepWork, label: ReviewCopy.deepWorkLabel, unit: "hours", suffix: " h", this: this,
                                usualWeeks: usualWeeks, chain: chain, value: { $0.focusHours },
                                arithmetic: LocalReview.focusArithmetic, evidence: { $0.focusEvidence })
    let switches = LocalReview.tile(.switches, label: ReviewCopy.switchesLabel, unit: "per_hour", suffix: "", this: this,
                                    usualWeeks: usualWeeks, chain: chain, value: { $0.switchesPerHour },
                                    arithmetic: LocalReview.switchesArithmetic, evidence: { $0.switchEvidence })
    let saved = ReviewTile(kind: .savedByFixes, label: ReviewCopy.savedLabel, value: nil, valueText: ReviewCopy.noFixesYet)

    let cleanGoals = Goals.clean(goals)
    let names = snapshot.repeats.map(\.name) + cleanGoals
    let sentence = LocalReview.sentence(snapshot: snapshot, chain: chain, isFirstWeek: earlier.isEmpty, active: active)

    var weeksKnown: Figure?
    var subtitle = [ReviewCopy.everyNumberOpens]
    if let first = history.first(where: \.hasData) {
      let n = LocalReview.weeks(from: first.week, to: week)
      let figure = Figure.local(Double(n), unit: "weeks",
                                arithmetic: "\(first.week.id) to \(week.id): \(n) \(n == 1 ? "week" : "weeks")", evidence: [])
      weeksKnown = figure
      subtitle.insert(ReviewCopy.weeksKnownItem(n), at: 0)
    }

    return ReviewContent(
      week: week, titleItems: ReviewCopy.titleItems(week), sentence: sentence.checked(names: names),
      sentenceFigures: sentence.figures, subtitleItems: subtitle, weeksKnown: weeksKnown,
      tiles: [active, deep, switches, saved],
      goals: LocalReview.goals(cleanGoals, snapshot: snapshot, week: week, chain: chain, answers: answers),
      questions: LocalReview.questions(snapshot: snapshot, week: week, goals: cleanGoals, answers: answers),
      provenance: .onDevice, names: names
    )
  }
}

enum LocalReview {
  /// Your usual is the median of up to this many earlier weeks with data.
  static let usualWeeks = 8
  /// A tile reads "down 3 weeks running" from this many changes in a row.
  static let tileRun = 3
  /// A goal shows its trend from this many changes in a row.
  static let goalRun = 2
  /// "about your usual" within this many percent.
  static let aboutPercent = 5

  // MARK: Tiles

  static func tile(_ kind: ReviewTile.Kind, label: String, unit: String, suffix: String, this: WeekStats,
                   usualWeeks: [WeekStats], chain: [WeekStats], value: (WeekStats) -> Double,
                   arithmetic: (WeekStats) -> String, evidence: (WeekStats) -> [EvidenceRef]) -> ReviewTile {
    let v = value(this)
    let figure = Figure.local(v, unit: unit, arithmetic: arithmetic(this), evidence: evidence(this))
    let n = ReviewFormat.number
    var usual: Figure?
    var delta: Figure?
    var percent: Int?
    var line: String
    if let u = WeekStats.median(usualWeeks.map(value)) {
      let values = usualWeeks.map(value).sorted().map { n($0) + suffix }.joined(separator: ", ")
      usual = Figure.local(u, unit: unit,
                           arithmetic: "median of \(usualWeeks.count) earlier \(usualWeeks.count == 1 ? "week" : "weeks") (\(values)) = \(n(u))\(suffix)",
                           evidence: [])
      if u > 0 {
        let p = Int(((v - u) / u * 100).rounded())
        percent = p
        delta = Figure.local(Double(p), unit: "percent",
                             arithmetic: "(\(n(v))\(suffix) \u{2212} \(n(u))\(suffix)) ÷ \(n(u))\(suffix) = \(ReviewCopy.signedPercent(p))%",
                             evidence: [])
        line = ReviewCopy.vsUsual(percent: p)
      } else if v == 0 {
        percent = 0
        delta = Figure.local(0, unit: "percent", arithmetic: "0\(suffix) this week and 0\(suffix) in your usual week", evidence: [])
        line = ReviewCopy.sameAsUsual
      } else {
        line = ReviewCopy.newThisWeek
      }
    } else {
      line = ReviewCopy.firstWeek
    }
    var run: Figure?
    var signedRun = 0
    let chainValues = chain.map(value)
    let r = WeekStats.run(chainValues)
    if abs(r) >= tileRun {
      let shown = chainValues.suffix(abs(r) + 1).map { n($0) + suffix }.joined(separator: " \u{2192} ")
      run = Figure.local(Double(abs(r)), unit: "weeks",
                         arithmetic: "\(shown): \(r > 0 ? "up" : "down") \(abs(r)) weeks in a row", evidence: [])
      signedRun = r
      line = ReviewCopy.running(up: r > 0, weeks: abs(r))
    }
    return ReviewTile(kind: kind, label: label, value: figure, valueText: ReviewFormat.value(figure), deltaLine: line,
                      usual: usual, delta: delta, run: run, tone: ReviewTile.tone(for: kind, percent: percent, run: signedRun))
  }

  static func activeArithmetic(_ w: WeekStats) -> String {
    let d = w.days.count
    return "\(d) \(d == 1 ? "day" : "days") counted: \(AnalysisCopy.duration(w.activeSeconds)) = \(ReviewFormat.number(w.activeHours)) h"
  }

  static func focusArithmetic(_ w: WeekStats) -> String {
    let b = w.focusBlocks
    guard b > 0 else { return "no focus blocks of 25 min or more this week = 0 h" }
    return "\(b) focus \(b == 1 ? "block" : "blocks") added up: \(AnalysisCopy.duration(w.focusSeconds)) = \(ReviewFormat.number(w.focusHours)) h"
  }

  static func switchesArithmetic(_ w: WeekStats) -> String {
    "\(w.switches) switches ÷ \(AnalysisCopy.hours(w.activeSeconds)) active = \(AnalysisCopy.decimal(w.switchesPerHour)) an hour"
  }

  /// ISO weeks from `a` to `b` inclusive.
  static func weeks(from a: ISOWeek, to b: ISOWeek) -> Int {
    var n = 1
    var cursor = a
    while cursor < b, n < 1000 {
      cursor = cursor.next
      n += 1
    }
    return n
  }

  // MARK: Sentence

  /// "grew N weeks in a row" for the highest-ranked repeat (not declined) whose minutes rose 3 or more weeks in a row
  /// up to this week; else the first-week sentence; else about, more or less than your usual.
  static func sentence(snapshot: InsightsSnapshot, chain: [WeekStats], isFirstWeek: Bool, active: ReviewTile) -> ReviewSentence {
    for p in snapshot.topRepeats {
      let minutes = chain.map { Double(WeekStats.minutes(of: p, in: $0.week)) }
      let r = WeekStats.run(minutes)
      guard r >= tileRun else { continue }
      let shown = minutes.suffix(r + 1).map { ReviewFormat.number($0) }.joined(separator: " \u{2192} ")
      let weeks = Figure.local(Double(r), unit: "weeks", arithmetic: "\(p.name): \(shown) min a week, up \(r) weeks in a row",
                               evidence: p.minutesPerWeek.evidence)
      return .grew(name: p.name, weeks: weeks)
    }
    guard let hours = active.value else { return .firstWeek(hours: Figure.nothing(unit: "hours")) }
    if isFirstWeek { return .firstWeek(hours: hours) }
    guard let delta = active.delta else { return .aboutUsual(hours: hours) }
    let p = Int(delta.value)
    if abs(p) < aboutPercent { return .aboutUsual(hours: hours) }
    return p > 0 ? .more(hours: hours, percent: delta) : .less(hours: hours, percent: delta)
  }

  // MARK: Goals

  static func goals(_ texts: [String], snapshot: InsightsSnapshot, week: ISOWeek, chain: [WeekStats],
                    answers: [LocalReviewAnswer]) -> [GoalRow] {
    let adjustments = RankingAdjustments(answers: answers)
    return texts.map { text -> GoalRow in
      let id = ReviewGoals.id(text)
      let linked = snapshot.repeats.filter { p in
        guard let e = adjustments.entries[p.key], e.answer.canLinkGoal else { return false }
        return e.goalID == id
      }
      guard !linked.isEmpty else { return GoalRow(id: id, text: text, hoursText: ReviewCopy.notLinkedYet) }
      func hours(_ w: ISOWeek) -> Double {
        let minutes = linked.reduce(0) { $0 + WeekStats.minutes(of: $1, in: w) }
        return (Double(minutes) / 6).rounded() / 10
      }
      let parts = linked.map { "\($0.name) \(WeekStats.minutes(of: $0, in: week)) min" }.joined(separator: " + ")
      let total = linked.reduce(0) { $0 + WeekStats.minutes(of: $1, in: week) }
      let h = hours(week)
      let evidence = WeekStats.dedupe(linked.flatMap { p in
        WeekStats.occurrences(of: p, in: week).map { EvidenceRef.observation($0.firstObservationID) }
      })
      let figure = Figure.local(h, unit: "hours", arithmetic: "\(parts) = \(total) min = \(ReviewFormat.number(h)) h",
                                evidence: evidence)
      let values = chain.map { hours($0.week) }
      let r = WeekStats.run(values)
      var trend: Figure?
      var items: [String] = []
      var tone = ReviewTone.neutral
      if abs(r) >= goalRun {
        let shown = values.suffix(abs(r) + 1).map { ReviewFormat.number($0) + " h" }.joined(separator: " \u{2192} ")
        trend = Figure.local(Double(abs(r)), unit: "weeks",
                             arithmetic: "\(shown): \(r > 0 ? "up" : "down") \(abs(r)) weeks in a row", evidence: [])
        items = ReviewCopy.goalTrendItems(up: r > 0, weeks: abs(r))
        tone = r > 0 ? .good : .needsYou
      }
      return GoalRow(id: id, text: text, hours: figure, hoursText: ReviewFormat.value(figure), linked: true, trend: trend,
                     trendItems: items, tone: tone)
    }
  }

  // MARK: Questions

  /// A repeat's score without any answer: minutes per week × persistence × confidence. Answers this week do not move a
  /// question.
  static func baseScore(_ p: RepeatPattern) -> Double {
    p.minutesPerWeek.value / 60 * p.persistence * p.confidence.weight
  }

  static func questions(snapshot: InsightsSnapshot, week: ISOWeek, goals: [String],
                        answers: [LocalReviewAnswer]) -> [WeekQuestion] {
    var thisWeek: [String: LocalReviewAnswer] = [:]
    var keptBefore = Set<String>()
    for a in LocalAnswers.latest(answers) {
      if a.isoWeek == week.id {
        thisWeek[a.subjectKey] = a
      } else if a.answer == .keep || a.answer == .otherGoal {
        keptBefore.insert(a.subjectKey)
      }
    }
    let candidates = snapshot.repeats
      .filter { WeekStats.minutes(of: $0, in: week) > 0 }
      .sorted { baseScore($0) != baseScore($1) ? baseScore($0) > baseScore($1) : $0.key < $1.key }
    var picked: [RepeatPattern] = []
    for p in candidates where picked.count < ReviewContent.maxQuestions {
      if thisWeek[p.key] != nil || !p.isDeclined { picked.append(p) }
    }
    let goalList = goals.map { ReviewGoal(id: ReviewGoals.id($0), text: $0) }
    return picked.enumerated().map { pair -> WeekQuestion in
      let i = pair.offset
      let p = pair.element
      let answer = thisWeek[p.key]
      let asksGoal: Bool
      if goalList.isEmpty {
        asksGoal = false
      } else if let a = answer {
        asksGoal = a.answer == .keep || a.answer == .otherGoal
      } else {
        asksGoal = !keptBefore.contains(p.key)
      }
      let mpw = Int(p.minutesPerWeek.value)
      let present = Figure.local(Double(p.weeksPresent), unit: "weeks",
                                 arithmetic: "\(p.name): seen in \(p.weeksPresent) of the last \(p.weeksObserved) weeks with data",
                                 evidence: p.minutesPerWeek.evidence)
      let observed = Figure.local(Double(p.weeksObserved), unit: "weeks",
                                  arithmetic: "weeks with data in the last \(LocalInsights.rankWeeks): \(p.weeksObserved)",
                                  evidence: [])
      let why = ReviewCopy.whyLine(top: i == 0, minutesPerWeek: mpw, present: p.weeksPresent, observed: p.weeksObserved)
      let text: String
      let chips: [ReviewChip]
      let kind: WeekQuestion.Kind
      if asksGoal {
        let goal = goalList[i % goalList.count]
        let others = goalList.filter { $0.id != goal.id }
        var list = [ReviewChip(label: ReviewCopy.yes, answer: .keep, goalID: goal.id), ReviewChip(label: ReviewCopy.no, answer: .keep)]
        if !others.isEmpty { list.append(ReviewChip(label: ReviewCopy.anotherGoal, answer: .otherGoal, goalChoices: others)) }
        chips = list
        text = ReviewCopy.goalQuestion(repeat: p.name, goal: goal.text)
        kind = .goal
      } else {
        chips = [ReviewChip(label: ReviewCopy.okBuild, answer: .build), ReviewChip(label: ReviewCopy.notNow, answer: .notNow),
                 ReviewChip(label: ReviewCopy.never, answer: .never)]
        text = ReviewCopy.buildQuestion(repeat: p.name)
        kind = .build
      }
      return WeekQuestion(subjectKey: p.key, kind: kind, name: p.name, text: text, whyLine: why,
                          why: [p.minutesPerWeek, present, observed], chips: chips,
                          answered: answer.map { ReviewAnswerKind(raw: $0.answer.rawValue) }, answeredGoalID: answer?.goalID,
                          minutesPerWeek: mpw)
    }
  }
}

extension ReviewContent {
  /// The brain's WeekReview as the screen shows it: its sentence (checked against its tiles), its four tiles as given
  /// and in its order, its goals by text, and its questions with one chip per answer it lists.
  public static func cloud(review: WeekReview, week: ISOWeek) -> ReviewContent {
    let tiles = review.tiles.enumerated().map { pair -> ReviewTile in
      let i = pair.offset
      let f = pair.element
      return ReviewTile(kind: .cloud, label: i < ReviewCopy.cloudTileLabels.count ? ReviewCopy.cloudTileLabels[i] : ReviewCopy.unitLabel(f.unit),
                 value: f, valueText: ReviewFormat.value(f))
    }
    let goals = review.goals.map { GoalRow(id: $0.id, text: $0.text) }
    let choices = review.goals.map { ReviewGoal(id: $0.id, text: $0.text) }
    let questions = review.questions.prefix(maxQuestions).map { q -> WeekQuestion in
      let chips: [ReviewChip] = q.answers.compactMap { kind -> ReviewChip? in
        guard let label = ReviewCopy.chipLabel(kind) else { return nil }
        if kind == .otherGoal {
          return choices.isEmpty ? nil : ReviewChip(label: label, answer: kind, goalChoices: choices)
        }
        return ReviewChip(label: label, answer: kind)
      }
      return WeekQuestion(subjectKey: q.subjectKey, questionKind: q.questionKind, kind: .cloud, name: q.name,
                          text: ReviewCopy.cloudQuestion(name: q.name), chips: chips, answered: q.answered)
    }
    let names = review.questions.map(\.name) + review.goals.map(\.text)
    let sentence = ReviewSentence.check(review.sentence, figures: review.tiles, names: names) ? review.sentence : ReviewSentence.fallback
    return ReviewContent(week: week, titleItems: ReviewCopy.titleItems(week), sentence: sentence, sentenceFigures: [],
                         subtitleItems: [ReviewCopy.everyNumberOpens], weeksKnown: nil, tiles: tiles, goals: goals,
                         questions: Array(questions), provenance: .cloud, names: names)
  }
}
