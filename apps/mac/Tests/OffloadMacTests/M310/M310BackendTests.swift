import Foundation
import Testing
@testable import OffloadMac

// Backend mode, the brain and builds clients, and the host rules (SPEC m3-10 red tests BACKEND, BRAIN, BUILDS,
// HOST). Every request goes to a RecordingTransport; no test touches the network. Fixtures were produced by the brain
// port (figure(), buildWeekRecord, buildWeekReview, parseReviewAnswer, defaultProfile) and the build-loop port
// (buildView), with an unknown field added here and there to prove unknown fields are ignored.
extension M310 {
  // MARK: BACKEND

  @Test("BACKEND: local by default; with no member token even an https base URL stays local")
  func backendLocalByDefault() {
    #expect(Backends.local.mode == .local)
    #expect(Backends.local.mode.isLocal)
    #expect(BackendMode.resolve(baseURL: nil, tokens: NoMemberToken()) == .local)
    #expect(BackendMode.resolve(baseURL: "https://api.example.test", tokens: NoMemberToken()) == .local)
    #expect(NoMemberToken().currentToken() == nil)
    #expect(BackendMode.baseURLDefaultsKey == "ai.offload.api.baseURL")
  }

  @Test("BACKEND: cloud only with an https base URL with a host and a token")
  func backendCloudNeedsHTTPSAndToken() {
    let mode = BackendMode.resolve(baseURL: " https://api.example.test ", tokens: M310BToken(token: M310B.token))
    #expect(!mode.isLocal)
    guard case .cloud(let config) = mode else {
      Issue.record("expected cloud mode")
      return
    }
    #expect(config.baseURL.absoluteString == "https://api.example.test")
    #expect(config.tokens.currentToken() == M310B.token)
    #expect(mode == .cloud(BackendConfig(baseURL: M310B.base, tokens: NoMemberToken())))
  }

  @Test("BACKEND: http, a missing or empty URL, a URL without a host or with credentials, or an empty token stay local")
  func backendStaysLocal() {
    let token = M310BToken(token: M310B.token)
    for raw in ["http://api.example.test", "", "   ", "https://", "ftp://api.example.test", "api.example.test",
                "https://user:pw@api.example.test", "https://api.example.test/?x=1", "https://api.example.test/#f"] {
      #expect(BackendMode.resolve(baseURL: raw, tokens: token) == .local, "\(raw)")
    }
    #expect(BackendMode.resolve(baseURL: "https://api.example.test", tokens: M310BToken(token: "")) == .local)
    #expect(BackendMode.resolve(baseURL: "https://api.example.test", tokens: M310BToken(token: "  ")) == .local)
    #expect(BackendMode.resolve(baseURL: "https://api.example.test", tokens: M310BToken(token: nil)) == .local)
  }

  @Test("BACKEND: the base URL is read from UserDefaults under ai.offload.api.baseURL")
  func backendReadsDefaults() {
    let suite = "m310b.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      Issue.record("no defaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let token = M310BToken(token: M310B.token)
    #expect(BackendMode.resolve(defaults: defaults, tokens: token) == .local)
    defaults.set("https://api.example.test", forKey: BackendMode.baseURLDefaultsKey)
    #expect(BackendMode.resolve(defaults: defaults, tokens: token) == .cloud(BackendConfig(baseURL: M310B.base, tokens: token)))
    defaults.set("http://api.example.test", forKey: BackendMode.baseURLDefaultsKey)
    #expect(BackendMode.resolve(defaults: defaults, tokens: token) == .local)
  }

  @Test("BACKEND: local builds no clients, so no request can be built; provenance is on device")
  func backendLocalBuildsNoClients() {
    let transport = RecordingTransport()
    let backends = Backends.make(mode: .local, transport: transport, signer: M310BSigner())
    #expect(backends.mode == .local)
    #expect(backends.brain == nil)
    #expect(backends.builds == nil)
    #expect(backends.provenance == .onDevice)
    #expect(transport.requests.isEmpty)
  }

  @Test("BACKEND: cloud builds both HTTP clients and provenance follows the mode")
  func backendCloudBuildsClients() async {
    let transport = RecordingTransport()
    let mode = BackendMode.resolve(baseURL: "https://api.example.test", tokens: M310BToken(token: M310B.token))
    let backends = Backends.make(mode: mode, transport: transport)
    #expect(backends.mode == mode)
    #expect(backends.provenance == .cloud)
    #expect(backends.brain != nil)
    #expect(backends.builds != nil)
    #expect(backends.brain is HTTPBrainClient)
    #expect(backends.builds is HTTPBuildsClient)
    if let brain = backends.brain {
      _ = await M310B.error { try await brain.profile() }
    }
    #expect(transport.requests.map { $0.url?.absoluteString } == ["https://api.example.test/v1/profile"])
  }

  // MARK: BRAIN

  @Test("BRAIN: GET /v1/profile with the bearer token and Accept, no body; the port's defaultProfile decodes")
  func brainProfileGet() async throws {
    let transport = RecordingTransport(replies: [.json(200, M310BFixtures.profile)])
    let profile = try await M310B.brain(transport).profile()
    let req = try #require(transport.requests.first)
    #expect(transport.requests.count == 1)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/profile")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(M310B.token)")
    #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == nil)
    #expect(req.value(forHTTPHeaderField: "Idempotency-Key") == nil)
    #expect(req.value(forHTTPHeaderField: "Offload-Signature") == nil)
    #expect(req.httpBody == nil)
    #expect(profile == BrainProfile.defaults)
    #expect(profile.timezone == "UTC")
    #expect(profile.reviewSlot == BrainReviewSlot(day: "fri", time: "16:00"))
    #expect(profile.autonomy == "suggest")
    #expect(profile.ownNameToModels == "mask")
    #expect(!profile.keyframesToCloud)
  }

  @Test("BRAIN: a profile with fields left out takes the brain's defaultProfile values; unknown fields are ignored")
  func brainProfileDefaults() async throws {
    let json = #"{"version":3,"role":"Founder","goals":[{"id":"g_a41535a1d6","text":"Ship the Mac app","horizon":"90d","created_at":"2026-11-22T12:00:00.000Z","archived_at":null}],"drains":["email","context_switching"],"schedule":{"days":["mon","tue"],"start":"09:00","end":"17:30"},"x_unknown_field":{"a":1}}"#
    let transport = RecordingTransport(replies: [.json(200, json)])
    let profile = try await M310B.brain(transport).profile()
    #expect(profile.version == 3)
    #expect(profile.role == "Founder")
    #expect(profile.industry == nil)
    #expect(profile.goals == [BrainGoal(id: "g_a41535a1d6", text: "Ship the Mac app", createdAt: "2026-11-22T12:00:00.000Z")])
    #expect(profile.drains == ["email", "context_switching"])
    #expect(profile.schedule == BrainSchedule(days: ["mon", "tue"], start: "09:00", end: "17:30"))
    #expect(profile.timezone == "UTC")
    #expect(profile.reviewSlot == BrainReviewSlot(day: "fri", time: "16:00"))
    #expect(profile.autonomy == "suggest")
    #expect(profile.ownNameToModels == "mask")
    #expect(profile.keyframesToCloud == false)
    #expect(profile.learningPaused == false)
    #expect(profile.updatedAt == nil)
  }

