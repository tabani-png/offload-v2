import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// The planned Today API (follow-up of 2026-11-22): `.cloud` reads `GET /v1/today?date=` (API.md "Today, records and
// review") with the day record for the header, and the opportunity routes for the card's answers. One flag,
// `TodayAPI.available`, is off until the server lands; off, `.cloud` shows a labelled sample and reads nothing.
// Fixtures are real-shaped JSON (M311TodayJSON); requests go through RecordingTransport, never the network.

extension M311 {
  // MARK: Decoding

  @Test("TODAYAPI: the planned GET /v1/today payload decodes from real-shaped JSON, keeping the items it can read")
  func todayDecodes() throws {
    let p = try M311TodayJSON.payload()
    #expect(p.date == "2026-11-12")
    #expect(p.dayGrid.categories.map(\.key) == ["code", "docs", "email"])
    #expect(p.dayGrid.categories.map(\.name) == ["Coding", nil, nil])
    #expect(p.dayGrid.categories.first?.minutes?.value == 200)
    #expect(p.dayGrid.cells.count == 6)
    #expect(p.dayGrid.cells.map(\.category) == ["email", "code", "code", nil, "docs", "code"])
    #expect(p.dayGrid.switchBursts.map(\.start) == ["10:00"])
    #expect(p.dayGrid.switchBursts.first?.switches?.value == 5)
    // An item without its Figure is left out, not decoded as zero.
    #expect(p.whatYouDid.map(\.name) == ["Reconcile invoices", "Review agent PRs"])
    #expect(p.whatYouDid.map(\.start) == ["09:00", "13:05"])
    #expect(p.whatYouDid.first?.minutes.unit == "minutes")
    #expect(p.repeats.map(\.taskKey) == ["k_t1", "k_t2", "k_t3", "k_t4"])
    #expect(p.repeats.first?.medianMinutes?.value == 20)
    #expect(p.repeats[1].medianMinutes == nil)
    let fix = try #require(p.suggestedFix)
    #expect(fix.id == "opp_1")
    #expect(fix.state == .open)
    #expect(fix.taskKey == "k_t2")
    #expect(fix.options.map(\.id) == ["fix_2", "fix_1"])
    #expect(fix.options.map(\.optionNo) == [2, 1])
    #expect(fix.options.last?.estimate?.arithmetic == "31 min × 6 × 0.45 = 1.4 h/wk")
    #expect(Array(fix.factors.keys) == ["weekly_hours_saved"])
    #expect(fix.goal?.text == "ship a product")
  }

