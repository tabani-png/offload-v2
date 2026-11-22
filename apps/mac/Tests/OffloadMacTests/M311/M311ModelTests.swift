import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// TodayLiveModel over the real AppModel (m3-04's fakes), m3-10's InsightsModel, NavigationModel and backends, with
// fixture snapshots and fake or recording clients. No window, no network.

extension M311 {
  // MARK: DAY

  @MainActor @Test("DAY: the model shows today when anything was counted today")
  func dayToday() {
    let (model, _) = M311Kit.localModel(M311Fixture.snapshot([M311Fixture.nov5, M311Fixture.nov9, M311Fixture.workday]))
    #expect(model.day == "2026-11-12")
    #expect(model.days == ["2026-11-05", "2026-11-09", "2026-11-12"])
    #expect(model.ready?.title == "Today · Thu, Nov 12")
  }

  @MainActor @Test("DAY: without data today the model shows the latest day with data (imports are of past days)")
  func dayLatest() {
    let (model, _) = M311Kit.localModel(M311Fixture.snapshot([M311Fixture.nov5, M311Fixture.nov9]))
    #expect(model.day == "2026-11-09")
    #expect(model.ready?.title == "Mon, Nov 9")
  }

  @MainActor @Test("DAY: previous and next step through days with data only, and stop at the ends")
  func dayStepping() async {
    let (model, _) = M311Kit.localModel(M311Fixture.snapshot([M311Fixture.nov5, M311Fixture.nov9, M311Fixture.workday]))
    #expect(!model.canGoForward)
    await model.previousDay()
    #expect(model.day == "2026-11-09")
    await model.previousDay()
    #expect(model.day == "2026-11-05")
    #expect(!model.canGoBack)
    await model.previousDay()
    #expect(model.day == "2026-11-05")
    await model.nextDay()
    #expect(model.day == "2026-11-09")
    #expect(model.ready?.title == "Mon, Nov 9")
  }