  @Test("BRAIN: PATCH /v1/profile sends only the keys set, as JCS bytes; only the brain's PATCHABLE keys exist")
  func brainProfilePatch() async throws {
    #expect(BrainProfilePatch.patchableKeys == ["role", "industry", "goals", "drains", "schedule", "timezone",
                                                "review_slot", "autonomy", "own_name_to_models", "keyframes_to_cloud"])
    var patch = BrainProfilePatch()
    #expect(patch.isEmpty)
    patch.setRole("Founder")
    patch.setDrains(["email", "meetings"])
    patch.setKeyframesToCloud(false)
    let transport = RecordingTransport(replies: [.json(200, M310BFixtures.profile)])
    _ = try await M310B.brain(transport).updateProfile(patch)
    let req = try #require(transport.requests.first)
    #expect(req.httpMethod == "PATCH")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/profile")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
    #expect(req.value(forHTTPHeaderField: "Idempotency-Key") == nil)
    #expect(M310B.body(req) == #"{"drains":["email","meetings"],"keyframes_to_cloud":false,"role":"Founder"}"#)

    var all = BrainProfilePatch()
    all.setRole(nil)
    all.setIndustry("Finance")
    all.setGoals(["Ship the Mac app"])
    all.setDrains([])
    all.setSchedule(nil)
    all.setTimezone("Europe/Berlin")
    all.setReviewSlot(BrainReviewSlot(day: "mon", time: "09:30"))
    all.setAutonomy("draft")
    all.setOwnNameToModels("keep")
    all.setKeyframesToCloud(true)
    #expect(Set(all.fields.keys) == Set(BrainProfilePatch.patchableKeys))
    let text = try JCS.string(all.body)
    #expect(text == #"{"autonomy":"draft","drains":[],"goals":["Ship the Mac app"],"industry":"Finance","keyframes_to_cloud":true,"own_name_to_models":"keep","review_slot":{"day":"mon","time":"09:30"},"role":null,"schedule":null,"timezone":"Europe/Berlin"}"#)
  }

  @Test("BRAIN: GET /v1/records/days/2026-11-20 decodes the port's DayRecord, every Figure intact")
  func brainDayRecord() async throws {
    let transport = RecordingTransport(replies: [.json(200, M310BFixtures.day)])
    let day = try await M310B.brain(transport).dayRecord(day: "2026-11-20")
    let req = try #require(transport.requests.first)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/records/days/2026-11-20")
    #expect(day.day == "2026-11-20")
    #expect(day.generatedAt == "2026-11-21T05:00:00.000Z")
    #expect(day.totals.activeMinutes.id == "fig_5c45b37d492459da")
    #expect(day.totals.activeMinutes.value == 312.5)
    #expect(day.totals.activeMinutes.unit == "minutes")
    #expect(day.totals.activeMinutes.arithmetic == "sum of 41 spans' active time, idle removed = 312.5 min")
    #expect(day.totals.activeMinutes.evidence == [EvidenceRef(kind: "observation", id: "01JCA0000000000000000000A1")])
    #expect(day.totals.activeMinutes.sourcePurgedAt == nil)
    #expect(day.totals.switches.value == 57)
    #expect(day.totals.switchesPerActiveHour.value == 10.9)
    #expect(day.totals.switchesPerActiveHour.evidence.isEmpty)
    #expect(day.totals.focusBlocks.value == 2)
    #expect(day.totals.focusMinutes.value == 71)
    #expect(day.totals.meetingMinutes.value == 45)
    #expect(day.byKind.map(\.kind) == ["build"])
    #expect(day.byApp.map(\.app) == ["com.apple.dt.Xcode"])
    #expect(day.byApp.first?.minutes.value == 120)
    #expect(day.byTask.count == 1)
    #expect(day.byTask.first?.taskKey == "k_0123456789ab")
    #expect(day.byTask.first?.name == "Reconcile invoices")
    #expect(day.byTask.first?.instances.value == 3)
    #expect(day.byTask.first?.medianMinutes.value == 21)
    #expect(day.episodeIDs == ["ep_fb_0123456789ab", "ep_i1"])
    #expect(day.sourcePurgedAt == nil)
  }

  @Test("BRAIN: GET /v1/records/weeks/2026-W47 decodes the port's WeekRecord")
  func brainWeekRecord() async throws {
    let transport = RecordingTransport(replies: [.json(200, M310BFixtures.week)])
    let week = try await M310B.brain(transport).weekRecord(isoWeek: "2026-W47")
    let req = try #require(transport.requests.first)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/records/weeks/2026-W47")
    #expect(week.isoWeek == "2026-W47")
    #expect(week.from == "2026-11-16")
    #expect(week.to == "2026-11-22")
    #expect(week.daysRecorded == ["2026-11-20"])
    #expect(week.hours.total.value == 5.21)
    #expect(week.hours.total.unit == "hours")
    #expect(week.hours.total.evidence == [EvidenceRef(kind: "day_record", id: "2026-11-20")])
    #expect(week.hours.byKind.first?.kind == "build")
    #expect(week.hours.byApp.first?.app == "com.apple.dt.Xcode")
    #expect(week.focus.blocks.value == 2)
    #expect(week.focus.minutes.value == 71)
    #expect(week.focus.switchesPerActiveHour.value == 10.9)
    #expect(week.focus.meetingHours.value == 0.75)
    #expect(week.tasks.count == 1)
    let task = try #require(week.tasks.first)
    #expect(task.taskKey == "k_0123456789ab")
    #expect(task.minutes.value == 62)
    #expect(task.instances.value == 3)
    #expect(task.medianMinutes.value == 21)
    #expect(task.baselineMinutes == nil)
    #expect(task.vsBaseline == nil)
    #expect(task.status == .new)
    #expect(week.fixes.estimated.isEmpty)
    #expect(week.fixes.measured.isEmpty)
    #expect(week.weeksObserved == 3)
    #expect(week.narrative == nil)
    #expect(week.generatedAt == "2026-11-22T12:00:00.000Z")
    #expect(WeekTaskStatus(raw: "gone") == .gone)
    #expect(WeekTaskStatus(raw: "vanished") == .unknown("vanished"))
  }

  @Test("BRAIN: GET /v1/review/week?w=2026-W47 decodes the port's WeekReview with four tiles and its question")
  func brainWeekReview() async throws {
    let transport = RecordingTransport(replies: [.json(200, M310BFixtures.review)])
    let review = try await M310B.brain(transport).weekReview(isoWeek: "2026-W47")
    let req = try #require(transport.requests.first)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/review/week?w=2026-W47")
    #expect(review.isoWeek == "2026-W47")
    #expect(review.sentence == "You worked 5.21 h this week: 71 min in focus blocks and 0.75 h in meetings.")
    #expect(review.tiles.map(\.value) == [5.21, 71, 0.75, 10.9])
    #expect(review.tiles.map(\.unit) == ["hours", "minutes", "hours", "per_hour"])
    #expect(review.goals == [ReviewGoal(id: "g_a41535a1d6", text: "Ship the Mac app")])
    #expect(review.questions.count == 1)
    let q = try #require(review.questions.first)
    #expect(q.subjectKey == "k_0123456789ab")
    #expect(q.questionKind == "opportunity")
    #expect(q.name == "Reconcile invoices")
    #expect(q.answers == ReviewAnswerKind.opportunityAnswers)
    #expect(q.answered == .keep)
  }

  @Test("BRAIN: POST /v1/review/answers body is exactly the JCS bytes, goal_id left out when nil, with an Idempotency-Key")
  func brainAnswer() async throws {
    let transport = RecordingTransport(replies: [.json(200, M310BFixtures.answer), .json(200, M310BFixtures.answer)])
    let client = M310B.brain(transport)
    let first = try await client.answer(ReviewAnswerRequest(isoWeek: "2026-W47", subjectKey: "k_0123456789ab", answer: .notNow))
    _ = try await client.answer(ReviewAnswerRequest(isoWeek: "2026-W47", subjectKey: "k_0123456789ab", answer: .keep, goalID: "g_a41535a1d6"))
    #expect(transport.requests.count == 2)
    let one = transport.requests[0]
    let two = transport.requests[1]
    #expect(one.httpMethod == "POST")
    #expect(one.url?.absoluteString == "https://api.example.test/v1/review/answers")
    #expect(M310B.body(one) == #"{"answer":"not_now","iso_week":"2026-W47","question_kind":"opportunity","subject_key":"k_0123456789ab"}"#)
    #expect(M310B.body(two) == #"{"answer":"keep","goal_id":"g_a41535a1d6","iso_week":"2026-W47","question_kind":"opportunity","subject_key":"k_0123456789ab"}"#)
    #expect(one.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
    #expect(M310B.isULID(one.value(forHTTPHeaderField: "Idempotency-Key")))
    #expect(M310B.isULID(two.value(forHTTPHeaderField: "Idempotency-Key")))
    #expect(one.value(forHTTPHeaderField: "Idempotency-Key") != two.value(forHTTPHeaderField: "Idempotency-Key"))
    #expect(one.value(forHTTPHeaderField: "Offload-Signature") == nil)
    #expect(first == ReviewAnswer(isoWeek: "2026-W47", subjectKey: "k_0123456789ab", answer: .keep,
                                  goalID: "g_a41535a1d6", answeredAt: "2026-11-22T12:00:00.000Z"))
  }

  @Test("BRAIN: every brain answer word decodes; an unknown one decodes as unknown")
  func brainAnswerKinds() throws {
    let words = ["keep", "not_now", "build", "never", "leave_alone", "other_goal", "yes", "no", "confirm_name", "dont_track", "undo"]
    for w in words {
      let kind = ReviewAnswerKind(raw: w)
      #expect(kind.raw == w)
      #expect(kind != .unknown(w))
    }
    let decoded = try JSONDecoder().decode([ReviewAnswerKind].self, from: Data(#"["leave_alone","maybe_later"]"#.utf8))
    #expect(decoded == [.leaveAlone, .unknown("maybe_later")])
    #expect(ReviewAnswerKind.goalAnswers == [.keep, .build, .otherGoal])
  }

  @Test("BRAIN: 404 on a week record or review is notFound (a future week), not an error screen")
  func brainNotFound() async {
    let envelope = #"{"error":{"code":"not_found","message":"that week has not happened yet","request_id":"req_01JCA0000000000000000000A1"}}"#
    let transport = RecordingTransport(replies: [.json(404, envelope), .json(404, envelope), .json(404, "")])
    let client = M310B.brain(transport)
    let week = await M310B.error { try await client.weekRecord(isoWeek: "2026-W52") }
    let review = await M310B.error { try await client.weekReview(isoWeek: "2026-W52") }
    let day = await M310B.error { try await client.dayRecord(day: "2026-12-30") }
    #expect(week == .notFound)
    #expect(review == .notFound)
    #expect(day == .notFound)
    #expect(week?.code == .notFound)
  }

  @Test("BRAIN: error envelope codes decode with message, request id and rule id; an unknown code is other")
  func brainErrorEnvelope() async {
    let transport = RecordingTransport(replies: [
      .json(400, #"{"error":{"code":"schema_invalid","message":"goals repeat","request_id":"req_01JCA0000000000000000000B1"}}"#),
      .json(403, #"{"error":{"code":"policy_denied","message":"paused in quiet hours","request_id":"req_01JCA0000000000000000000B2","rule_id":"core.commit.quiet_hours"}}"#),
      .json(418, #"{"error":{"code":"teapot_brewing","message":"later","request_id":"req_01JCA0000000000000000000B3","x_unknown":1}}"#),
      .json(500, "not json"),
    ])
    let client = M310B.brain(transport)
    var patch = BrainProfilePatch()
    patch.setGoals(["A", "a"])
    let one = await M310B.error { try await client.updateProfile(patch) }
    let two = await M310B.error { try await client.profile() }
    let three = await M310B.error { try await client.profile() }
    let four = await M310B.error { try await client.profile() }
    #expect(one == .server(status: 400, code: .schemaInvalid, message: "goals repeat",
                           requestID: "req_01JCA0000000000000000000B1", ruleID: nil))
    #expect(two == .server(status: 403, code: .policyDenied, message: "paused in quiet hours",
                           requestID: "req_01JCA0000000000000000000B2", ruleID: "core.commit.quiet_hours"))
    #expect(three == .server(status: 418, code: .other("teapot_brewing"), message: "later",
                             requestID: "req_01JCA0000000000000000000B3", ruleID: nil))
    #expect(four == .badResponse(status: 500))
    let all = ["invalid_request", "unknown_kind", "schema_invalid", "clock_skew", "unauthenticated", "token_expired",
               "forbidden", "policy_denied", "feature_not_licensed", "hash_mismatch", "consent_missing", "not_found",
               "already_running", "approval_used", "approval_expired", "idempotency_conflict", "seq_replay",
               "nonce_used", "last_owner", "state_conflict", "stale_notice", "too_large", "leak_detected",
               "teeth_gate_failed", "budget_exceeded", "recipient_not_allowed", "rate_limited", "server_error"]
    for code in all {
      let parsed = APIErrorCode(raw: code)
      #expect(parsed.raw == code)
      #expect(parsed != .other(code), "\(code) is in the closed list")
    }
  }

  @Test("BRAIN: a malformed day or week is refused before any request is built")
  func brainRefusesBadDates() async {
    let transport = RecordingTransport()
    let client = M310B.brain(transport)
    for day in ["2026-11-2", "20261120", "2026-11-20/..", "2026-11-20?x=1", ""] {
      let e = await M310B.error { try await client.dayRecord(day: day) }
      #expect(e == .refusedPath, "\(day)")
    }
    for week in ["2026-W4", "2026-w47", "2026-W47/../profile", "2026-W47&w=2026-W48"] {
      let record = await M310B.error { try await client.weekRecord(isoWeek: week) }
      let review = await M310B.error { try await client.weekReview(isoWeek: week) }
      #expect(record == .refusedPath, "\(week)")
      #expect(review == .refusedPath, "\(week)")
    }
    #expect(transport.requests.isEmpty)
  }

  // MARK: BUILDS

  @Test("BUILDS: GET /v1/opportunities?state=open decodes options, factors, goal and unknown states; unreadable items are skipped")
  func buildsOpenOpportunities() async throws {
    let transport = RecordingTransport(replies: [.json(200, M310BFixtures.opportunities)])
    let list = try await M310B.builds(transport).openOpportunities()
    let req = try #require(transport.requests.first)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/opportunities?state=open")
    #expect(req.httpBody == nil)
    #expect(list.map(\.id) == ["opp_1", "opp_2"])
    let opp = list[0]
    #expect(opp.source == "finder")
    #expect(opp.taskKey == "k_0123456789ab")
    #expect(opp.title == "Reconcile invoices")
    #expect(opp.description == "Match the bank export to the invoices")
    #expect(opp.isoWeek == "2026-W47")
    #expect(opp.rank == 1)
    #expect(opp.state == .open)
    #expect(Set(opp.factors.keys) == ["weekly_hours_saved", "persistence"])
    #expect(opp.factors["weekly_hours_saved"]?.value == 3.1)
    #expect(opp.factors["weekly_hours_saved"]?.id == "fig_2b12a316e5ba76f5")
    #expect(opp.factors["persistence"]?.unit == "ratio")
    #expect(opp.options.map(\.id) == ["fix_1", "fix_2"])
    #expect(opp.options[0].optionNo == 1)
    #expect(opp.options[0].recommended)
    #expect(opp.options[0].kind == "routine")
    #expect(opp.options[0].detail == "Runs every Monday and asks before it sends")
    #expect(opp.options[0].estimate?.value == 2.5)
    #expect(opp.options[1].recommended == false)
    #expect(opp.options[1].estimate == nil)
    #expect(opp.missingConnections.isEmpty)
    #expect(opp.goal == OpportunityGoal(id: "g_a41535a1d6", text: "Ship the Mac app"))
    let second = list[1]
    #expect(second.state == .unknown("waiting_on_moon"))
    #expect(second.factors.isEmpty)
    #expect(second.options.isEmpty)
    #expect(second.missingConnections == ["google_sheets"])
    #expect(second.goal == nil)
    #expect(OpportunityState(raw: "needs_connection") == .needsConnection)
    #expect(OpportunityState(raw: "left_alone").raw == "left_alone")
  }

  @Test("BUILDS: GET /v1/opportunities/{id} and POST its answer with option_id only when given")
  func buildsOpportunityAnswer() async throws {
    let one = #"{"id":"opp_1","source":"finder","title":"Reconcile invoices","state":"chosen"}"#
    let transport = RecordingTransport(replies: [.json(200, one), .json(200, one), .json(200, one)])
    let client = M310B.builds(transport)
    let read = try await client.opportunity(id: "opp_1")
    let chosen = try await client.answerOpportunity(id: "opp_1", answer: .build, optionID: "fix_2")
    _ = try await client.answerOpportunity(id: "opp_1", answer: .leaveAlone, optionID: nil)
    #expect(read.state == .chosen)
    #expect(chosen.state == .chosen)
    let r = transport.requests
    #expect(r.count == 3)
    #expect(r[0].httpMethod == "GET")
    #expect(r[0].url?.absoluteString == "https://api.example.test/v1/opportunities/opp_1")
    #expect(r[1].httpMethod == "POST")
    #expect(r[1].url?.absoluteString == "https://api.example.test/v1/opportunities/opp_1/answer")
    #expect(M310B.body(r[1]) == #"{"answer":"build","option_id":"fix_2"}"#)
    #expect(M310B.body(r[2]) == #"{"answer":"leave_alone"}"#)
    #expect(M310B.isULID(r[1].value(forHTTPHeaderField: "Idempotency-Key")))
    #expect(r[1].value(forHTTPHeaderField: "Offload-Signature") == nil)
    #expect(OpportunityAnswer.allCases.map(\.rawValue) == ["build", "not_now", "never", "leave_alone"])
  }

  @Test("BUILDS: GET /v1/fixes/{id} decodes the brief, the four hashes, the estimate and the cap")
  func buildsFix() async throws {
    let transport = RecordingTransport(replies: [.json(200, M310BFixtures.fix)])
    let fix = try await M310B.builds(transport).fix(id: "fix_1")
    let req = try #require(transport.requests.first)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/fixes/fix_1")
    #expect(fix.id == "fix_1")
    #expect(fix.brief["title"] == .string("Weekly invoice match"))
    #expect(fix.brief["steps"] == .array([.string("read the export"), .string("match invoices")]))
    #expect(fix.briefHash == String(repeating: "1", count: 64))
    #expect(fix.checkSetHash == String(repeating: "2", count: 64))
    #expect(fix.heldOutHash == String(repeating: "3", count: 64))
    #expect(fix.fixtureSetHash == String(repeating: "4", count: 64))
    #expect(fix.estimate?.id == "fig_fe674dd6a0877984")
    #expect(fix.capUSD == 4)
    #expect(fix.hashes == FixHashes(briefHash: String(repeating: "1", count: 64), checkSetHash: String(repeating: "2", count: 64),
                                    heldOutHash: String(repeating: "3", count: 64), fixtureSetHash: String(repeating: "4", count: 64)))
  }

  @Test("BUILDS: OK, build posts exactly the JCS bytes with cap_usd 4, signed over those bytes, with an Idempotency-Key")
  func buildsOKBuild() async throws {
    let signer = M310BSigner()
    let transport = RecordingTransport(replies: [.json(202, #"{"build_id":"0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33"}"#)])
    let fix = try JSONDecoder().decode(Fix.self, from: Data(M310BFixtures.fix.utf8))
    let started = try await M310B.builds(transport, signer: signer).okBuild(fixID: "fix_1", hashes: fix.hashes)
    let req = try #require(transport.requests.first)
    let expected = #"{"brief_hash":"1111111111111111111111111111111111111111111111111111111111111111","cap_usd":4,"check_set_hash":"2222222222222222222222222222222222222222222222222222222222222222","fixture_set_hash":"4444444444444444444444444444444444444444444444444444444444444444","held_out_hash":"3333333333333333333333333333333333333333333333333333333333333333"}"#
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/fixes/fix_1/build-approvals")
    #expect(M310B.body(req) == expected)
    #expect(req.httpBody == Data(expected.utf8))
    #expect(signer.bodies == [Data(expected.utf8)])
    #expect(req.value(forHTTPHeaderField: "Offload-Signature") == M310BSigner.header)
    #expect(M310B.isULID(req.value(forHTTPHeaderField: "Idempotency-Key")))
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(M310B.token)")
    #expect(started == BuildStarted(buildID: "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33"))
  }

  @Test("BUILDS: deploy posts exactly the three hashes, signed, and decodes 201 routine_id and version")
  func buildsDeploy() async throws {
    let signer = M310BSigner()
    let transport = RecordingTransport(replies: [.json(201, #"{"routine_id":"0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a40","version":1}"#)])
    let build = try JSONDecoder().decode(Build.self, from: Data(M310BFixtures.build.utf8))
    let hashes = try #require(build.deployHashes)
    let deployed = try await M310B.builds(transport, signer: signer).deploy(id: build.id, hashes: hashes)
    let req = try #require(transport.requests.first)
    let expected = #"{"artifact_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","definition_hash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","receipt_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}"#
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/builds/0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33/deploy")
    #expect(M310B.body(req) == expected)
    #expect(signer.bodies == [Data(expected.utf8)])
    #expect(req.value(forHTTPHeaderField: "Offload-Signature") == M310BSigner.header)
    #expect(M310B.isULID(req.value(forHTTPHeaderField: "Idempotency-Key")))
    #expect(deployed == Deployed(routineID: "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a40", version: 1))
  }

  @Test("BUILDS: without a signer, OK, build and deploy are refused on this Mac and nothing is sent")
  func buildsNoSignerRefuses() async {
    let transport = RecordingTransport(fallback: .json(202, #"{"build_id":"x"}"#))
    let client = M310B.builds(transport, signer: nil)
    let hashes = FixHashes(briefHash: "1", checkSetHash: "2", heldOutHash: "3", fixtureSetHash: "4")
    let ok = await M310B.error { try await client.okBuild(fixID: "fix_1", hashes: hashes) }
    let deploy = await M310B.error {
      try await client.deploy(id: "b1", hashes: DeployHashes(artifactSHA256: "a", receiptHash: "b", definitionHash: "c"))
    }
    #expect(ok == .signingUnavailable)
    #expect(deploy == .signingUnavailable)
    #expect(transport.requests.isEmpty)
    let failing = M310B.builds(transport, signer: M310BSigner(fails: true))
    let refused = await M310B.error { try await failing.okBuild(fixID: "fix_1", hashes: hashes) }
    #expect(refused == .signingUnavailable)
    #expect(transport.requests.isEmpty)
  }

  @Test("BUILDS: the build-loop port's Build decodes every field; GET /v1/builds/{id}")
  func buildsBuildFixture() async throws {
    let transport = RecordingTransport(replies: [.json(200, M310BFixtures.build)])
    let build = try await M310B.builds(transport).build(id: "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33")
    let req = try #require(transport.requests.first)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/builds/0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33")
    #expect(build.id == "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33")
    #expect(build.state == .ready)
    #expect(build.state.isReady)
    #expect(!build.state.isLive)
    #expect(build.capUSD == 4)
    #expect(build.spentUSD == 1.875)
    #expect(build.fanoutWorkers == 3)
    #expect(build.stages == [
      BuildStage(name: "build", state: .done, startedAt: "2026-11-22T11:50:00.000Z", endedAt: "2026-11-22T11:55:00.000Z", note: nil),
      BuildStage(name: "verify", state: .done, startedAt: "2026-11-22T11:55:00.000Z", endedAt: "2026-11-22T11:59:00.000Z", note: "all checks passed"),
    ])
    #expect(build.attempts.count == 2)
    let a = build.attempts[0]
    #expect(a.id == "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a34")
    #expect(a.ordinal == 1)
    #expect(a.outcome == .pass)
    #expect(a.spentUSD == 1.25)
    #expect(a.tries == 2)
    #expect(a.turns == 14)
    #expect(a.frozenPass == true)
    #expect(a.heldOutPass == true)
    #expect(a.checkGroups == [CheckGroup(name: .frozen, passed: 12, failed: 0), CheckGroup(name: .heldOut, passed: 5, failed: 0)])
    #expect(a.artifactSHA256 == String(repeating: "a", count: 64))
    #expect(a.artifactBytes == 20480)
    #expect(a.artifactFiles == ["routine.json", "main.ts"])
    #expect(a.note == "passed")
    let b = build.attempts[1]
    #expect(b.outcome == .fail)
    #expect(b.spentUSD == 0.625)
    #expect(b.frozenPass == false)
    #expect(b.heldOutPass == nil)
    #expect(b.checkGroups == [CheckGroup(name: .frozen, passed: 10, failed: 2)])
    #expect(b.artifactSHA256 == nil)
    #expect(b.artifactBytes == 0)
    #expect(b.artifactFiles.isEmpty)
    #expect(b.note == "2 checks failed")
    #expect(build.winnerAttemptID == "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a34")
    #expect(build.artifactSHA256 == String(repeating: "a", count: 64))
    #expect(build.receiptHash == String(repeating: "b", count: 64))
    #expect(build.definitionHash == String(repeating: "c", count: 64))
    #expect(build.deployed == false)
    #expect(build.startedAt == "2026-11-22T11:50:00.000Z")
    #expect(build.endedAt == "2026-11-22T11:59:00.000Z")
  }

  @Test("BUILDS: an unknown build state, stage state, outcome or check group decodes as unknown, never as success")
  func buildsUnknownStates() throws {
    let json = #"{"id":"b1","state":"teleporting","cap_usd":4,"spent_usd":0,"fanout_workers":1,"stages":[{"name":"build","state":"paused","started_at":"2026-11-22T11:50:00.000Z","ended_at":null,"note":null}],"attempts":[{"id":"a1","ordinal":1,"outcome":"vanished","spent_usd":0,"tries":0,"turns":0,"frozen_pass":null,"held_out_pass":null,"check_groups":[{"name":"smoke","passed":1,"failed":0}],"artifact_sha256":null,"artifact_bytes":0,"artifact_files":[],"note":""}],"winner_attempt_id":null,"artifact_sha256":null,"receipt_hash":null,"definition_hash":null,"deployed":false,"started_at":null,"ended_at":null}"#
    let build = try JSONDecoder().decode(Build.self, from: Data(json.utf8))
    #expect(build.state == .unknown("teleporting"))
    #expect(!build.state.isReady)
    #expect(!build.state.isLive)
    #expect(build.stages.first?.state == .unknown("paused"))
    #expect(build.attempts.first?.outcome == .unknown("vanished"))
    #expect(build.attempts.first?.checkGroups.first?.name == .unknown("smoke"))
    #expect(build.deployHashes == nil)
    let states = ["queued", "building", "verifying", "fanning_out", "repairing", "ready", "failed", "capped", "tampered",
                  "cancelled", "infra_failed"]
    for s in states {
      #expect(BuildState(raw: s).raw == s)
      #expect(BuildState(raw: s) != .unknown(s))
    }
    #expect(BuildState(raw: "fanning_out").isLive)
    #expect(!BuildState(raw: "infra_failed").isReady)
  }

  @Test("BUILDS: 403 hash_mismatch, 409 already_running and 409 state_conflict decode")
  func buildsConflicts() async {
    let transport = RecordingTransport(replies: [
      .json(403, #"{"error":{"code":"hash_mismatch","message":"brief_hash is not this fix's current value: review it again","request_id":"req_01JCA0000000000000000000C1"}}"#),
      .json(409, #"{"error":{"code":"already_running","message":"a build of this fix is queued or running","request_id":"req_01JCA0000000000000000000C2"}}"#),
      .json(409, #"{"error":{"code":"state_conflict","message":"only a ready build can be deployed","request_id":"req_01JCA0000000000000000000C3"}}"#),
    ])
    let client = M310B.builds(transport, signer: M310BSigner())
    let hashes = FixHashes(briefHash: "1", checkSetHash: "2", heldOutHash: "3", fixtureSetHash: "4")
    let mismatch = await M310B.error { try await client.okBuild(fixID: "fix_1", hashes: hashes) }
    let running = await M310B.error { try await client.okBuild(fixID: "fix_1", hashes: hashes) }
    let conflict = await M310B.error {
      try await client.deploy(id: "b1", hashes: DeployHashes(artifactSHA256: "a", receiptHash: "b", definitionHash: "c"))
    }
    #expect(mismatch == .server(status: 403, code: .hashMismatch, message: "brief_hash is not this fix's current value: review it again",
                                requestID: "req_01JCA0000000000000000000C1", ruleID: nil))
    #expect(running?.code == .alreadyRunning)
    #expect(conflict?.code == .stateConflict)
    #expect(conflict == .server(status: 409, code: .stateConflict, message: "only a ready build can be deployed",
                                requestID: "req_01JCA0000000000000000000C3", ruleID: nil))
  }

  @Test("BUILDS: cancel, definition and outcomes use their routes; outcome numbers decode plain or as Figures")
  func buildsCancelDefinitionOutcomes() async throws {
    let transport = RecordingTransport(replies: [
      .json(200, M310BFixtures.build), .json(200, M310BFixtures.definition), .json(200, M310BFixtures.outcomes),
    ])
    let client = M310B.builds(transport)
    let cancelled = try await client.cancel(id: "b1")
    let definition = try await client.definition(id: "b1")
    let outcomes = try await client.outcomes(month: "2026-11")
    let r = transport.requests
    #expect(r.map { $0.httpMethod ?? "" } == ["POST", "GET", "GET"])
    #expect(r.map { $0.url?.absoluteString ?? "" } == [
      "https://api.example.test/v1/builds/b1/cancel",
      "https://api.example.test/v1/builds/b1/definition",
      "https://api.example.test/v1/outcomes?month=2026-11",
    ])
    #expect(r[0].httpBody == nil)
    #expect(r[0].value(forHTTPHeaderField: "Offload-Signature") == nil)
    #expect(cancelled.state == .ready)
    #expect(definition.definitionHash == String(repeating: "c", count: 64))
    #expect(definition.words == ["Every Monday at 9:00", "Reads the Finance sheet"])
    #expect(definition.definition["trigger"]?["cron"] == .string("0 9 * * 1"))
    #expect(outcomes.count == 2)
    #expect(outcomes[0].routineID == "r1")
    #expect(outcomes[0].estimatedMinutesPerWeek?.value == 150)
    #expect(outcomes[0].estimatedMinutesPerWeek?.figure?.id == "fig_6ec1c8b3dc73e45c")
    #expect(outcomes[0].baselineMinutesPerWeek == .number(120))
    #expect(outcomes[0].weeks == [.number(30), .string("source_purged"), .number(28), .null])
    #expect(outcomes[0].flag == .onTrack)
    #expect(outcomes[0].ratio?.value == 0.9)
    #expect(outcomes[1].flag == .unknown("sideways"))
    #expect(outcomes[1].shippedAt == nil)
    let bad = await M310B.error { try await client.outcomes(month: "2026-11/..") }
    #expect(bad == .refusedPath)
    #expect(transport.requests.count == 3)
  }

  @Test("BUILDS: JCS sorts keys by UTF-16 code units, writes integers without a fraction and escapes only what JSON needs")
  func buildsJCS() throws {
    let value = JSONValue.object([
      "b": .number(1),
      "a": .string("x\"\\\n\u{1}\u{1F}\té/<"),
      "c": .number(4.0),
      "d": .array([.bool(true), .null, .number(1.5), .number(-0.0), .number(0.25)]),
      "\u{E000}": .number(1),
      "\u{1F600}": .number(2),
      "e": .object(["z": .number(1), "y": .number(2)]),
    ])
    let expected = #"{"a":"x\"\\\n\u0001\u001f\té/<","b":1,"c":4,"d":[true,null,1.5,0,0.25],"e":{"y":2,"z":1},"😀":2,""#
      + "\u{E000}" + #"":1}"#
    #expect(try JCS.string(value) == expected)
    #expect(try JCS.encode(value) == Data(expected.utf8))
    #expect(throws: JCSEncodingError.self) { _ = try JCS.encode(.number(Double.nan)) }
    #expect(try JCS.number(1e-7) == "1e-7")
    #expect(try JCS.number(123456789) == "123456789")
  }

  // MARK: HOST

  @Test("HOST: every request goes to the configured host under /v1, base path kept")
  func hostEveryRequestUnderV1() async {
    let transport = RecordingTransport()
    let brain = M310B.brain(transport)
    let builds = M310B.builds(transport, signer: M310BSigner())
    _ = await M310B.error { try await brain.profile() }
    _ = await M310B.error { try await brain.updateProfile(BrainProfilePatch()) }
    _ = await M310B.error { try await brain.dayRecord(day: "2026-11-20") }
    _ = await M310B.error { try await brain.weekRecord(isoWeek: "2026-W47") }
    _ = await M310B.error { try await brain.weekReview(isoWeek: "2026-W47") }
    _ = await M310B.error { try await brain.answer(ReviewAnswerRequest(isoWeek: "2026-W47", subjectKey: "k_0123456789ab", answer: .keep)) }
    _ = await M310B.error { try await builds.openOpportunities() }
    _ = await M310B.error { try await builds.opportunity(id: "opp_1") }
    _ = await M310B.error { try await builds.answerOpportunity(id: "opp_1", answer: .never, optionID: nil) }
    _ = await M310B.error { try await builds.fix(id: "fix_1") }
    _ = await M310B.error { try await builds.okBuild(fixID: "fix_1", hashes: FixHashes(briefHash: "1", checkSetHash: "2", heldOutHash: "3", fixtureSetHash: "4")) }
    _ = await M310B.error { try await builds.build(id: "b1") }
    _ = await M310B.error { try await builds.cancel(id: "b1") }
    _ = await M310B.error { try await builds.definition(id: "b1") }
    _ = await M310B.error { try await builds.deploy(id: "b1", hashes: DeployHashes(artifactSHA256: "a", receiptHash: "b", definitionHash: "c")) }
    _ = await M310B.error { try await builds.outcomes(month: "2026-11") }
    let urls = transport.requests.compactMap(\.url)
    #expect(urls.count == 16)
    for url in urls {
      let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
      #expect(comps?.scheme == "https", "\(url)")
      #expect(comps?.host == "api.example.test", "\(url)")
      #expect(comps?.port == nil, "\(url)")
      #expect(comps?.path.hasPrefix("/v1/") == true, "\(url)")
      #expect(comps?.path.contains("..") == false, "\(url)")
    }

    let prefixed = RecordingTransport()
    let core = M310B.core(prefixed, base: URL(string: "https://api.example.test/offload/")!)
    _ = await M310B.error { try await HTTPBrainClient(core: core).profile() }
    #expect(prefixed.requests.first?.url?.absoluteString == "https://api.example.test/offload/v1/profile")
  }

  @Test("HOST: an id with a slash, dots, another host or URL syntax is refused before anything is sent")
  func hostRefusesUnsafeIDs() async {
    let transport = RecordingTransport()
    let builds = M310B.builds(transport, signer: M310BSigner())
    let unsafe = ["a/b", "..", ".", "../profile", "//other.host", "//other.host/v1/x", "x?state=all", "x#frag", "%2F", "a b",
                  "a\tb", "a:b", "https:", "", "café", String(repeating: "a", count: 129)]
    for id in unsafe {
      let fix = await M310B.error { try await builds.fix(id: id) }
      let build = await M310B.error { try await builds.build(id: id) }
      let opp = await M310B.error { try await builds.opportunity(id: id) }
      let answer = await M310B.error { try await builds.answerOpportunity(id: id, answer: .build, optionID: nil) }
      let deploy = await M310B.error {
        try await builds.deploy(id: id, hashes: DeployHashes(artifactSHA256: "a", receiptHash: "b", definitionHash: "c"))
      }
      #expect(fix == .refusedPath, "\(id)")
      #expect(build == .refusedPath, "\(id)")
      #expect(opp == .refusedPath, "\(id)")
      #expect(answer == .refusedPath, "\(id)")
      #expect(deploy == .refusedPath, "\(id)")
    }
    #expect(transport.requests.isEmpty)
    #expect(APIClientCore.isSafeSegment("0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33"))
    #expect(APIClientCore.isSafeSegment("fix_1"))
    let http = APIClientCore(config: BackendConfig(baseURL: URL(string: "http://api.example.test")!, tokens: M310BToken(token: M310B.token)),
                             transport: transport)
    let plain = await M310B.error { try await HTTPBrainClient(core: http).profile() }
    #expect(plain == .refusedPath)
    #expect(transport.requests.isEmpty)
  }

  @Test("HOST: the bearer token never appears in an error, a description or a server message echoed back")
  func hostTokenNeverInErrors() async {
    let echo = #"{"error":{"code":"unauthenticated","message":"bad token \#(M310B.token) for member","request_id":"req_\#(M310B.token)"}}"#
    let transport = RecordingTransport(replies: [.json(401, echo), .offline, .json(500, "oops \(M310B.token)"), .json(200, "{")])
    let client = M310B.brain(transport)
    var errors: [APIError] = []
    for _ in 0..<4 {
      if let e = await M310B.error({ try await client.profile() }) { errors.append(e) }
    }
    if let e = await M310B.error({ try await client.dayRecord(day: "../x") }) { errors.append(e) }
    let noSigner = M310B.builds(transport, signer: nil)
    if let e = await M310B.error({ try await noSigner.okBuild(fixID: "f", hashes: FixHashes(briefHash: "1", checkSetHash: "2", heldOutHash: "3", fixtureSetHash: "4")) }) {
      errors.append(e)
    }
    #expect(errors.count == 6)
    #expect(errors.first == .server(status: 401, code: .unauthenticated, message: "bad token [member token] for member",
                                    requestID: "req_[member token]", ruleID: nil))
    #expect(errors[1].isOffline)
    #expect(errors[2] == .badResponse(status: 500))
    #expect(errors[3] == .badResponse(status: 200))
    for e in errors {
      #expect(!String(describing: e).contains(M310B.token))
      #expect(!String(reflecting: e).contains(M310B.token))
      #expect(!e.localizedDescription.contains(M310B.token))
      #expect(!(e.errorDescription ?? "").contains(M310B.token))
    }
    let mode = BackendMode.resolve(baseURL: "https://api.example.test", tokens: M310BToken(token: M310B.token))
    #expect(!String(describing: mode).contains(M310B.token))
    #expect(!String(reflecting: mode).contains(M310B.token))
    if case .cloud(let config) = mode {
      #expect(!String(describing: config).contains(M310B.token))
    }
  }

  @Test("HOST: with no member token at request time nothing is sent")
  func hostNoTokenSendsNothing() async {
    let transport = RecordingTransport()
    let core = M310B.core(transport, signer: M310BSigner(), token: nil)
    let brain = await M310B.error { try await HTTPBrainClient(core: core).profile() }
    let ok = await M310B.error {
      try await HTTPBuildsClient(core: core).okBuild(fixID: "fix_1", hashes: FixHashes(briefHash: "1", checkSetHash: "2", heldOutHash: "3", fixtureSetHash: "4"))
    }
    #expect(brain == .notSignedIn)
    #expect(ok == .notSignedIn)
    #expect(transport.requests.isEmpty)
  }
}

