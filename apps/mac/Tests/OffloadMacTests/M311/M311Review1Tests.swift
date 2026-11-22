import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Review 1 (logs/m3-11-mac-today-live.review1.md): every number one click from how it was counted (finding 3), the
// counting line only for import recounts or an empty screen (finding 4), the menu line kept true in the cloud
// (finding 5), the paths without a test (finding 6) and one colour per kind of work (finding 7).

extension M311 {
  // MARK: Finding 3

  @Test("HOW: the card's count opens to how it was counted")
  func howCardCount() throws {
    let c = try #require(M311Fixture.local(M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat])))
    #expect(c.fix?.how == "how: Mon 1 + Tue 1 + Wed 2 + Thu 2 = 6 times")
  }

  @Test("HOW: each option's saving opens to its arithmetic; Leave it alone has none")
  func howOptionSaving() throws {
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), week: nil, opportunities: [M311Cloud.opportunity("opp_1", rank: 1)],
                                            today: M311Clock.today, timeZone: M311Clock.utc))
    let options = try #require(c.fix?.options)
    #expect(options.map(\.how) == ["how: 31 min × 6 × 0.45 = 1.4 h/wk", "how: 0.6 h/wk", nil])
  }

  @Test("HOW: a cloud repeat's how line says how the times and the minutes were counted")
  func howCloudRepeat() throws {
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), week: M311Cloud.week(), opportunities: [],
                                            today: M311Clock.today, timeZone: M311Clock.utc))
    for r in c.repeats {
      #expect(r.how.contains(r.times.arithmetic))
      #expect(r.how.contains(r.minutes.arithmetic))
    }
  }

  // MARK: Finding 4

  @MainActor @Test("STATES: a recount while content is shown (live capture's minute) does not show the counting line")
  func countingNoFlash() async {
    let snap = M311Fixture.snapshot([M311Fixture.workday])
    let (model, app) = M311Kit.localModel(snap)
    let task = app.insights.schedule { _ in snap }
    #expect(app.insights.isAnalysing)
    #expect(model.importingLine == nil)
    #expect(model.ready != nil)
    await task.value
    #expect(model.ready != nil)
  }

  @MainActor @Test("STATES: after an import finishes, its recount shows the counting line above what was counted, then clears")
  func countingAfterImport() async {
    let snap = M311Fixture.snapshot([M311Fixture.workday])
    let recordings = M311Kit.recordings()
    let (model, app) = M311Kit.localModel(snap, recordings: recordings)
    recordings.apply(.started(.videos, files: 1))
    recordings.apply(.finished(ImportReport(space: nil, filesRead: 1, skipped: 0, failed: 0, stillWriting: 0, moments: 4,
                                            observations: 4, firstDay: nil, lastDay: nil)))
    let task = app.insights.schedule { _ in snap }
    #expect(model.state == .importing(file: 0, of: 0))
    #expect(model.importingLine == TodayCopy.counting)
    #expect(model.content?.headline == "7 h 40 m of work.")
    await task.value
    #expect(model.importingLine == nil)
    #expect(model.ready != nil)
    // A later recount (live capture) does not bring the line back.
    let again = app.insights.schedule { _ in snap }
    #expect(model.importingLine == nil)
    await again.value
  }

  // MARK: Finding 5

  @MainActor @Test("MENU: a failed cloud read of today clears the menu line (nothing rather than old numbers)")
  func menuClearedOnFailure() async {
    let brain = M311Brain()
    let (model, _) = M311Kit.cloudModel(brain: brain)
    await model.refresh(force: true)
    #expect(model.menuLine == "today · 7 h 40 m")
    brain.setDay { _ in throw APIError.server(status: 500, code: .serverError, message: "", requestID: nil, ruleID: nil) }
    await model.refresh(force: true)
    #expect(model.menuLine == nil)
  }

  @MainActor @Test("MENU: in .cloud the menu reads today's record itself, at most once a minute, without Today open")
  func menuCloudReadsToday() async {
    let brain = M311Brain()
    let now = M311Now()
    let (model, _) = M311Kit.cloudModel(brain: brain, now: now)
    #expect(model.menuLine == nil)
    await model.refreshMenuLine()
    #expect(model.menuLine == "today · 7 h 40 m")
    #expect(brain.dayCalls == ["2026-11-12"])
    await model.refreshMenuLine()
    #expect(brain.dayCalls.count == 1)
    now.advance(61)
    await model.refreshMenuLine()
    #expect(brain.dayCalls.count == 2)
  }

  @MainActor @Test("MENU: in .local the menu line asks for no request")
  func menuLocalNoRequest() async {
    let brain = M311Brain()
    let insights = InsightsModel.empty(timeZone: M311Clock.utc)
    insights.publish(M311Fixture.snapshot([M311Fixture.workday]))
    let app = M311Kit().app(backends: Backends(mode: .local, brain: brain, builds: M311Builds(), provenance: .onDevice), insights: insights)
    let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {})
    await model.refreshMenuLine()
    #expect(brain.dayCalls.isEmpty)
    #expect(model.menuLine == "today · 7 h 40 m · mostly Xcode")
  }

  // MARK: Finding 6

  @MainActor @Test("ANSWER: a local answer that cannot be saved says so and the card stays")
  func answerLocalWriteFails() async {
    let store = InsightsStore(sources: InsightsStore.Sources(reader: NoInsightEvents(), answers: M311FailingAnswers(),
                                                             timeZone: M311Clock.utc, now: { M311Clock.now }))
    let insights = InsightsModel(store: store)
    insights.publish(M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat]))
    let app = M311Kit().app(insights: insights)
    let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {})
    await model.notNow()
    #expect(model.answerError == "Your answer could not be saved on this Mac.")
    #expect(model.ready?.fix?.source == .localRepeat(key: "k_aaaaaaaaaaaa", name: "Xcode, then github.com in Safari, then Slack",
                                                     minutesPerWeek: 186, isoWeek: M311Clock.week))
  }

  @MainActor @Test("ANSWER: a cloud answer that fails says why in one sentence and the card stays")
  func answerCloudFails() async {
    let builds = M311Builds(answerFailure: .transport(code: URLError.Code.notConnectedToInternet.rawValue))
    let (model, _) = M311Kit.cloudModel(builds: builds)
    await model.refresh(force: true)
    await model.notNow()
    #expect(model.answerError == "Can't reach Offload. Showing nothing rather than old numbers.")
    #expect(model.ready?.fix?.source == .opportunity(id: "opp_1"))
  }

  @MainActor @Test("HANDOFF: OK, build with Leave it alone picked hands nothing to Build progress")
  func handoffNotWhenLeavingAlone() async {
    let (model, app) = M311Kit.cloudModel()
    await model.refresh(force: true)
    model.selectOption(2)
    model.okBuild()
    #expect(app.navigation.pendingBuild == nil)
    #expect(app.navigation.selection == .today)
  }

  @MainActor @Test("CLOUD: a read of a day the person stepped away from is dropped, not drawn over the new day")
  func cloudStaleReadDropped() async {
    let brain = M311Brain()
    let (model, _) = M311Kit.cloudModel(brain: brain)
    brain.setBeforeDay { day in
      if day == "2026-11-12" { await model.previousDay() }
    }
    await model.refresh(force: true)
    #expect(brain.dayCalls == ["2026-11-12", "2026-11-11"])
    #expect(model.day == "2026-11-11")
    #expect(model.ready?.title == "Wed, Nov 11")
  }

  @MainActor @Test("DAY: while live capture runs, the minute's tick recounts today")
  func tickRecountsWhileCapturing() async {
    let store = InsightsStore(sources: InsightsStore.Sources(reader: NoInsightEvents(), timeZone: M311Clock.utc,
                                                             now: { M311Clock.now }))
    let insights = InsightsModel(store: store)
    let kit = M311Kit()
    let app = kit.app(insights: insights)
    let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {})
    await model.tick()
    #expect(await store.recomputed.isEmpty)
    kit.fakes.capture.start()
    await model.tick()
    #expect(await store.recomputed == ["2026-11-12"])
  }

  // MARK: Finding 7

  @Test("CLOUD: each kind of work keeps its colour whatever its rank that day; an unknown kind is Other's colour")
  func kindColoursStable() throws {
    var day = M311Cloud.day()
    day.byKind = [
      KindMinutes(kind: "email", minutes: M311Cloud.fig(200, "minutes", "200 min of email")),
      KindMinutes(kind: "code", minutes: M311Cloud.fig(100, "minutes", "100 min of code")),
      KindMinutes(kind: "mystery", minutes: M311Cloud.fig(50, "minutes", "50 min of mystery")),
    ]
    let c = try #require(TodayContent.cloud(day: day, week: nil, opportunities: [], today: M311Clock.today, timeZone: M311Clock.utc))
    #expect(c.kinds.map(\.kind) == ["Email", "Code", "Mystery"])
    #expect(c.kinds.map(\.colorHex) == [Tokens.Palette.needsYou, Tokens.Palette.working, DayGrid.otherColor])
    #expect(TodayContent.kindColor("code") == Tokens.Palette.working)
    #expect(Set(["code", "docs", "meeting", "sheet", "email", "chat", "browse"].map(TodayContent.kindColor)).count == 7)
  }
}
