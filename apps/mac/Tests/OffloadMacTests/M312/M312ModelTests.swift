import Foundation
import Testing
@testable import OffloadMac

// The screen's model: answering in both modes, the notes after an answer, the states, and the brain's routes (SPEC
// m3-12 red tests ANSWERS, NOTES, STATES, CLOUD).
extension M312 {
  /// A local model over the five patterns of W47, with the answers in `store`.
  @MainActor static func fiveModel(store: MemoryLocalAnswerStore = MemoryLocalAnswerStore(), goals: [String] = [],
                                   navigation: NavigationModel = NavigationModel()) async -> (WeeklyReviewModel, InsightsModel) {
    let insights = await M312Kit.insights(M312Data.fivePatterns, answers: store)
    let model = M312Kit.model(insights: insights, navigation: navigation, goals: goals)
    await model.refresh()
    return (model, insights)
  }

  /// A cloud model whose transport answers with `replies` in order.
  @MainActor static func cloudModel(_ replies: [RecordingTransport.Reply], navigation: NavigationModel = NavigationModel(),
                                    now: Date = M312Clock.now) -> (WeeklyReviewModel, RecordingTransport) {
    let transport = RecordingTransport(replies: replies)
    let model = M312Kit.model(backends: M312Kit.cloudBackends(transport), insights: InsightsModel.empty(timeZone: M312Clock.utc),
                              navigation: navigation, now: now)
    return (model, transport)
  }

  // MARK: ANSWERS

  @Test("ANSWERS: a local answer is written to LocalAnswerStore with the week, the k_ key, the answer and the goal id")
  @MainActor func answersWrittenLocally() async throws {
    let store = MemoryLocalAnswerStore()
    let (model, _) = await Self.fiveModel(store: store, goals: ["Ship a product"])
    #expect(model.state == .ready)
    #expect(model.week.id == "2026-W47")
    let q = try #require(model.content?.questions.first)
    let yes = try #require(q.chips.first { $0.label == "Yes" })
    await model.answer(q, yes)
    let saved = try #require(store.answers().first)
    #expect(store.answers().count == 1)
    #expect(saved.isoWeek == "2026-W47")
    #expect(saved.subjectKey == q.subjectKey)
    #expect(saved.subjectKey.hasPrefix("k_"))
    #expect(saved.answer == .keep)
    #expect(saved.goalID == ReviewGoals.id("Ship a product"))
    #expect(saved.questionKind == "opportunity")
    #expect(saved.minutesPerWeek == q.minutesPerWeek)
    #expect(saved.answeredAt == M312Clock.now)
    #expect(model.content?.questions.first?.isAnswered == true)
    #expect(model.content?.answeredCount == 1)
  }

  @Test("ANSWERS: other_goal needs a goal; without one nothing is written")
  @MainActor func answersOtherGoalNeedsGoal() async throws {
    let store = MemoryLocalAnswerStore()
    let (model, _) = await Self.fiveModel(store: store, goals: ["Ship a product", "Close customers"])
    let q = try #require(model.content?.questions.first)
    let other = try #require(q.chips.first { $0.answer == .otherGoal })
    await model.answer(q, other)
    #expect(store.answers().isEmpty)
    #expect(model.answerError == ReviewCopy.pickGoal)
    let close = ReviewGoals.id("Close customers")
    await model.answer(q, other, goalID: close)
    #expect(store.answers().map(\.answer) == [.otherGoal])
    #expect(store.answers().first?.goalID == close)
    #expect(model.answerError == nil)
  }