// MARK: Helpers

struct M310BToken: MemberTokenProvider {
  let token: String?
  func currentToken() -> String? { token }
}

/// Records the bodies it signs and returns a fixed header value.
final class M310BSigner: RequestSigner, @unchecked Sendable {
  static let header = "keyid=0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33, sig=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0-Pw"
  struct Refused: Error {}

  private let lock = NSLock()
  private var seen: [Data] = []
  private let fails: Bool

  init(fails: Bool = false) { self.fails = fails }

  func signature(for body: Data) throws -> String {
    if fails { throw Refused() }
    lock.lock()
    defer { lock.unlock() }
    seen.append(body)
    return Self.header
  }

  var bodies: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }
}

enum M310B {
  static let token = "m310b-member-token-7Qx9ZkLw"
  static let base = URL(string: "https://api.example.test")!
  static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  static func core(
    _ transport: RecordingTransport, signer: (any RequestSigner)? = nil, token: String? = M310B.token,
    base: URL = M310B.base
  ) -> APIClientCore {
    APIClientCore(
      config: BackendConfig(baseURL: base, tokens: M310BToken(token: token)),
      transport: transport,
      signer: signer,
      now: { Date(timeIntervalSince1970: 1_795_348_800) }
    )
  }

  static func brain(_ transport: RecordingTransport) -> HTTPBrainClient {
    HTTPBrainClient(core: core(transport))
  }