  @Test("TODAYAPI: missing lists, a null grid and a null suggested fix decode as empty, never as invented numbers")
  func todayDecodesSparse() throws {
    let p = try M311TodayJSON.payload(#"{"day_grid":null,"what_you_did":null,"suggested_fix":null,"extra":1}"#)
    #expect(p.date == nil)
    #expect(p.dayGrid.categories.isEmpty && p.dayGrid.cells.isEmpty && p.dayGrid.switchBursts.isEmpty)
    #expect(p.whatYouDid.isEmpty)
    #expect(p.repeats.isEmpty)
    #expect(p.suggestedFix == nil)
  }

  // MARK: Requests

  @Test("TODAYAPI: the Today client sends GET /v1/today?date= under the base URL with the member token and no body")
  func todayRequest() async throws {
    let transport = RecordingTransport(replies: [.json(200, M311TodayJSON.full)])
    let client = HTTPTodayClient(core: APIClientCore(config: M311Backends.config, transport: transport))
    let p = try await client.today(date: "2026-11-12")
    #expect(p.suggestedFix?.id == "opp_1")
    let req = try #require(transport.requests.first)
    #expect(transport.requests.count == 1)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/today?date=2026-11-12")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer m311-member-token")
    #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(req.httpBody == nil)
  }

  @Test("TODAYAPI: a malformed date is refused before any request, and a 404 is not found")
  func todayRequestChecks() async throws {
    let transport = RecordingTransport(replies: [.json(404, #"{"error":{"code":"not_found","message":"no record"}}"#)])
    let client = HTTPTodayClient(core: APIClientCore(config: M311Backends.config, transport: transport))
    for bad in ["2026-11-1", "2026/11/12", "../today", "2026-11-12&x=1", ""] {
      await #expect(throws: APIError.refusedPath) { _ = try await client.today(date: bad) }
    }
    #expect(transport.requests.isEmpty)
    await #expect(throws: APIError.notFound) { _ = try await client.today(date: "2026-11-12") }
  }

  @Test("TODAYAPI: the opportunity routes: GET ?state=open, GET /{id}, POST /{id}/answer with answer and option_id")
  func opportunityRequests() async throws {
    let transport = RecordingTransport(replies: [
      .json(200, "[" + M311TodayJSON.opportunity + #",{"broken":true}]"#),
      .json(200, M311TodayJSON.opportunity),
      .json(200, #"{"id":"opp_1","title":"","state":"chosen"}"#),
    ])
    let builds = HTTPBuildsClient(core: APIClientCore(config: M311Backends.config, transport: transport))
    let open = try await builds.openOpportunities()
    #expect(open.map(\.id) == ["opp_1"])
    let one = try await builds.opportunity(id: "opp_1")
    #expect(one.options.count == 2)
    let answered = try await builds.answerOpportunity(id: "opp_1", answer: .build, optionID: "fix_1")
    #expect(answered.state == .chosen)
    let r = transport.requests
    #expect(r.map(\.httpMethod) == ["GET", "GET", "POST"])
    #expect(r.map { $0.url?.absoluteString ?? "" } == [
      "https://api.example.test/v1/opportunities?state=open",
      "https://api.example.test/v1/opportunities/opp_1",
      "https://api.example.test/v1/opportunities/opp_1/answer",
    ])
    #expect(String(decoding: r[2].httpBody ?? Data(), as: UTF8.self) == #"{"answer":"build","option_id":"fix_1"}"#)
    #expect(r[2].value(forHTTPHeaderField: "Idempotency-Key") != nil)
    #expect(r[2].value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
    #expect(Set(OpportunityAnswer.allCases.map(\.rawValue)) == ["build", "not_now", "never", "leave_alone"])
  }

  @Test("TODAYAPI: the Today client exists only over the HTTP brain in .cloud; .local has none")
  func todayClientFrom() {
    #expect(HTTPTodayClient.from(Backends.make(mode: .cloud(M311Backends.config), transport: RecordingTransport())) != nil)
    #expect(HTTPTodayClient.from(.local) == nil)
    #expect(HTTPTodayClient.from(M311Backends.cloud()) == nil)
  }

  @Test("TODAYAPI: the flag is off until the server's GET /v1/today lands, so a .cloud model shows the sample")
  @MainActor func todayFlagDefault() async {
    #expect(TodayAPI.available == false)
    let brain = M311Brain()
    let app = M311Kit().app(backends: M311Backends.cloud(brain: brain))
    let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {})
    await model.refresh(force: true)
    #expect(model.isSample)
    #expect(model.ready?.provenance == .sample)
    #expect(brain.dayCalls.isEmpty)
  }

  // MARK: Flag on

  @MainActor @Test("CLOUD: with the Today API on, GET /v1/today fills the grid, What you did, the repeats and the card")
  func cloudTodayFills() async throws {
    let brain = M311Brain()
    let builds = M311Builds()
    let today = M311Today()
    let (model, _) = M311Kit.cloudModel(brain: brain, builds: builds, today: today)
    await model.refresh(force: true)
    #expect(brain.dayCalls == ["2026-11-12"])
    #expect(today.calls == ["2026-11-12"])
    #expect(brain.weekCalls.isEmpty)
    #expect(builds.calls == 0)
    let c = try #require(model.ready)
    #expect(c.headline == "7 h 40 m of work.")
    #expect(c.grid?.rows.map(\.name) == ["Coding", "Docs", "Email"])
    #expect(c.kinds.isEmpty)
    #expect(c.did.map(\.name) == ["Reconcile invoices", "Review agent PRs"])
    #expect(c.did.map(\.start) == ["9:00a", "1:05p"])
    #expect(c.repeats.map(\.name) == ["Review agent PRs", "Reconcile invoices", "Customer follow-up"])
    #expect(c.repeats.first?.count == "6× · 3.1 h")
    #expect(c.fix?.source == .opportunity(id: "opp_1"))
    #expect(c.fix?.how == "how: Mon 1 + Tue 1 + Wed 2 + Thu 2 = 6")
    #expect(c.provenance == .cloud)
    #expect(!model.isSample)
  }

  @Test("GRID: the cloud grid comes from day_grid: whole hours around the cells, one row per kind in its colour, bursts")
  func gridCloud() throws {
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), payload: try M311TodayJSON.payload(), rhythm: nil,
                                            today: M311Clock.today, timeZone: M311Clock.utc))
    let g = try #require(c.grid)
    // 9:00 to 18:00 by default, widened to 7:00 for the 07:45 cell.
    #expect(g.startMinute == 7 * 60)
    #expect(g.endMinute == 18 * 60)
    #expect(g.cellCount == 44)
    #expect(g.hourLabels.first == "7a")
    #expect(g.hourLabels.last == "5p")
    #expect(g.rows.map(\.name) == ["Coding", "Docs", "Email"])
    #expect(g.rows.map(\.colorHex) == [TodayContent.kindColor("code"), TodayContent.kindColor("docs"), TodayContent.kindColor("email")])
    #expect(g.rows.map { row in row.cells.indices.filter { row.cells[$0] } } == [[8, 9], [12], [3]])
    #expect(g.bursts.indices.filter { g.bursts[$0] } == [12])
    #expect(g.rows.first?.figure?.arithmetic == "active time of 10 code spans = 200 min")
    #expect(DayGridView.label(g.rows[0]) == "Coding, 3 h 20 m")
  }

