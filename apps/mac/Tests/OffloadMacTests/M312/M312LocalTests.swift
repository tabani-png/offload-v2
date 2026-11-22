import CryptoKit
import Foundation
import Testing
@testable import OffloadMac

// The review counted on this Mac: sentence, tiles against your usual week, goals, questions, and the rule that every
// number traces to a Figure (SPEC m3-12 red tests SENTENCE, TILES, USUAL, GOALS, QUESTIONS, FIGURES).
extension M312 {
  static let w47 = M312Clock.week("2026-W47")

  static func local(_ events: [InsightEvent], answers: [LocalReviewAnswer] = [], goals: [String] = [],
                    week: ISOWeek = M312.w47) -> ReviewContent? {
    let snapshot = M312Data.snapshot(events, answers: answers)
    return ReviewContent.local(snapshot: snapshot, week: week, goals: goals, answers: answers)
  }

  /// W37 and W38 at 8 h, W39 to W43 at 12 h, W44 to W46 at 8 h, then W47 at `minutes`.
  static func usualWeeks(thisWeek minutes: Int) -> [InsightEvent] {
    let earlier: [(week: Int, minutes: Int)] = [(37, 480), (38, 480), (39, 720), (40, 720), (41, 720), (42, 720), (43, 720),
                                                (44, 480), (45, 480), (46, 480)]
    return M312Data.focusWeeks(earlier + [(47, minutes)])
  }

  static func answer(_ key: String, _ a: LocalAnswer, week: String = "2026-W46", goal: String? = nil) -> LocalReviewAnswer {
    LocalReviewAnswer(isoWeek: week, subjectKey: key, answer: a, goalID: goal, answeredAt: M312Clock.date(2026, 11, 13, 17),
                      minutesPerWeek: 60)
  }

  // MARK: SENTENCE

  @Test("SENTENCE: a top repeat whose minutes rose in each of the last 3 weeks gives \"grew 3 weeks in a row\"")
  func sentenceGrew() throws {
    let c = try #require(Self.local(M312Data.patternWeeks(firstWeek: 44, counts: [1, 2, 3, 4])))
    #expect(c.sentence == "\(m312PatternName) grew 3 weeks in a row.")
    #expect(ReviewSentence.check(c.sentence, figures: c.figures, names: c.names))
  }

  @Test("SENTENCE: two rising weeks are not enough; the hours sentence is chosen instead")
  func sentenceGrewNeedsThreeRises() throws {
    // W44 60 min, W45 30, W46 60, W47 90: the usual is 1 h, this week 1.5 h.
    let c = try #require(Self.local(M312Data.patternWeeks(firstWeek: 44, counts: [2, 1, 2, 3])))
    #expect(!c.sentence.contains("in a row"))
    #expect(c.sentence == "You worked 1.5 h, 50% more than your usual.")
  }