  static func builds(_ transport: RecordingTransport, signer: (any RequestSigner)? = nil) -> HTTPBuildsClient {
    HTTPBuildsClient(core: core(transport, signer: signer))
  }

  static func body(_ request: URLRequest) -> String {
    String(decoding: request.httpBody ?? Data(), as: UTF8.self)
  }

  static func isULID(_ s: String?) -> Bool {
    guard let s, s.count == 26 else { return false }
    return s.allSatisfy { crockford.contains($0) }
  }

  /// The APIError a call throws, or nil when it returns (or throws something else).
  static func error<T>(_ run: @Sendable () async throws -> T) async -> APIError? {
    do {
      _ = try await run()
      return nil
    } catch let e as APIError {
      return e
    } catch {
      return nil
    }
  }
}

/// JSON from the ports (see the file comment). Synthetic: no real person's data.
enum M310BFixtures {
  static let profile = #"{"version":0,"role":null,"industry":null,"goals":[],"drains":[],"schedule":null,"timezone":"UTC","review_slot":{"day":"fri","time":"16:00"},"autonomy":"suggest","own_name_to_models":"mask","keyframes_to_cloud":false,"learning_paused":false,"updated_at":null}"#

  static let day = #"{"day":"2026-11-20","generated_at":"2026-11-21T05:00:00.000Z","x_unknown_field":{"a":[1,2,3]},"totals":{"active_minutes":{"id":"fig_5c45b37d492459da","value":312.5,"unit":"minutes","arithmetic":"sum of 41 spans' active time, idle removed = 312.5 min","evidence":[{"kind":"observation","id":"01JCA0000000000000000000A1"}],"source_purged_at":null},"switches":{"id":"fig_a3da3e3ca5108d5d","value":57,"unit":"count","arithmetic":"57 times the app changed between consecutive spans","evidence":[{"kind":"observation","id":"01JCA0000000000000000000A2"}],"source_purged_at":null},"switches_per_active_hour":{"id":"fig_ee69952afc90878f","value":10.9,"unit":"per_hour","arithmetic":"57 switches / (312.5 min / 60) = 10.9 per active hour","evidence":[],"source_purged_at":null},"focus_blocks":{"id":"fig_3d378f94671418bc","value":2,"unit":"count","arithmetic":"runs of one task with gaps under 2 min lasting at least 25 min: 2","evidence":[{"kind":"episode","id":"ep_fb_0123456789ab"}],"source_purged_at":null},"focus_minutes":{"id":"fig_23b6923eee78f9a3","value":71,"unit":"minutes","arithmetic":"active time in 2 focus blocks = 71 min","evidence":[{"kind":"episode","id":"ep_fb_0123456789ab"}],"source_purged_at":null},"meeting_minutes":{"id":"fig_f5de5dcd4666441d","value":45,"unit":"minutes","arithmetic":"active time of 3 meeting spans = 45 min","evidence":[{"kind":"observation","id":"01JCA0000000000000000000A3"}],"source_purged_at":null}},"by_kind":[{"kind":"build","minutes":{"id":"fig_aa5f6bc2d4ea84d3","value":120,"unit":"minutes","arithmetic":"active time of 10 build spans = 120 min","evidence":[{"kind":"observation","id":"01JCA0000000000000000000A4"}],"source_purged_at":null}}],"by_app":[{"app":"com.apple.dt.Xcode","minutes":{"id":"fig_8a9aec49858f8048","value":120,"unit":"minutes","arithmetic":"active time of 10 spans in com.apple.dt.Xcode = 120 min","evidence":[{"kind":"observation","id":"01JCA0000000000000000000A4"}],"source_purged_at":null}}],"by_task":[{"task_key":"k_0123456789ab","name":"Reconcile invoices","minutes":{"id":"fig_0daca2caf4211d46","value":62,"unit":"minutes","arithmetic":"active time of 3 instances = 62 min","evidence":[{"kind":"episode","id":"ep_i1"}],"source_purged_at":null},"instances":{"id":"fig_c6a49f25b8e72207","value":3,"unit":"count","arithmetic":"3 instances on 2026-11-20","evidence":[{"kind":"episode","id":"ep_i1"}],"source_purged_at":null},"median_minutes":{"id":"fig_71b4c73f48306da8","value":21,"unit":"minutes","arithmetic":"median of 3 instances' active minutes = 21 min","evidence":[{"kind":"episode","id":"ep_i1"}],"source_purged_at":null}}],"episode_ids":["ep_fb_0123456789ab","ep_i1"],"source_purged_at":null}"#