  @Test("GRID: kinds past the top 5, and cells of a kind the categories do not name, go to Other")
  func gridCloudOther() throws {
    let keys = ["code", "docs", "email", "meeting", "browse", "chat"]
    let categories = keys.enumerated().map { i, k in
      TodayGridCategory(key: k, name: nil, minutes: M311Cloud.fig(Double(60 - i), "minutes", "\(60 - i) min of \(k)"))
    }
    let cells = keys.enumerated().map { i, k in TodayGridCell(start: String(format: "%02ld:00", 9 + i), category: k) }
      + [TodayGridCell(start: "16:00", category: "mystery")]
    var p = M311Cloud.payload()
    p.dayGrid = TodayDayGridPayload(categories: categories, cells: cells, switchBursts: [])
    let g = try #require(TodayContent.cloud(day: M311Cloud.day(), payload: p, rhythm: nil, today: M311Clock.today,
                                            timeZone: M311Clock.utc)?.grid)
    #expect(g.rows.map(\.name) == ["Code", "Docs", "Email", "Meeting", "Browse", "Other"])
    #expect(g.rows.last?.colorHex == DayGrid.otherColor)
    #expect(g.rows.last.map { row in row.cells.indices.filter { row.cells[$0] } } == [20, 28])
  }

  @Test("DID: cloud start times read as the hour axis; a malformed one shows no time")
  func didCloudClock() {
    #expect(TodayCopy.clock(hhmm: "09:00") == "9:00a")
    #expect(TodayCopy.clock(hhmm: "13:05") == "1:05p")
    #expect(TodayCopy.clock(hhmm: "00:30") == "12:30a")
    #expect(TodayCopy.clock(hhmm: "9am") == nil)
  }

  @MainActor @Test("CLOUD: a suggested fix sent without options is read whole from GET /v1/opportunities/{id}")
  func cloudFixReadWhole() async throws {
    let full = try JSONDecoder().decode(Opportunity.self, from: Data(M311TodayJSON.opportunity.utf8))
    let builds = M311Builds(full: ["opp_1": full])
    let today = M311Today { _ in
      var p = try M311TodayJSON.payload()
      p.suggestedFix?.options = []
      return p
    }
    let (model, _) = M311Kit.cloudModel(builds: builds, today: today)
    await model.refresh(force: true)
    #expect(builds.opportunityCalls == ["opp_1"])
    #expect(model.ready?.fix?.options.map(\.id) == ["fix_1", "fix_2", "leave_alone"])
  }

  @MainActor @Test("CLOUD: a 404 from GET /v1/today is Nothing recorded for this day yet.; another failure says why")
  func cloudTodayFailures() async {
    let today = M311Today { _ in throw APIError.notFound }
    let (model, _) = M311Kit.cloudModel(today: today)
    await model.refresh(force: true)
    #expect(model.state == .notRecorded("2026-11-12"))
    #expect(model.content == nil)
    today.set { _ in throw APIError.transport(code: URLError.Code.notConnectedToInternet.rawValue) }
    await model.refresh(force: true)
    #expect(model.state == .failed(.offline))
    #expect(model.content == nil)
  }

  @Test("FIX: a suggested fix that is no longer open is not drawn")
  func fixCloudNotOpen() throws {
    var p = try M311TodayJSON.payload()
    p.suggestedFix?.state = .chosen
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), payload: p, rhythm: nil, today: M311Clock.today,
                                            timeZone: M311Clock.utc))
    #expect(c.fix == nil)
  }

  @Test("FIGURES: every number from GET /v1/today traces to a Figure with arithmetic and evidence")
  func figuresToday() throws {
    let c = try #require(TodayContent.cloud(day: M311Cloud.day(), payload: try M311TodayJSON.payload(), rhythm: nil,
                                            today: M311Clock.today, timeZone: M311Clock.utc))
    #expect(c.figures.count > 10)
    for f in c.figures {
      #expect(!f.arithmetic.isEmpty)
      #expect(!f.evidence.isEmpty)
    }
    for row in c.grid?.rows ?? [] { #expect(row.figure.map { c.figures.contains($0) } == true) }
    for row in c.did { #expect(c.figures.contains(row.figure)) }
    for r in c.repeats { #expect(c.figures.contains(r.times) && c.figures.contains(r.minutes)) }
    #expect(TodayCopy.minutes(of: M311Cloud.fig(200, "minutes", "x")) == 200)
    #expect(TodayCopy.minutes(of: Figure.local(5400, unit: "seconds", arithmetic: "x", evidence: [])) == 90)
    #expect(TodayCopy.minutes(of: M311Cloud.fig(1.5, "hours", "x")) == 90)
  }

  // MARK: Answers

  @MainActor @Test("ANSWER: round trip over HTTP: Not now posts the answer, then the next open opportunity by rank takes the card")
  func answerRoundTrip() async throws {
    let day = try JSONEncoder().encode(M311Cloud.day())
    let next = try JSONEncoder().encode([M311Cloud.opportunity("opp_3", rank: 3), M311Cloud.opportunity("opp_2", rank: 2)])
    let transport = RecordingTransport(replies: [
      .status(200, body: day),
      .json(200, M311TodayJSON.full),
      .json(200, #"{"id":"opp_1","title":"","state":"not_now"}"#),
      .status(200, body: next),
    ])
    let app = M311Kit().app(backends: Backends.make(mode: .cloud(M311Backends.config), transport: transport))
    let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {}, todayAPI: true)
    await model.refresh(force: true)
    #expect(model.ready?.fix?.source == .opportunity(id: "opp_1"))
    await model.notNow()
    let r = transport.requests
    #expect(r.map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "")" } == [
      "GET https://api.example.test/v1/records/days/2026-11-12",
      "GET https://api.example.test/v1/today?date=2026-11-12",
      "POST https://api.example.test/v1/opportunities/opp_1/answer",
      "GET https://api.example.test/v1/opportunities?state=open",
    ])
    #expect(String(decoding: r[2].httpBody ?? Data(), as: UTF8.self) == #"{"answer":"not_now"}"#)
    #expect(model.answerError == nil)
    #expect(model.ready?.fix?.source == .opportunity(id: "opp_2"))
  }

  @MainActor @Test("ANSWER: an answered opportunity is not drawn again when a later read still suggests it")
  func answerStaysAnswered() async {
    let builds = M311Builds(open: [])
    let now = M311Now()
    let (model, _) = M311Kit.cloudModel(builds: builds, now: now)
    await model.refresh(force: true)
    await model.notNow()
    #expect(builds.answers.map(\.0) == ["opp_1"])
    #expect(model.ready?.fix == nil)
    now.advance(61)
    await model.tick()
    #expect(model.ready != nil)
    #expect(model.ready?.fix == nil)
  }

  // MARK: Flag off: the labelled sample

  @MainActor @Test("STATES: with the Today API off, .cloud shows the labelled sample and sends no request")
  func sampleNoRequests() async {
    let brain = M311Brain()
    let builds = M311Builds()
    let today = M311Today()
    let (model, _) = M311Kit.cloudModel(brain: brain, builds: builds, today: today, todayAPI: false)
    await model.refresh(force: true)
    await model.tick()
    await model.previousDay()
    await model.tryAgain()
    await model.menuTick()
    #expect(brain.dayCalls.isEmpty)
    #expect(brain.weekCalls.isEmpty)
    #expect(today.calls.isEmpty)
    #expect(builds.calls == 0)
    #expect(model.isSample)
    #expect(model.ready?.provenance == .sample)
    #expect(model.ready?.grid != nil)
    #expect(model.ready?.fix != nil)
    #expect(model.day == M311Clock.today)
    #expect(!model.canGoBack && !model.canGoForward)
    #expect(TodayCopy.sampleTodayAPI == "Sample data: Today API not live yet")
  }

  @MainActor @Test("STATES: sample numbers never pass for real ones: each Figure says sample, the card says so, the menu has no line")
  func sampleNeverReal() async throws {
    let (model, _) = M311Kit.cloudModel(todayAPI: false)
    await model.refresh(force: true)
    let c = try #require(model.ready)
    #expect(!c.figures.isEmpty)
    for f in c.figures {
      #expect(f.arithmetic.hasPrefix("sample: "), "not marked: \(f.arithmetic)")
      #expect(f.evidence.allSatisfy { $0.kind == "sample" }, "evidence: \(f.arithmetic)")
    }
    #expect(c.fix?.status == TodayCopy.sampleFixStatus)
    #expect(c.fix?.isSample == true)
    await model.menuTick()
    #expect(model.menuLine == nil)
  }

  @MainActor @Test("STATES: the sample's buttons and keys do nothing: no answer is posted, nothing goes to Build progress")
  func sampleInert() async {
    let builds = M311Builds()
    let (model, app) = M311Kit.cloudModel(builds: builds, todayAPI: false)
    await model.refresh(force: true)
    model.cardFocused = true
    #expect(!model.accepts(.return))
    #expect(!model.accepts(.digit(1)))
    #expect(await model.handleKey(.return) == false)
    model.okBuild()
    await model.pressPrimary()
    await model.notNow()
    await model.leaveAlone()
    #expect(builds.answers.isEmpty)
    #expect(app.navigation.pendingBuild == nil)
    #expect(app.navigation.selection == .today)
    #expect(model.ready?.fix != nil)
  }

  @MainActor @Test("STATES: .local keeps local insights whatever the flag says")
  func localIgnoresFlag() async {
    for flag in [false, true] {
      let insights = InsightsModel.empty(timeZone: M311Clock.utc)
      insights.publish(M311Fixture.snapshot([M311Fixture.workday]))
      let today = M311Today()
      let app = M311Kit().app(insights: insights)
      let model = TodayLiveModel(app: app, now: M311Now().clock, reloadRanking: {}, todayAPI: flag, todayClient: today)
      await model.refresh(force: true)
      #expect(model.ready?.provenance == .onDevice)
      #expect(!model.isSample)
      #expect(today.calls.isEmpty)
    }
  }

  @Test("COPY: the sample label and the sample card's status are Today's strings and follow the caption rules")
  func copySample() {
    #expect(TodayCopy.all.contains(TodayCopy.sampleTodayAPI))
    #expect(TodayCopy.all.contains(TodayCopy.sampleFixStatus))
    #expect(TodayCopy.captions.contains(TodayCopy.sampleFixStatus))
    #expect(TodayCopy.sampleTodayAPI.hasPrefix("Sample data: "))
  }
}