  @Test("SENTENCE: about, more and less than your usual, from the Active tile's figures")
  func sentenceAboutMoreLess() throws {
    let about = try #require(Self.local(Self.usualWeeks(thisWeek: 708)))
    #expect(about.sentence == "You worked 11.8 h, about your usual.")
    let more = try #require(Self.local(Self.usualWeeks(thisWeek: 828)))
    #expect(more.sentence == "You worked 13.8 h, 15% more than your usual.")
    let less = try #require(Self.local(Self.usualWeeks(thisWeek: 528)))
    #expect(less.sentence == "You worked 8.8 h, 27% less than your usual.")
    for c in [about, more, less] { #expect(ReviewSentence.check(c.sentence, figures: c.figures, names: c.names)) }
  }

  @Test("SENTENCE: the first week has its own template")
  func sentenceFirstWeek() throws {
    let c = try #require(Self.local(M312Data.tilesWeek))
    #expect(c.sentence == "Your first week: 2.7 h of work.")
  }

  @Test("SENTENCE: a sentence with a number that is not in the figures is refused; names may hold digits")
  func sentenceCheckRefuses() {
    let hours = Figure.local(41.2, unit: "hours", arithmetic: "fixture", evidence: [])
    let weeks = Figure.local(3, unit: "weeks", arithmetic: "fixture", evidence: [])
    let cloud = Figure.local(5.21, unit: "hours", arithmetic: "fixture", evidence: [])
    #expect(ReviewSentence.check("You worked 41.2 h, about your usual.", figures: [hours]))
    #expect(!ReviewSentence.check("You worked 41.2 h, about your usual.", figures: [weeks]))
    #expect(!ReviewSentence.check("You worked 42 h, about your usual.", figures: [hours]))
    #expect(!ReviewSentence.check("You worked 41.2 h, 12% more than your usual.", figures: [hours]))
    #expect(ReviewSentence.check("You worked 5.21 h this week.", figures: [cloud]))
    #expect(ReviewSentence.check("Here is your week.", figures: []))
    #expect(!ReviewSentence.check("Notes 2 grew 3 weeks in a row.", figures: [weeks]))
    #expect(ReviewSentence.check("Notes 2 grew 3 weeks in a row.", figures: [weeks], names: ["Notes 2"]))
    #expect(ReviewSentence.fallback == "Here is your week.")
  }

  // MARK: TILES

  @Test("TILES: Active, Deep work and Switches / hour come from the week's days, in the mockup's order")
  func tilesFromSnapshot() throws {
    let c = try #require(Self.local(M312Data.tilesWeek))
    #expect(c.tiles.map(\.label) == ["Active", "Deep work", "Switches / hour", "Saved by fixes"])
    #expect(c.tiles.map(\.kind) == [.active, .deepWork, .switches, .savedByFixes])
    #expect(c.tiles[0].value?.value == 2.7)
    #expect(c.tiles[0].value?.unit == "hours")
    #expect(c.tiles[0].valueText == "2.7 h")
    #expect(c.tiles[1].value?.value == 2)
    #expect(c.tiles[1].valueText == "2 h")
    #expect(c.tiles[2].value?.value == 7.5)
    #expect(c.tiles[2].value?.unit == "per_hour")
    #expect(c.tiles[2].valueText == "7.5")
  }

  @Test("TILES: Saved by fixes reads \"no fixes yet\" and shows no number")
  func tilesSavedByFixes() throws {
    let c = try #require(Self.local(M312Data.tilesWeek))
    let saved = try #require(c.tiles.last)
    #expect(saved.label == "Saved by fixes")
    #expect(saved.valueText == "no fixes yet")
    #expect(saved.value == nil)
    #expect(saved.deltaLine == nil)
    #expect(saved.figures.isEmpty)
    #expect(saved.tone == .neutral)
    #expect(ReviewSentence.numbers(in: saved.valueText).isEmpty)
  }

  @Test("TILES: a tile's arithmetic says how it was counted")
  func tilesArithmetic() throws {
    let c = try #require(Self.local(M312Data.tilesWeek))
    #expect(c.tiles[0].value?.arithmetic.hasSuffix("= 2.7 h") == true)
    #expect(c.tiles[1].value?.arithmetic.hasSuffix("= 2 h") == true)
    // The arithmetic reproduces its value: 20 ÷ 160 × 60 = 7.5 (review 1, finding 8).
    #expect(c.tiles[2].value?.arithmetic == "20 switches ÷ 160 min active × 60 = 7.5 an hour")
    #expect(c.tiles[0].value?.evidence.isEmpty == false)
  }

  @Test("TILES: cloud tiles are the brain's four, as given and in its order")
  func tilesCloud() throws {
    let review = try JSONDecoder().decode(WeekReview.self, from: Data(M312Fixtures.review.utf8))
    let c = ReviewContent.cloud(review: review, week: Self.w47)
    #expect(c.tiles.map(\.label) == ["Active", "Focus", "Meetings", "Switches / hour"])
    #expect(c.tiles.map { $0.value?.value } == [5.21, 71, 0.75, 10.9])
    #expect(c.tiles.map(\.valueText) == ["5.21 h", "71 min", "0.75 h", "10.9"])
    #expect(c.tiles.map(\.value) == review.tiles.map { Optional($0) })
    #expect(c.tiles.allSatisfy { $0.deltaLine == nil && $0.tone == .neutral })
  }

  // MARK: USUAL

  @Test("USUAL: your usual is the median of up to 8 earlier weeks with data; \"−2% vs your usual\"")
  func usualMedianOfEight() throws {
    let c = try #require(Self.local(Self.usualWeeks(thisWeek: 708)))
    let active = c.tiles[0]
    #expect(active.value?.value == 11.8)
    // W39 to W46: 12, 12, 12, 12, 12, 8, 8, 8 → 12 (with W37 and W38 it would be 10).
    #expect(active.usual?.value == 12)
    #expect(active.usual?.arithmetic.hasPrefix("median of 8 earlier weeks") == true)
    #expect(active.delta?.value == -2)
    #expect(active.deltaLine == "\u{2212}2% vs your usual")
    #expect(active.tone == .good)
    #expect(c.tiles[1].deltaLine == "\u{2212}2% vs your usual")
    #expect(c.tiles[1].tone == .needsYou)
    #expect(c.tiles[2].deltaLine == "same as your usual")
  }

  @Test("USUAL: a week with no earlier week reads \"first week\"")
  func usualFirstWeek() throws {
    let c = try #require(Self.local(M312Data.tilesWeek))
    #expect(c.tiles.prefix(3).map(\.deltaLine) == ["first week", "first week", "first week"])
    #expect(c.tiles.prefix(3).allSatisfy { $0.usual == nil && $0.delta == nil && $0.tone == .neutral })
  }

  @Test("USUAL: tone rules: Deep work up is good, Switches / hour up needs you, Active within 10% is good")
  func usualToneRules() {
    #expect(ReviewTile.tone(for: .deepWork, percent: 5, run: 0) == .good)
    #expect(ReviewTile.tone(for: .deepWork, percent: -5, run: 0) == .needsYou)
    #expect(ReviewTile.tone(for: .deepWork, percent: 4, run: -3) == .needsYou)
    #expect(ReviewTile.tone(for: .switches, percent: 6, run: 0) == .needsYou)
    #expect(ReviewTile.tone(for: .switches, percent: -6, run: 0) == .good)
    #expect(ReviewTile.tone(for: .switches, percent: -1, run: 3) == .needsYou)
    #expect(ReviewTile.tone(for: .active, percent: -2, run: 0) == .good)
    #expect(ReviewTile.tone(for: .active, percent: 10, run: 0) == .good)
    #expect(ReviewTile.tone(for: .active, percent: -10, run: 0) == .good)
    #expect(ReviewTile.tone(for: .active, percent: 12, run: 0) == .needsYou)
    #expect(ReviewTile.tone(for: .active, percent: -11, run: -3) == .needsYou)
    #expect(ReviewTile.tone(for: .active, percent: nil, run: 0) == .neutral)
    #expect(ReviewTile.tone(for: .deepWork, percent: nil, run: 0) == .neutral)
    #expect(ReviewTile.tone(for: .savedByFixes, percent: 5, run: 0) == .neutral)
  }

  @Test("USUAL: falling 3 weeks in a row reads \"down 3 weeks running\"; 4 falling changes read 4")
  func usualRunning() throws {
    // W44 11 h, W45 10, W46 9, W47 8: three falls in consecutive weeks.
    let three = try #require(Self.local(M312Data.focusWeeks([(44, 660), (45, 600), (46, 540), (47, 480)])))
    #expect(three.tiles[1].deltaLine == "down 3 weeks running")
    #expect(three.tiles[1].run?.value == 3)
    #expect(three.tiles[1].tone == .needsYou)
    #expect(three.tiles[0].deltaLine == "down 3 weeks running")
    #expect(three.tiles[0].tone == .needsYou)  // 8 h against a usual of 10 h is 20% less
    let four = try #require(Self.local(M312Data.focusWeeks([(43, 720), (44, 660), (45, 600), (46, 540), (47, 480)])))
    #expect(four.tiles[1].deltaLine == "down 4 weeks running")
    // A gap breaks the run: W42 12 h, nothing in W43, then W44 to W47 falling twice.
    let gap = try #require(Self.local(M312Data.focusWeeks([(42, 720), (44, 600), (46, 540), (47, 480)])))
    #expect(gap.tiles[1].run == nil)
    #expect(gap.tiles[1].deltaLine?.hasSuffix("vs your usual") == true)
  }

  @Test("USUAL: rising 3 weeks in a row reads \"up 3 weeks running\"")
  func usualRunningUp() throws {
    let c = try #require(Self.local(M312Data.focusWeeks([(44, 480), (45, 540), (46, 600), (47, 660)])))
    #expect(c.tiles[1].deltaLine == "up 3 weeks running")
    #expect(c.tiles[1].tone == .good)
  }

  // MARK: GOALS

  @Test("GOALS: the profile's goals are listed, at most 3, with the brain's id shape")
  func goalsListed() throws {
    let c = try #require(Self.local(M312Data.tilesWeek, goals: ["Ship a product", "More deep work", "Close customers", "Learn"]))
    #expect(c.goals.map(\.text) == ["Ship a product", "More deep work", "Close customers"])
    #expect(c.goals.map(\.id) == ["Ship a product", "More deep work", "Close customers"].map(ReviewGoals.id))
    #expect(c.goals.allSatisfy { $0.hoursText == ReviewCopy.notLinkedYet && $0.hours == nil && !$0.linked })
  }

  @Test("GOALS: a goal's hours come only from repeats whose latest answer links them to it")
  func goalsHoursFromLinkedRepeats() throws {
    let events = M312Data.patternWeeks(firstWeek: 45, counts: [1, 2, 3])
    let key = M312Data.key(M312Data.snapshot(events), named: m312PatternName)
    let ship = ReviewGoals.id("Ship a product")
    let linked = try #require(Self.local(events, answers: [Self.answer(key, .keep, goal: ship)],
                                         goals: ["Ship a product", "More deep work"]))
    #expect(linked.goals[0].hours?.value == 1.5)
    #expect(linked.goals[0].hoursText == "1.5 h")
    #expect(linked.goals[0].linked)
    #expect(linked.goals[1].hoursText == "not linked yet")
    #expect(linked.goals[1].hours == nil)
    // not_now cannot link a goal, even with a goal id; a later answer without the goal unlinks it.
    let notNow = try #require(Self.local(events, answers: [Self.answer(key, .notNow, goal: ship)], goals: ["Ship a product"]))
    #expect(notNow.goals[0].hoursText == "not linked yet")
    let later = LocalReviewAnswer(isoWeek: "2026-W47", subjectKey: key, answer: .keep, goalID: nil,
                                  answeredAt: M312Clock.date(2026, 11, 20, 17), minutesPerWeek: 90)
    let unlinked = try #require(Self.local(events, answers: [Self.answer(key, .keep, goal: ship), later], goals: ["Ship a product"]))
    #expect(unlinked.goals[0].hoursText == "not linked yet")
  }

  @Test("GOALS: other_goal links the repeat to the goal it names")
  func goalsOtherGoal() throws {
    let events = M312Data.patternWeeks(firstWeek: 45, counts: [1, 2, 3])
    let key = M312Data.key(M312Data.snapshot(events), named: m312PatternName)
    let close = ReviewGoals.id("Close customers")
    let c = try #require(Self.local(events, answers: [Self.answer(key, .otherGoal, goal: close)],
                                    goals: ["Ship a product", "Close customers"]))
    #expect(c.goals[0].hoursText == "not linked yet")
    #expect(c.goals[1].hoursText == "1.5 h")
  }

  @Test("GOALS: trend arrows from the linked hours of earlier weeks; down reads drifting")
  func goalsTrend() throws {
    let ship = ReviewGoals.id("Ship a product")
    let upEvents = M312Data.patternWeeks(firstWeek: 45, counts: [1, 2, 3])
    let upKey = M312Data.key(M312Data.snapshot(upEvents), named: m312PatternName)
    let up = try #require(Self.local(upEvents, answers: [Self.answer(upKey, .build, goal: ship)], goals: ["Ship a product"]))
    #expect(up.goals[0].trendItems == ["\u{2191} 2 weeks"])
    #expect(up.goals[0].trend?.value == 2)
    #expect(up.goals[0].tone == .good)
    let downEvents = M312Data.patternWeeks(firstWeek: 45, counts: [3, 2, 1])
    let downKey = M312Data.key(M312Data.snapshot(downEvents), named: m312PatternName)
    let down = try #require(Self.local(downEvents, answers: [Self.answer(downKey, .keep, goal: ship)], goals: ["Ship a product"]))
    #expect(down.goals[0].hoursText == "0.5 h")
    #expect(down.goals[0].trendItems == ["\u{2193} 2 weeks", "drifting"])
    #expect(down.goals[0].tone == .needsYou)
    // One week of linked hours has no trend.
    let one = try #require(Self.local(M312Data.patternWeeks(firstWeek: 47, counts: [3]),
                                      answers: [Self.answer(upKey, .keep, goal: ship)], goals: ["Ship a product"]))
    #expect(one.goals[0].trendItems.isEmpty)
    #expect(one.goals[0].trend == nil)
  }

  @Test("GOALS: a local goal id is g_ and the first 10 hex of SHA-256 of the goal text, trimmed and lowercased")
  func goalsIDShape() {
    let id = ReviewGoals.id("Ship a product")
    #expect(id.wholeMatch(of: try! Regex("g_[0-9a-f]{10}")) != nil)
    let digest = SHA256.hash(data: Data("ship a product".utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(id == "g_" + digest.prefix(10))
    #expect(ReviewGoals.id("  Ship a Product ") == id)
    #expect(ReviewGoals.id("More deep work") != id)
  }

  // MARK: QUESTIONS

  @Test("QUESTIONS: at most 4, from the top-ranked repeats of the week; without goals each asks to build")
  func questionsAtMostFour() throws {
    let c = try #require(Self.local(M312Data.fivePatterns))
    #expect(c.questions.count == 4)
    #expect(c.questions.map(\.name) == ["A, then B", "C, then D", "E, then F", "G, then H"])
    #expect(c.questions.allSatisfy { $0.kind == .build && $0.questionKind == "opportunity" && $0.subjectKey.hasPrefix("k_") })
    #expect(c.questions[0].text == "Build something for A, then B next?")
    #expect(c.questions[0].chips.map(\.label) == ["OK, build", "Not now", "Never"])
    #expect(c.questions[0].chips.map(\.answer) == [.build, .notNow, .never])
    #expect(c.answeredCount == 0)
    #expect(c.counterItems == ["0 of 4 answered", "each answer tunes next week"])
  }

  @Test("QUESTIONS: the goal question only when goals exist; another goal offers the other goals")
  func questionsGoalOnlyWithGoals() throws {
    let one = try #require(Self.local(M312Data.fivePatterns, goals: ["Ship a product"]))
    #expect(one.questions[0].kind == .goal)
    #expect(one.questions[0].text == "Is A, then B part of ship a product?")
    #expect(one.questions[0].chips.map(\.label) == ["Yes", "No"])
    let ship = ReviewGoals.id("Ship a product")
    let close = ReviewGoals.id("Close customers")
    let two = try #require(Self.local(M312Data.fivePatterns, goals: ["Ship a product", "Close customers"]))
    let q = two.questions[0]
    #expect(q.chips.map(\.label) == ["Yes", "No", "It's for another goal"])
    #expect(q.chips.map(\.answer) == [.keep, .keep, .otherGoal])
    #expect(q.chips[0].goalID == ship)
    #expect(q.chips[1].goalID == nil)
    #expect(q.chips[2].goalChoices == [ReviewGoal(id: close, text: "Close customers")])
    #expect(two.questions[1].text == "Is C, then D part of close customers?")
    // A repeat already kept is asked about building instead.
    let snapshot = M312Data.snapshot(M312Data.fivePatterns)
    let a = M312Data.key(snapshot, named: "A, then B")
    let kept = try #require(Self.local(M312Data.fivePatterns, answers: [Self.answer(a, .keep, goal: ship)], goals: ["Ship a product"]))
    #expect(kept.questions[0].name == "A, then B")
    #expect(kept.questions[0].kind == .build)
  }

  @Test("QUESTIONS: a declined repeat is not asked; one answered this week stays in place, ticked, and is not asked again")
  func questionsAnsweredAndDeclined() throws {
    let snapshot = M312Data.snapshot(M312Data.fivePatterns)
    let a = M312Data.key(snapshot, named: "A, then B")
    let cKey = M312Data.key(snapshot, named: "C, then D")
    let answers = [Self.answer(a, .never, week: "2026-W46"),
                   LocalReviewAnswer(isoWeek: "2026-W47", subjectKey: cKey, answer: .notNow, answeredAt: M312Clock.date(2026, 11, 20, 17),
                                     minutesPerWeek: 60)]
    let c = try #require(Self.local(M312Data.fivePatterns, answers: answers))
    #expect(c.questions.map(\.name) == ["C, then D", "E, then F", "G, then H", "I, then J"])
    #expect(c.questions[0].isAnswered)
    #expect(c.questions[0].answered == .notNow)
    #expect(c.questions[0].isOn(c.questions[0].chips[1]))
    #expect(!c.questions[0].isOn(c.questions[0].chips[0]))
    #expect(c.questions.filter { !$0.isAnswered }.map(\.name) == ["E, then F", "G, then H", "I, then J"])
    #expect(c.answeredCount == 1)
  }

  @Test("QUESTIONS: the why line's numbers come from the repeat's Figures")
  func questionsWhyLine() throws {
    let events = M312Data.patternWeeks(firstWeek: 44, counts: [1, 2, 3, 4])
    let p = try #require(M312Data.snapshot(events).repeats.first)
    let c = try #require(Self.local(events))
    let q = try #require(c.questions.first)
    let mpw = Int(p.minutesPerWeek.value)
    #expect(q.whyLine == "Top repeat: \(mpw) min/week, \(p.weeksPresent) of \(p.weeksObserved) weeks.")
    #expect(q.why.map(\.value) == [Double(mpw), Double(p.weeksPresent), Double(p.weeksObserved)])
    #expect(q.why[0] == p.minutesPerWeek)
    #expect(q.minutesPerWeek == mpw)
    #expect(ReviewSentence.check(q.whyLine ?? "", figures: q.why))
    let five = try #require(Self.local(M312Data.fivePatterns))
    #expect(five.questions[1].whyLine?.hasPrefix("Top repeat") == false)
    #expect(five.questions[1].whyLine?.hasSuffix("1 of 1 week.") == true)
  }

  @Test("QUESTIONS: cloud questions keep the brain's order and answered state, with chips named by answer")
  func questionsCloud() throws {
    let review = try JSONDecoder().decode(WeekReview.self, from: Data(M312Fixtures.review.utf8))
    let c = ReviewContent.cloud(review: review, week: Self.w47)
    #expect(c.questions.map(\.subjectKey) == ["k_0123456789ab", "k_ba9876543210"])
    let q = c.questions[0]
    #expect(q.kind == .cloud)
    #expect(q.text == "What next for Reconcile invoices?")
    #expect(q.chips.map(\.label) == ["Keep", "Not now", "OK, build", "Never", "Leave it alone", "It's for another goal"])
    #expect(q.chips.last?.goalChoices.map(\.text) == ["Ship the Mac app", "Close customers"])
    #expect(q.answered == .keep)
    #expect(q.isAnswered)
    #expect(q.whyLine == nil)
    #expect(!c.questions[1].isAnswered)
    #expect(c.answeredCount == 1)
    #expect(c.counterItems == ["1 of 2 answered", "each answer tunes next week"])
    var noGoals = review
    noGoals.goals = []
    #expect(!ReviewContent.cloud(review: noGoals, week: Self.w47).questions[0].chips.contains { $0.answer == .otherGoal })
    #expect(ReviewCopy.chipLabel(.leaveAlone) == "Leave it alone")
    #expect(ReviewCopy.chipLabel(.yes) == nil)
  }

  // MARK: FIGURES

  @Test("FIGURES: every number the local review shows traces to one of its Figures")
  func figuresLocal() throws {
    var e = M312Events()
    M312Data.patternWeeks(firstWeek: 44, counts: [1, 2, 3, 4], into: &e)
    e.choppy(M312Clock.monday(week: 47, day: 4, hour: 15), steps: 12)
    let key = M312Data.key(M312Data.snapshot(e.events), named: m312PatternName)
    let ship = ReviewGoals.id("Ship a product")
    let c = try #require(Self.local(e.events, answers: [Self.answer(key, .keep, goal: ship)], goals: ["Ship a product", "Close 2 deals"]))
    // Each line is checked against its own figures (review 1, finding 7), so a line cannot borrow another's number.
    var lines: [(text: String, figures: [Figure])] = [(c.sentence, c.sentenceFigures + c.tiles.flatMap(\.figures))]
    lines += c.subtitleItems.map { ($0, [c.weeksKnown].compactMap { $0 }) }
    for t in c.tiles { lines += ([t.valueText] + [t.deltaLine].compactMap { $0 }).map { ($0, t.figures) } }
    for g in c.goals { lines += ([g.hoursText].compactMap { $0 } + g.trendItems).map { ($0, g.figures) } }
    for q in c.questions { lines += [q.whyLine].compactMap { $0 }.map { ($0, q.why) } }
    var numbers = 0
    for line in lines {
      numbers += ReviewSentence.numbers(in: line.text).count
      #expect(ReviewSentence.check(line.text, figures: line.figures, names: c.names), "not from its figures: \(line.text)")
    }
    #expect(numbers >= 10)
    #expect(c.subtitleItems == ["week 4 of what Offload knows about you", "every number opens to how it was counted"])
    #expect(c.weeksKnown?.value == 4)
    #expect(c.names.contains("Close 2 deals"))
    #expect(c.names.contains(m312PatternName))
  }

  @Test("FIGURES: every Figure has its arithmetic and the id API.md computes")
  func figuresArithmetic() throws {
    let c = try #require(Self.local(Self.usualWeeks(thisWeek: 708)))
    #expect(!c.figures.isEmpty)
    for f in c.figures {
      #expect(!f.arithmetic.isEmpty)
      #expect(f.id == Figure.id(value: f.value, unit: f.unit, arithmetic: f.arithmetic, evidence: f.evidence, sourcePurgedAt: nil))
    }
    #expect(c.tiles[0].delta?.arithmetic == "(11.8 h \u{2212} 12 h) ÷ 12 h = \u{2212}2%")
  }

  @Test("FIGURES: a cloud review's figures are the brain's tiles, and its sentence passes the same check")
  func figuresCloud() throws {
    let review = try JSONDecoder().decode(WeekReview.self, from: Data(M312Fixtures.review.utf8))
    let c = ReviewContent.cloud(review: review, week: Self.w47)
    #expect(c.figures == review.tiles)
    #expect(c.sentence == review.sentence)
    var bad = review
    bad.sentence = "You worked 99 h this week."
    #expect(ReviewContent.cloud(review: bad, week: Self.w47).sentence == ReviewSentence.fallback)
    #expect(c.provenance == .cloud)
    #expect(c.subtitleItems == ["every number opens to how it was counted"])
  }
}