  static let week = #"{"iso_week":"2026-W47","from":"2026-11-16","to":"2026-11-22","days_recorded":["2026-11-20"],"hours":{"total":{"id":"fig_2c85640bc0da46fd","value":5.21,"unit":"hours","arithmetic":"sum of 1 day records' active minutes (312.5 min) / 60 = 5.21 h","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},"by_kind":[{"kind":"build","hours":{"id":"fig_724bc48c08bfb464","value":2,"unit":"hours","arithmetic":"build minutes of 1 day records (120 min) / 60","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null}}],"by_app":[{"app":"com.apple.dt.Xcode","hours":{"id":"fig_5d88946c709e0480","value":2,"unit":"hours","arithmetic":"minutes in com.apple.dt.Xcode on 1 day records (120 min) / 60","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null}}]},"focus":{"blocks":{"id":"fig_5a7f3afb138c0a30","value":2,"unit":"count","arithmetic":"sum of focus blocks on 1 days = 2","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},"minutes":{"id":"fig_41716091fda3611a","value":71,"unit":"minutes","arithmetic":"sum of focus minutes on 1 days = 71 min","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},"switches_per_active_hour":{"id":"fig_65c308ec4f932000","value":10.9,"unit":"per_hour","arithmetic":"57 switches / (312.5 min / 60) = 10.9 per active hour","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},"meeting_hours":{"id":"fig_59f504e7ad0ef358","value":0.75,"unit":"hours","arithmetic":"sum of meeting minutes on 1 days / 60 = 0.75 h","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null}},"tasks":[{"task_key":"k_0123456789ab","name":"Reconcile invoices","minutes":{"id":"fig_4685ec314ad5680d","value":62,"unit":"minutes","arithmetic":"sum of the task's minutes on 1 days = 62 min","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},"instances":{"id":"fig_31079d07e0587212","value":3,"unit":"count","arithmetic":"sum of the task's instances on 1 days = 3","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},"median_minutes":{"id":"fig_0d6b4d8b2c97a11d","value":21,"unit":"minutes","arithmetic":"median of 1 daily medians = 21 min","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},"baseline_minutes":null,"vs_baseline":null,"status":"new"}],"fixes":{"estimated":[],"measured":[]},"weeks_observed":3,"narrative":null,"generated_at":"2026-11-22T12:00:00.000Z"}"#