  @MainActor @Test("DAY: a new snapshot keeps the day picked while it still has data")
  func dayKeptOnRefresh() async {
    let insights = InsightsModel.empty(timeZone: M311Clock.utc)
    insights.publish(M311Fixture.snapshot([M311Fixture.nov5, M311Fixture.workday]))
    let app = M311Kit().app(insights: insights)
    let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {})
    await model.previousDay()
    #expect(model.day == "2026-11-05")
    insights.publish(M311Fixture.snapshot([M311Fixture.nov5, M311Fixture.nov9, M311Fixture.workday]))
    #expect(model.day == "2026-11-05")
    #expect(model.days.count == 3)
    insights.publish(M311Fixture.snapshot([M311Fixture.workday]))
    #expect(model.day == "2026-11-12")
  }

  // MARK: HOW

  @MainActor @Test("HOW: tapping the count shows the how line; a second tap hides it")
  func howToggle() {
    let snap = M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat] + M311Fixture.moreRepeats)
    let (model, _) = M311Kit.localModel(snap)
    #expect(!model.isHowShown("k_aaaaaaaaaaaa"))
    model.toggleHow("k_aaaaaaaaaaaa")
    #expect(model.isHowShown("k_aaaaaaaaaaaa"))
    #expect(!model.isHowShown("k_bbbbbbbbbbbb"))
    model.toggleHow("k_aaaaaaaaaaaa")
    #expect(!model.isHowShown("k_aaaaaaaaaaaa"))
  }

  // MARK: ANSWER

  @MainActor @Test("ANSWER: local Not now writes not_now for the repeat's key and the shown week, and the card moves on")
  func answerNotNow() async throws {
    let snap = M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat] + M311Fixture.moreRepeats)
    let (model, app) = M311Kit.localModel(snap)
    #expect(model.ready?.fix?.source == .localRepeat(key: "k_aaaaaaaaaaaa", name: "Xcode, then github.com in Safari, then Slack",
                                                     minutesPerWeek: 186, isoWeek: M311Clock.week))
    await model.notNow()
    let saved = try #require(app.insights.answers.answers().first)
    #expect(saved.subjectKey == "k_aaaaaaaaaaaa")
    #expect(saved.isoWeek == M311Clock.week)
    #expect(saved.answer == .notNow)
    #expect(saved.answeredAt == M311Clock.now)
    #expect(saved.minutesPerWeek == 186)
    guard case .localRepeat(let key, _, _, _) = model.ready?.fix?.source else {
      Issue.record("no next card")
      return
    }
    #expect(key == "k_bbbbbbbbbbbb")
  }

  @MainActor @Test("ANSWER: local Leave it alone writes leave_alone and the repeat leaves the list")
  func answerLeaveAlone() async throws {
    let snap = M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat] + M311Fixture.moreRepeats)
    let (model, app) = M311Kit.localModel(snap)
    await model.leaveAlone()
    let saved = try #require(app.insights.answers.answers().first)
    #expect(saved.answer == .leaveAlone)
    #expect(saved.subjectKey == "k_aaaaaaaaaaaa")
    #expect(!(model.ready?.repeats.contains { $0.key == "k_aaaaaaaaaaaa" } ?? true))
  }

  @MainActor @Test("ANSWER: the answer reaches local ranking: after the store reloads, the declined repeat stays away")
  func answerRanking() async throws {
    // Three days with the same three steps: a real repeat counted by m3-10's engine and store.
    var e = M311Events()
    for d in [9, 10, 11] {
      e.session(M311Clock.date(2026, 11, d, 10), [(M311App.xcode, nil, 10), (M311App.safari, "github.com", 10), (M311App.slack, nil, 10)])
    }
    let events = e.events
    struct Reader: InsightEventReader {
      let all: [InsightEvent]
      func events(in interval: DateInterval) -> [InsightEvent] { all.filter { $0.ts >= interval.start && $0.ts < interval.end } }
      func dayLabels(timeZone: TimeZone) -> [String] { Array(Set(all.map { LocalDays.label($0.ts, timeZone: timeZone) })).sorted() }
    }
    let answers = MemoryLocalAnswerStore()
    let store = InsightsStore(sources: InsightsStore.Sources(reader: Reader(all: events), answers: answers, timeZone: M311Clock.utc,
                                                             now: { M311Clock.now }))
    let insights = InsightsModel(store: store)
    await insights.refreshAll()
    let app = M311Kit().app(insights: insights)
    let model = TodayLiveModel(app: app, now: M311Now().clock)
    #expect(model.day == "2026-11-11")
    #expect(model.ready?.fix != nil)
    await model.notNow()
    await insights.idle()
    #expect(model.ready?.fix == nil)
    #expect(insights.snapshot.thingsYouRepeat.isEmpty)
  }

  @MainActor @Test("ANSWER: cloud Not now posts POST /v1/opportunities/{id}/answer with the exact body")
  func answerCloudBody() async throws {
    let opps = try JSONEncoder().encode([M311Cloud.opportunity("opp_1", rank: 1)])
    let transport = RecordingTransport(replies: [
      .status(200, body: opps),
      .json(200, #"{"id":"opp_1","title":"","state":"not_now"}"#),
    ])
    let core = APIClientCore(config: M311Backends.config, transport: transport)
    let app = M311Kit().app(backends: M311Backends.cloud(brain: M311Brain(), builds: HTTPBuildsClient(core: core)))
    let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {})
    await model.refresh(force: true)
    #expect(model.ready?.fix?.source == .opportunity(id: "opp_1"))
    await model.notNow()
    let post = try #require(transport.requests.last)
    #expect(post.httpMethod == "POST")
    #expect(post.url?.absoluteString == "https://api.example.test/v1/opportunities/opp_1/answer")
    #expect(String(decoding: post.httpBody ?? Data(), as: UTF8.self) == #"{"answer":"not_now"}"#)
    #expect(model.ready?.fix == nil)
  }

  @MainActor @Test("ANSWER: cloud Leave it alone (the button or the picked option) posts leave_alone")
  func answerCloudLeaveAlone() async {
    let builds = M311Builds()
    let (model, _) = M311Kit.cloudModel(builds: builds)
    await model.refresh(force: true)
    model.selectOption(2)
    #expect(model.primaryLabel == "Leave it alone")
    await model.pressPrimary()
    #expect(builds.answers.count == 1)
    #expect(builds.answers.first?.0 == "opp_1")
    #expect(builds.answers.first?.1 == .leaveAlone)
    #expect(builds.answers.first?.2 == nil)
  }

  // MARK: HANDOFF

  @MainActor @Test("HANDOFF: OK, build in .local starts a localRepeat build with the key, name and minutes per week")
  func handoffLocal() {
    let snap = M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat])
    let (model, app) = M311Kit.localModel(snap)
    model.okBuild()
    #expect(app.navigation.pendingBuild == .localRepeat(key: "k_aaaaaaaaaaaa", name: "Xcode, then github.com in Safari, then Slack",
                                                        minutesPerWeek: 186))
    #expect(app.navigation.selection == .builds)
  }

  @MainActor @Test("HANDOFF: OK, build in .cloud hands the opportunity and the picked option to Build progress")
  func handoffCloud() async {
    let (model, app) = M311Kit.cloudModel()
    await model.refresh(force: true)
    // The recommended option (fix_1) is picked at first.
    #expect(model.selectedOption == 0)
    model.selectOption(1)
    model.okBuild()
    #expect(app.navigation.pendingBuild == .opportunity(id: "opp_1", optionID: "fix_2"))
    #expect(app.navigation.selection == .builds)
  }

  @MainActor @Test("HANDOFF: OK, build with no card does nothing")
  func handoffNoCard() {
    let (model, app) = M311Kit.localModel(M311Fixture.snapshot([M311Fixture.workday]))
    model.okBuild()
    #expect(app.navigation.pendingBuild == nil)
    #expect(app.navigation.selection == .today)
  }

  // MARK: CLOUD

  @MainActor @Test("CLOUD: the day and week records and the open opportunities fill the screen")
  func cloudModel() async throws {
    let brain = M311Brain()
    let builds = M311Builds()
    let (model, _) = M311Kit.cloudModel(brain: brain, builds: builds)
    await model.refresh(force: true)
    #expect(brain.dayCalls == ["2026-11-12"])
    #expect(brain.weekCalls == ["2026-W46"])
    #expect(builds.calls == 1)
    let c = try #require(model.ready)
    #expect(c.headline == "7 h 40 m of work.")
    #expect(c.kinds.count == 3)
    #expect(c.did.count == 2)
    #expect(c.repeats.count == 3)
    #expect(c.fix?.source == .opportunity(id: "opp_1"))
  }

  @MainActor @Test("CLOUD: a 404 for the day is Nothing recorded for this day yet., not an error")
  func cloudNotRecorded() async {
    let brain = M311Brain(day: { _ in throw APIError.notFound })
    let (model, _) = M311Kit.cloudModel(brain: brain)
    await model.refresh(force: true)
    #expect(model.state == .notRecorded("2026-11-12"))
  }

  @MainActor @Test("CLOUD: no request is made in .local, even with clients present")
  func cloudNoRequestInLocal() async {
    let brain = M311Brain()
    let builds = M311Builds()
    let insights = InsightsModel.empty(timeZone: M311Clock.utc)
    insights.publish(M311Fixture.snapshot([M311Fixture.workday]))
    let app = M311Kit().app(backends: Backends(mode: .local, brain: brain, builds: builds, provenance: .onDevice), insights: insights)
    let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {})
    await model.refresh(force: true)
    await model.previousDay()
    await model.tick()
    #expect(brain.dayCalls.isEmpty)
    #expect(brain.weekCalls.isEmpty)
    #expect(builds.calls == 0)
    #expect(model.ready?.provenance == .onDevice)
  }

  @MainActor @Test("CLOUD: reads are not repeated more than once a minute unless forced")
  func cloudOncePerMinute() async {
    let brain = M311Brain()
    let now = M311Now()
    let (model, _) = M311Kit.cloudModel(brain: brain, now: now)
    await model.refresh()
    await model.refresh()
    await model.tick()
    #expect(brain.dayCalls.count == 1)
    now.advance(61)
    await model.tick()
    #expect(brain.dayCalls.count == 2)
    await model.refresh(force: true)
    #expect(brain.dayCalls.count == 3)
  }

  @MainActor @Test("CLOUD: previous and next step one calendar day, never past today")
  func cloudStepping() async {
    let brain = M311Brain()
    let (model, _) = M311Kit.cloudModel(brain: brain)
    await model.refresh(force: true)
    await model.nextDay()
    #expect(model.day == "2026-11-12")
    await model.previousDay()
    #expect(model.day == "2026-11-11")
    #expect(brain.dayCalls == ["2026-11-12", "2026-11-11"])
    #expect(model.ready?.title == "Wed, Nov 11")
  }

  // MARK: STATES

  @MainActor @Test("STATES: nothing counted is the empty state; Choose recordings selects the Recordings screen")
  func stateEmpty() {
    let (model, app) = M311Kit.localModel(.empty)
    #expect(model.state == .empty)
    #expect(model.content == nil)
    model.chooseRecordings()
    #expect(app.navigation.selection == .recordings)
  }

  @MainActor @Test("STATES: the importing line shows while m3-05's phase is reading, above what was already counted")
  func stateImporting() {
    let recordings = M311Kit.recordings()
    let (model, _) = M311Kit.localModel(M311Fixture.snapshot([M311Fixture.workday]), recordings: recordings)
    #expect(model.ready != nil)
    recordings.apply(.started(.videos, files: 12))
    recordings.apply(.reading(file: 3, of: 12))
    #expect(model.state == .importing(file: 3, of: 12))
    #expect(model.content?.headline == "7 h 40 m of work.")
    #expect(model.importingLine == "reading file 3 of 12 · Today updates when it's done")
    recordings.apply(.finished(ImportReport(space: nil, filesRead: 12, skipped: 0, failed: 0, stillWriting: 0, moments: 10,
                                            observations: 10, firstDay: nil, lastDay: nil)))
    #expect(model.ready != nil)
  }

  @MainActor @Test("STATES: while insights are counting with nothing counted yet, no number is shown")
  func stateCounting() {
    let recordings = M311Kit.recordings()
    let (model, _) = M311Kit.localModel(.empty, recordings: recordings)
    recordings.apply(.started(.videos, files: 2))
    #expect(model.state == .importing(file: 0, of: 2))
    #expect(model.content == nil)
    #expect(model.importingLine == "looking at the folder · Today updates when it's done")
  }

  @MainActor @Test("STATES: a failed cloud read says one sentence per error code, and Try again reads again")
  func stateFailed() async {
    #expect(TodayError(APIError.server(status: 401, code: .unauthenticated, message: "", requestID: nil, ruleID: nil)).sentence
      == "Sign in again to see Today.")
    #expect(TodayError(APIError.server(status: 401, code: .tokenExpired, message: "", requestID: nil, ruleID: nil)).sentence
      == "Sign in again to see Today.")
    #expect(TodayError(APIError.notSignedIn).sentence == "Sign in again to see Today.")
    #expect(TodayError(APIError.transport(code: URLError.Code.notConnectedToInternet.rawValue)).sentence
      == "Can't reach Offload. Showing nothing rather than old numbers.")
    #expect(TodayError(APIError.server(status: 500, code: .serverError, message: "", requestID: nil, ruleID: nil)).sentence
      == "Today could not load (server_error).")
    let brain = M311Brain(day: { _ in throw APIError.transport(code: URLError.Code.notConnectedToInternet.rawValue) })
    let (model, _) = M311Kit.cloudModel(brain: brain)
    await model.refresh(force: true)
    #expect(model.state == .failed(.offline))
    #expect(model.content == nil)
    brain.setDay { M311Cloud.day($0) }
    await model.tryAgain()
    #expect(model.ready?.headline == "7 h 40 m of work.")
  }

  @MainActor @Test("STATES: a failed read after a good one shows nothing rather than old numbers")
  func stateFailedClears() async {
    let brain = M311Brain()
    let now = M311Now()
    let (model, _) = M311Kit.cloudModel(brain: brain, now: now)
    await model.refresh(force: true)
    #expect(model.content != nil)
    brain.setDay { _ in throw APIError.server(status: 500, code: .serverError, message: "", requestID: nil, ruleID: nil) }
    await model.refresh(force: true)
    #expect(model.state == .failed(.other("server_error")))
    #expect(model.content == nil)
  }

  // MARK: BANNERS

  @MainActor @Test("BANNERS: m3-04's banners show above the content and their actions reach AppModel")
  func banners() throws {
    let (model, app) = M311Kit.localModel(M311Fixture.snapshot([M311Fixture.workday]))
    #expect(model.banners == app.today.banners)
    let local = try #require(model.banners.first { $0.id == TodayBanner.localID })
    model.dismissBanner(local)
    #expect(!model.banners.contains { $0.id == TodayBanner.localID })
    #expect(!app.today.banners.contains { $0.id == TodayBanner.localID })
  }

  @MainActor @Test("BANNERS: tapping a banner runs AppModel.tapBanner (Local mode opens sign-in)")
  func bannerTap() throws {
    let (model, app) = M311Kit.localModel(M311Fixture.snapshot([M311Fixture.workday]))
    #expect(app.route == .today)
    let local = try #require(model.banners.first { $0.id == TodayBanner.localID })
    model.tapBanner(local)
    #expect(app.route == .onboarding(.signIn))
  }

  // MARK: KEYS

  @MainActor @Test("KEYS: 1, 2, 3 pick options and Return presses the primary button, while the card has focus")
  func keysPick() async {
    let (model, app) = M311Kit.cloudModel()
    await model.refresh(force: true)
    model.cardFocused = true
    #expect(await model.handleKey(.digit(2)))
    #expect(model.selectedOption == 1)
    #expect(await model.handleKey(.digit(3)))
    #expect(model.primaryLabel == "Leave it alone")
    #expect(await model.handleKey(.digit(1)))
    #expect(model.primaryLabel == "OK, build")
    #expect(!(await model.handleKey(.digit(4))))
    #expect(model.selectedOption == 0)
    #expect(await model.handleKey(.return))
    #expect(app.navigation.pendingBuild == .opportunity(id: "opp_1", optionID: "fix_1"))
  }

  @MainActor @Test("KEYS: without focus on the card the keys do nothing")
  func keysNeedFocus() async {
    let (model, app) = M311Kit.cloudModel()
    await model.refresh(force: true)
    model.cardFocused = false
    #expect(!(await model.handleKey(.digit(2))))
    #expect(model.selectedOption == 0)
    #expect(!(await model.handleKey(.return)))
    #expect(app.navigation.pendingBuild == nil)
  }

  @MainActor @Test("KEYS: in .local Return builds the top repeat; digits pick nothing (no options on the Mac)")
  func keysLocal() async {
    let (model, app) = M311Kit.localModel(M311Fixture.snapshot([M311Fixture.workday], repeats: [M311Fixture.reviewRepeat]))
    model.cardFocused = true
    #expect(!(await model.handleKey(.digit(1))))
    #expect(await model.handleKey(.return))
    #expect(app.navigation.pendingBuild == .localRepeat(key: "k_aaaaaaaaaaaa", name: "Xcode, then github.com in Safari, then Slack",
                                                        minutesPerWeek: 186))
  }

  // MARK: MENU (model)

  @MainActor @Test("MENU: the model's menu line follows the snapshot for today and is nil on a day without data")
  func menuModel() {
    let insights = InsightsModel.empty(timeZone: M311Clock.utc)
    insights.publish(M311Fixture.snapshot([M311Fixture.nov5]))
    let app = M311Kit().app(insights: insights)
    let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {})
    #expect(model.menuLine == nil)
    insights.publish(M311Fixture.snapshot([M311Fixture.nov5, M311Fixture.workday]))
    #expect(model.menuLine == "today · 7 h 40 m · mostly Xcode")
  }

  @MainActor @Test("MENU: one model per app, so the menu bar and the screen read the same one")
  func menuShared() {
    let app = M311Kit().app()
    #expect(TodayLiveModel.shared(for: app) === TodayLiveModel.shared(for: app))
    let other = M311Kit().app()
    #expect(TodayLiveModel.shared(for: app) !== TodayLiveModel.shared(for: other))
  }
}