  @Test("ANSWERS: after a local answer the next snapshot ranks it at once; Never drops the repeat from the top")
  @MainActor func answersRankAtOnce() async throws {
    let store = MemoryLocalAnswerStore()
    // The five patterns of W47, and A then B and C then D again on Mon and Tue of W48, so next week has questions.
    var later = M312Events(origin: .imported("imp-m312-w48"), prefix: "w48")
    for day in 0..<2 {
      for (i, pair) in [("A", "B"), ("C", "D")].enumerated() {
        let steps: [M312Step] = [(app: M312App.letter(pair.0), host: nil, minutes: 12 - i * 2),
                                 (app: M312App.letter(pair.1), host: nil, minutes: 12 - i * 2)]
        later.session(M312Clock.monday(week: 48, day: day, hour: 8 + i * 2), steps)
      }
    }
    let insights = await M312Kit.insights(M312Data.fivePatterns + later.events, answers: store)
    let model = M312Kit.model(insights: insights)
    await model.refresh()
    let q = try #require(model.content?.questions.first)
    #expect(insights.snapshot.topRepeats.first?.key == q.subjectKey)
    let never = try #require(q.chips.first { $0.answer == .never })
    await model.answer(q, never)
    let ranked = try #require(insights.snapshot.repeats.first { $0.key == q.subjectKey })
    #expect(ranked.isDeclined)
    #expect(!insights.snapshot.topRepeats.contains { $0.key == q.subjectKey })
    // The question stays in place, answered; the next week does not ask it.
    #expect(model.content?.questions.first?.subjectKey == q.subjectKey)
    #expect(model.content?.questions.first?.answered == .never)
    let next = try #require(ReviewContent.local(snapshot: insights.snapshot, week: M312Clock.week("2026-W48"), goals: [],
                                                answers: store.answers()))
    #expect(!next.questions.contains { $0.subjectKey == q.subjectKey })
    #expect(next.questions.map(\.name) == ["C, then D"])
  }

  @Test("ANSWERS: a cloud answer posts the exact body and leaves goal_id out when there is none")
  @MainActor func answersCloudBody() async throws {
    let (model, transport) = Self.cloudModel([.json(200, M312Fixtures.review), .json(200, M312Fixtures.answer),
                                              .json(200, M312Fixtures.answer)])
    await model.refresh()
    let q = try #require(model.content?.questions.last)
    let notNow = try #require(q.chips.first { $0.answer == .notNow })
    await model.answer(q, notNow)
    #expect(transport.requests.count == 2)
    let post = transport.requests[1]
    #expect(post.httpMethod == "POST")
    #expect(post.url?.absoluteString == "https://api.example.test/v1/review/answers")
    #expect(M312Kit.body(post) == #"{"answer":"not_now","iso_week":"2026-W47","question_kind":"opportunity","subject_key":"k_ba9876543210"}"#)
    #expect(model.content?.questions.last?.answered == .notNow)
    let other = try #require(q.chips.first { $0.answer == .otherGoal })
    await model.answer(q, other, goalID: "g_0b1c2d3e4f")
    #expect(M312Kit.body(transport.requests[2]) == #"{"answer":"other_goal","goal_id":"g_0b1c2d3e4f","iso_week":"2026-W47","question_kind":"opportunity","subject_key":"k_ba9876543210"}"#)
  }

  @Test("ANSWERS: a goal id is sent only with keep, build or other_goal")
  @MainActor func answersGoalOnlyWhenItLinks() async throws {
    let (model, transport) = Self.cloudModel([.json(200, M312Fixtures.review), .json(200, M312Fixtures.answer)])
    await model.refresh()
    let q = try #require(model.content?.questions.last)
    let never = try #require(q.chips.first { $0.answer == .never })
    await model.answer(q, never, goalID: "g_0b1c2d3e4f")
    #expect(!M312Kit.body(transport.requests[1]).contains("goal_id"))
  }

  @Test("ANSWERS: a failed cloud answer leaves the question unanswered and says so")
  @MainActor func answersCloudFailure() async throws {
    let (model, _) = Self.cloudModel([.json(200, M312Fixtures.review), .offline])
    await model.refresh()
    let q = try #require(model.content?.questions.last)
    let buildChip = try #require(q.chips.first { $0.answer == .build })
    await model.answer(q, buildChip)
    #expect(model.content?.questions.last?.isAnswered == false)
    #expect(model.answerError == ReviewCopy.answerFailed)
  }

  // MARK: NOTES

  @Test("NOTES: OK, build adds the build note and hands the repeat to Build progress")
  @MainActor func notesBuildLocal() async throws {
    let navigation = NavigationModel()
    let (model, _) = await Self.fiveModel(navigation: navigation)
    let q = try #require(model.content?.questions.first)
    let buildChip = try #require(q.chips.first { $0.answer == .build })
    await model.answer(q, buildChip)
    #expect(navigation.pendingBuild == .localRepeat(key: q.subjectKey, name: q.name, minutesPerWeek: q.minutesPerWeek))
    #expect(navigation.selection == .builds)
    #expect(model.content?.questions.first?.noteItems == ["queued", "same build screen as today"])
  }

  @Test("NOTES: in the cloud OK, build hands over the question's task key")
  @MainActor func notesBuildCloud() async throws {
    let navigation = NavigationModel()
    let (model, _) = Self.cloudModel([.json(200, M312Fixtures.review), .json(200, M312Fixtures.answer)], navigation: navigation)
    await model.refresh()
    let q = try #require(model.content?.questions.last)
    let buildChip = try #require(q.chips.first { $0.answer == .build })
    await model.answer(q, buildChip)
    #expect(navigation.pendingBuild == .opportunity(id: "k_ba9876543210", optionID: nil))
    #expect(navigation.selection == .builds)
  }

  @Test("NOTES: Never adds \"it won't come back unless the hours rise by half\"; other answers add no note")
  @MainActor func notesNever() async throws {
    let (model, _) = await Self.fiveModel()
    let qs = try #require(model.content?.questions)
    let neverChip = try #require(qs[0].chips.first { $0.answer == .never })
    await model.answer(qs[0], neverChip)
    let notNowChip = try #require(qs[1].chips.first { $0.answer == .notNow })
    await model.answer(qs[1], notNowChip)
    let after = try #require(model.content?.questions)
    #expect(after[0].noteItems == ["it won't come back unless the hours rise by half"])
    #expect(after[1].noteItems.isEmpty)
    #expect(after[2].noteItems.isEmpty)
  }

  @Test("NOTES: the counter reads \"2 of 4 answered · each answer tunes next week\" as two items")
  @MainActor func notesCounter() async throws {
    let (model, _) = await Self.fiveModel()
    let qs = try #require(model.content?.questions)
    await model.answer(qs[0], qs[0].chips[1])
    await model.answer(qs[2], qs[2].chips[1])
    #expect(model.content?.answeredCount == 2)
    #expect(model.content?.counterItems == ["2 of 4 answered", "each answer tunes next week"])
    #expect(ReviewCopy.counterItems(answered: 0, total: 1) == ["0 of 1 answered", "each answer tunes next week"])
  }

  // MARK: STATES

  @Test("STATES: a local week with nothing counted is empty, with Choose recordings")
  @MainActor func statesEmpty() async {
    let navigation = NavigationModel()
    let insights = await M312Kit.insights([])
    let model = M312Kit.model(insights: insights, navigation: navigation)
    await model.refresh()
    #expect(model.state == .empty)
    #expect(model.content == nil)
    #expect(ReviewCopy.empty == "Nothing counted this week yet.")
    #expect(ReviewCopy.chooseRecordings == "Choose recordings")
    model.chooseRecordings()
    #expect(navigation.selection == .recordings)
  }

  @Test("STATES: an empty week offers the latest week with data (an old archive), which opens with one tap")
  @MainActor func statesEmptyOffersLatestWeek() async {
    let insights = await M312Kit.insights(M312Data.focusWeeks([(40, 90), (41, 120)]))
    let model = M312Kit.model(insights: insights)
    await model.refresh()
    #expect(model.week.id == "2026-W47")
    #expect(model.state == .empty)
    #expect(model.latestDataWeek?.id == "2026-W41")
    #expect(ReviewCopy.seeWeek(M312Clock.week("2026-W41")) == "See the week of Oct 5")
    await model.showLatestData()
    #expect(model.week.id == "2026-W41")
    #expect(model.state == .ready)
    #expect(model.content?.tiles.first?.valueText == "2 h")
    let none = M312Kit.model(insights: await M312Kit.insights([]))
    await none.refresh()
    #expect(none.latestDataWeek == nil)
  }

  @Test("STATES: before the slot this week is not yet: the line names the slot in words; last week is shown first")
  @MainActor func statesNotYet() async {
    let wednesday = M312Clock.date(2026, 11, 18, 12)
    let insights = await M312Kit.insights(M312Data.patternWeeks(firstWeek: 45, counts: [2, 2, 2]), now: wednesday)
    let model = M312Kit.model(insights: insights, now: wednesday)
    await model.refresh()
    #expect(model.week.id == "2026-W46")
    #expect(model.state == .ready)
    #expect(model.canGoForward)
    await model.nextWeek()
    #expect(model.week.id == "2026-W47")
    #expect(model.state == .notYet(M312Clock.week("2026-W47")))
    #expect(model.notYetLine == "Your review for this week lands Friday at 4:00 PM.")
    #expect(!model.canGoForward)
    await model.previousWeek()
    #expect(model.week.id == "2026-W46")
    await model.previousWeek()
    #expect(model.week.id == "2026-W45")
    #expect(!model.canGoBack)
  }

  @Test("STATES: previous and next step through weeks with data, skipping weeks without")
  @MainActor func statesStepThroughWeeks() async {
    let insights = await M312Kit.insights(M312Data.focusWeeks([(42, 60), (45, 60), (47, 60)]))
    let model = M312Kit.model(insights: insights)
    await model.refresh()
    #expect(model.week.id == "2026-W47")
    await model.previousWeek()
    #expect(model.week.id == "2026-W45")
    await model.previousWeek()
    #expect(model.week.id == "2026-W42")
    #expect(!model.canGoBack)
    await model.nextWeek()
    #expect(model.week.id == "2026-W45")
  }

  @Test("STATES: a failed load has one sentence per error with Try again, which loads again")
  @MainActor func statesFailed() async {
    #expect(ReviewError(.transport(code: URLError.Code.notConnectedToInternet.rawValue)) == .offline)
    #expect(ReviewError(.notSignedIn) == .signedOut)
    #expect(ReviewError(.server(status: 401, code: .tokenExpired, message: "", requestID: nil, ruleID: nil)) == .signedOut)
    #expect(ReviewError(.server(status: 429, code: .rateLimited, message: "", requestID: nil, ruleID: nil)) == .busy)
    #expect(ReviewError(.server(status: 500, code: .serverError, message: "", requestID: nil, ruleID: nil)) == .server)
    #expect(ReviewError(.badResponse(status: 502)) == .server)
    #expect(ReviewError(.invalidBody) == .other)
    let sentences = [ReviewError.offline, .signedOut, .busy, .server, .other].map(\.sentence)
    #expect(Set(sentences).count == 5)
    #expect(ReviewCopy.tryAgain == "Try again")
    let (model, _) = Self.cloudModel([.offline, .json(200, M312Fixtures.review)])
    await model.refresh()
    #expect(model.state == .failed(.offline))
    #expect(model.failureLine == ReviewError.offline.sentence)
    #expect(model.content == nil)
    await model.refresh()
    #expect(model.state == .ready)
  }

  // MARK: CLOUD

  @Test("CLOUD: the review is GET /v1/review/week?w=2026-W47 for the shown week")
  @MainActor func cloudRequest() async throws {
    let (model, transport) = Self.cloudModel([.json(200, M312Fixtures.review)])
    await model.refresh()
    let req = try #require(transport.requests.first)
    #expect(transport.requests.count == 1)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/review/week?w=2026-W47")
  }

  @Test("CLOUD: the brain's WeekReview maps to the screen's content")
  @MainActor func cloudMapsFixture() async throws {
    let (model, _) = Self.cloudModel([.json(200, M312Fixtures.review)])
    await model.refresh()
    let c = try #require(model.content)
    #expect(model.state == .ready)
    #expect(c.title == "Week of Nov 16 \u{00B7} review")
    #expect(c.titleItems == ["Week of Nov 16", "review"])
    #expect(c.sentence == "You worked 5.21 h this week: 71 min in focus blocks and 0.75 h in meetings.")
    #expect(c.tiles.count == 4)
    #expect(c.goals.map(\.text) == ["Ship the Mac app", "Close customers"])
    #expect(c.goals.allSatisfy { $0.hoursText == nil && $0.trendItems.isEmpty })
    #expect(c.questions.count == 2)
    #expect(c.provenance == .cloud)
  }

  @Test("CLOUD: a 404 for the week is no review, never an error")
  @MainActor func cloudNotFound() async {
    let (model, _) = Self.cloudModel([.json(404, M312Fixtures.notFound)])
    await model.refresh()
    // After the slot a 404 means the brain has no review for the week (review 1, finding 5); "not yet" is only for a
    // week before its slot, which is never requested.
    #expect(model.state == .noReview(M312Clock.week("2026-W47")))
    #expect(model.content == nil)
  }

  @Test("CLOUD: .local never sends a request, even with a client present")
  @MainActor func cloudNothingInLocal() async throws {
    let transport = RecordingTransport(replies: [.json(200, M312Fixtures.review)])
    let cloud = M312Kit.cloudBackends(transport)
    let backends = Backends(mode: .local, brain: cloud.brain, builds: nil, provenance: .onDevice)
    let store = MemoryLocalAnswerStore()
    let insights = await M312Kit.insights(M312Data.fivePatterns, answers: store)
    let model = M312Kit.model(backends: backends, insights: insights)
    await model.refresh()
    let q = try #require(model.content?.questions.first)
    await model.answer(q, q.chips[0])
    await model.previousWeek()
    await model.nextWeek()
    #expect(transport.requests.isEmpty)
    #expect(model.content?.provenance == .onDevice)
    #expect(store.answers().count == 1)
  }
}