  static let review = #"{"iso_week":"2026-W47","sentence":"You worked 5.21 h this week: 71 min in focus blocks and 0.75 h in meetings.","tiles":[{"id":"fig_2c85640bc0da46fd","value":5.21,"unit":"hours","arithmetic":"sum of 1 day records' active minutes (312.5 min) / 60 = 5.21 h","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},{"id":"fig_41716091fda3611a","value":71,"unit":"minutes","arithmetic":"sum of focus minutes on 1 days = 71 min","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},{"id":"fig_59f504e7ad0ef358","value":0.75,"unit":"hours","arithmetic":"sum of meeting minutes on 1 days / 60 = 0.75 h","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null},{"id":"fig_65c308ec4f932000","value":10.9,"unit":"per_hour","arithmetic":"57 switches / (312.5 min / 60) = 10.9 per active hour","evidence":[{"kind":"day_record","id":"2026-11-20"}],"source_purged_at":null}],"goals":[{"id":"g_a41535a1d6","text":"Ship the Mac app"}],"questions":[{"subject_key":"k_0123456789ab","question_kind":"opportunity","name":"Reconcile invoices","answers":["keep","not_now","build","never","leave_alone","other_goal"],"answered":"keep"}]}"#

  static let answer = #"{"iso_week":"2026-W47","subject_key":"k_0123456789ab","question_kind":"opportunity","answer":"keep","goal_id":"g_a41535a1d6","answered_at":"2026-11-22T12:00:00.000Z"}"#

  static let build = #"{"id":"0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33","x_unknown_field":"ignored","state":"ready","cap_usd":4,"spent_usd":1.875,"fanout_workers":3,"stages":[{"name":"build","state":"done","started_at":"2026-11-22T11:50:00.000Z","ended_at":"2026-11-22T11:55:00.000Z","note":null},{"name":"verify","state":"done","started_at":"2026-11-22T11:55:00.000Z","ended_at":"2026-11-22T11:59:00.000Z","note":"all checks passed"}],"attempts":[{"id":"0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a34","ordinal":1,"outcome":"pass","spent_usd":1.25,"tries":2,"turns":14,"frozen_pass":true,"held_out_pass":true,"check_groups":[{"name":"frozen","passed":12,"failed":0},{"name":"held_out","passed":5,"failed":0}],"artifact_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifact_bytes":20480,"artifact_files":["routine.json","main.ts"],"note":"passed","wall_seconds":412},{"id":"0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a35","ordinal":2,"outcome":"fail","spent_usd":0.625,"tries":1,"turns":9,"frozen_pass":false,"held_out_pass":null,"check_groups":[{"name":"frozen","passed":10,"failed":2}],"artifact_sha256":null,"artifact_bytes":0,"artifact_files":[],"note":"2 checks failed"}],"winner_attempt_id":"0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a34","artifact_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","receipt_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","definition_hash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","deployed":false,"started_at":"2026-11-22T11:50:00.000Z","ended_at":"2026-11-22T11:59:00.000Z"}"#

  static let opportunities = #"[{"id":"opp_1","source":"finder","task_key":"k_0123456789ab","title":"Reconcile invoices","description":"Match the bank export to the invoices","iso_week":"2026-W47","rank":1,"score":2.4,"state":"open","factors":{"weekly_hours_saved":{"id":"fig_2b12a316e5ba76f5","value":3.1,"unit":"hours_per_week","arithmetic":"6 times x 31 min median = 3.1 h","evidence":[{"kind":"episode","id":"ep_i1"}],"source_purged_at":null},"persistence":{"id":"fig_06c49bf1fc374a53","value":0.75,"unit":"ratio","arithmetic":"3 of the last 4 weeks = 0.75","evidence":[{"kind":"week_record","id":"2026-W47"}],"source_purged_at":null},"note":"not a figure"},"options":[{"id":"fix_1","option_no":1,"kind":"routine","recommended":true,"title":"A weekly routine","detail":"Runs every Monday and asks before it sends","estimate":{"id":"fig_fe674dd6a0877984","value":2.5,"unit":"hours_per_week","arithmetic":"62 min x 3 per week x 0.8 = 2.5 h","evidence":[{"kind":"fix_estimate","id":"fix_1"}],"source_purged_at":null}},{"id":"fix_2","option_no":2,"title":"A checklist"},{"title":"no id, skipped"}],"missing_connections":[],"goal":{"id":"g_a41535a1d6","text":"Ship the Mac app"},"x_unknown_field":true},{"title":"no id: skipped"},{"id":"opp_2","source":"manual","title":"Weekly report","state":"waiting_on_moon","missing_connections":["google_sheets"],"goal":"not an object"}]"#

  static let fix = #"{"id":"fix_1","brief":{"title":"Weekly invoice match","steps":["read the export","match invoices"]},"brief_hash":"1111111111111111111111111111111111111111111111111111111111111111","check_set_hash":"2222222222222222222222222222222222222222222222222222222222222222","held_out_hash":"3333333333333333333333333333333333333333333333333333333333333333","fixture_set_hash":"4444444444444444444444444444444444444444444444444444444444444444","estimate":{"id":"fig_fe674dd6a0877984","value":2.5,"unit":"hours_per_week","arithmetic":"62 min x 3 per week x 0.8 = 2.5 h","evidence":[{"kind":"fix_estimate","id":"fix_1"}],"source_purged_at":null},"cap_usd":4,"x_unknown_field":[]}"#

  static let definition = #"{"definition":{"trigger":{"kind":"schedule","cron":"0 9 * * 1"},"steps":[{"capability":"sheets.read"}]},"definition_hash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","words":["Every Monday at 9:00","Reads the Finance sheet"]}"#

  static let outcomes = #"[{"routine_id":"r1","shipped_at":"2026-10-01T00:00:00Z","estimated_minutes_per_week":{"id":"fig_6ec1c8b3dc73e45c","value":150,"unit":"minutes_per_week","arithmetic":"2.5 h x 60 = 150 min/week","evidence":[{"kind":"fix_estimate","id":"fix_1"}],"source_purged_at":null},"baseline_minutes_per_week":120,"weeks":[30,"source_purged",28,null],"flag":"on_track","ratio":0.9,"arithmetic":"135 min measured / 150 min estimated = 0.9"},{"routine_id":"r2","flag":"sideways"}]"#
}
