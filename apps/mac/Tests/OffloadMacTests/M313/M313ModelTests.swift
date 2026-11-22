import Foundation
import Testing
@testable import OffloadMac

// BuildProgressModel over the fake builds client and m3-10's HTTP client (SPEC m3-13 red tests LIST, PLAN, OKBUILD,
// INSTALL, POLL, STATES, HANDOFF). Loops run as steps over a recording sleeper; nothing waits in real time.

extension M313 {
  // MARK: LIST

  @Test("LIST: builds started on this Mac, newest first, with name, state and start time")
  @MainActor func listNewestFirst() async {
    let store = MemoryBuildRecordStore([
      M313F.record("b_old", name: "Weekly report", fixID: nil, at: "2026-11-22T10:00:00Z"),
      M313F.record(),
    ])
    let client = M313Client()
    client.script("build", .value(M313F.fanningOut), .value(M313F.readyAs(.failed)))
    client.script("fix", .value(M313F.fix))
    let model = M313M.cloud(client, store: store)
    await model.refresh()
    #expect(model.builds.map(\.id) == [M313F.buildID, "b_old"])
    #expect(model.builds.map(\.name) == ["PR pre-read tool", "Weekly report"])
    #expect(model.builds.map(\.line) == ["building", "didn't pass"])
    #expect(model.builds.map(\.started) == ["started 22 Nov, 11:50", "started 22 Nov, 10:00"])
    #expect(model.builds.map(\.dot) == [.needsYou, .failedCheck])
    #expect(model.selected == M313F.buildID)
    #expect(model.detail?.title == "Building · PR pre-read tool")
    #expect(model.detail?.steps.first?.detail == "what it builds and what it must not touch · fingerprint 7c41e2")
    #expect(client.calls == ["build \(M313F.buildID)", "build b_old", "fix fix_1"])
    #expect(model.emptyLine == nil)
  }

  @Test("LIST: start times arrive in UTC and are shown in the person's time zone")
  @MainActor func listTimeZone() async {
    let client = M313Client()
    client.script("build", .value(M313F.ready))
    let model = BuildProgressModel(mode: M313F.cloudMode, client: client, store: MemoryBuildRecordStore([M313F.record(fixID: nil)]),
                                   sleeper: M313Sleeper(), now: { M313F.date("2026-11-22T12:00:00Z") },
                                   timeZone: TimeZone(identifier: "America/New_York")!)
    model.activate()
    await model.refresh()
    #expect(model.builds.first?.started == "started 22 Nov, 06:50")
    #expect(model.builds.first?.line == "ready to install")
  }

  @Test("LIST: a build that is gone (404) shows the gone line and can be removed from the list")
  @MainActor func listGone() async {
    let store = MemoryBuildRecordStore([M313F.record(fixID: nil)])
    let client = M313Client()
    client.script("build", .error(.notFound))
    let model = M313M.cloud(client, store: store)
    await model.refresh()
    #expect(model.builds.count == 1)
    #expect(model.builds.first?.line == "This build is no longer available.")
    #expect(model.builds.first?.canRemove == true)
    #expect(model.detail == nil)
    model.remove(buildID: M313F.buildID)
    #expect(model.builds.isEmpty)
    #expect(store.records().isEmpty)
    #expect(model.emptyLine == "No builds yet. Press OK, build on a suggested fix in Today.")
  }

  @Test("LIST: the UserDefaults store round-trips, keeps newest first and replaces a record with the same build id")
  @MainActor func listStoreRoundTrip() {
    let suite = "m313-store-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsBuildRecordStore(defaults: defaults)
    store.add(M313F.record("b_old", at: "2026-11-21T09:00:00Z"))
    store.add(M313F.record("b_new", at: "2026-11-22T09:00:00Z"))
    let again = UserDefaultsBuildRecordStore(defaults: defaults)
    #expect(again.records().map(\.buildID) == ["b_new", "b_old"])
    #expect(again.records().first == M313F.record("b_new", at: "2026-11-22T09:00:00Z"))
    var installed = M313F.record("b_old", at: "2026-11-21T09:00:00Z")
    installed.routineID = "rt_1"
    installed.installedAt = M313F.date("2026-11-22T12:10:00Z")
    again.add(installed)
    #expect(UserDefaultsBuildRecordStore(defaults: defaults).records().map(\.buildID) == ["b_new", "b_old"])
    #expect(UserDefaultsBuildRecordStore(defaults: defaults).records().last?.routineID == "rt_1")
    again.remove(buildID: "b_new")
    #expect(UserDefaultsBuildRecordStore(defaults: defaults).records().map(\.buildID) == ["b_old"])
  }

  @Test("LIST: an unreadable stored list reads as empty; the memory store behaves like the UserDefaults one")
  @MainActor func listStoreUnreadable() {
    let suite = "m313-bad-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not json".utf8), forKey: UserDefaultsBuildRecordStore.key)
    #expect(UserDefaultsBuildRecordStore(defaults: defaults).records().isEmpty)
    let memory = MemoryBuildRecordStore()
    memory.add(M313F.record("b1", at: "2026-11-20T09:00:00Z"))
    memory.add(M313F.record("b2", at: "2026-11-21T09:00:00Z"))
    memory.add(M313F.record("b1", name: "Renamed", at: "2026-11-20T09:00:00Z"))
    #expect(memory.records().map(\.buildID) == ["b2", "b1"])
    #expect(memory.records().last?.name == "Renamed")
  }

  // MARK: PLAN

  @Test("PLAN: answer build, then poll the opportunity until its fix can be read")
  @MainActor func planAnswerThenPoll() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("designing")))
    client.script("opportunity", .value(M313F.opportunity("designing")), .value(M313F.opportunity("ready_for_approval")))
    client.script("fix", .value(M313F.fix))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(model.plan?.phase == .designing)
    #expect(model.plan?.line == "Designing the fix…")
    #expect(model.plan?.title == "PR pre-read tool")
    #expect(await model.planStep() == 5)
    #expect(model.plan?.phase == .designing)
    #expect(await model.planStep() == nil)
    #expect(model.plan?.phase == .ready(M313F.fix))
    #expect(model.plan?.line == nil)
    #expect(client.calls == ["answer opp_1 build fix_1", "opportunity opp_1", "opportunity opp_1", "fix fix_1"])
  }

  @Test("PLAN: the opportunity is polled every 5 s while the fix is designed")
  @MainActor func planPollsEvery5s() async {
    let client = M313Client()
    let sleeper = M313Sleeper()
    client.script("answer", .value(M313F.opportunity("chosen")))
    client.script("opportunity", .value(M313F.opportunity("capturing_fixtures")), .value(M313F.opportunity("designing")),
                  .value(M313F.opportunity("ready_for_approval")))
    client.script("fix", .value(M313F.fix))
    let model = M313M.cloud(client, sleeper: sleeper)
    await model.startPlan(opportunityID: "opp_1", optionID: nil)
    await model.runPlanLoop()
    #expect(sleeper.delays == [5, 5, 5])
    #expect(model.plan?.phase == .ready(M313F.fix))
    // No option given: the recommended option is the fix.
    #expect(client.calls.first == "answer opp_1 build -")
    #expect(client.calls.last == "fix fix_1")
  }

  @Test("PLAN: needs_connection says which apps to connect first and keeps polling")
  @MainActor func planNeedsConnection() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("needs_connection", missing: ["google_sheets", "github"])))
    client.script("opportunity", .value(M313F.opportunity("needs_connection", missing: ["github"])))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(model.plan?.phase == .needsConnection(["google_sheets", "github"]))
    #expect(model.plan?.line == "Connect Google Sheets and Github first.")
    #expect(await model.planStep() == 5)
    #expect(model.plan?.line == "Connect Github first.")
    #expect(client.count("fix") == 0)
  }

  @Test("PLAN: the fix's plan shows its summary, the estimate labelled estimated, and the build cap")
  @MainActor func planSummary() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("ready_for_approval")))
    client.script("fix", .value(M313F.fix))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(model.plan?.phase == .ready(M313F.fix))
    let summary = PlanSummary.make(fix: M313F.fix, title: "PR pre-read tool")
    #expect(summary.summary == "Reads each new pull request and posts a short summary card before review.")
    #expect(summary.estimate == "saves 1.4 h/wk, estimated")
    #expect(summary.cap == "build cap $4.00")
    var bare = M313F.fix
    bare.brief = .object([:])
    bare.estimate = nil
    #expect(PlanSummary.make(fix: bare, title: "PR pre-read tool") == PlanSummary(summary: "PR pre-read tool", estimate: nil,
                                                                                    cap: "build cap $4.00"))
  }

  @Test("PLAN: after 10 minutes of designing it says Still designing. Check back later. and stops")
  @MainActor func planTenMinutes() async {
    let client = M313Client()
    let now = M313Now()
    client.script("answer", .value(M313F.opportunity("designing")))
    client.fallback("opportunity", .value(M313F.opportunity("designing")))
    let model = M313M.cloud(client, now: now)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    now.advance(599)
    #expect(await model.planStep() == 5)
    now.advance(2)
    #expect(await model.planStep() == nil)
    #expect(model.plan?.phase == .tooLong)
    #expect(model.plan?.line == "Still designing. Check back later.")
    #expect(client.count("opportunity") == 1)
  }

  @Test("PLAN: a fix that is not there yet (404) keeps waiting")
  @MainActor func planFixNotYet() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("ready_for_approval")))
    client.script("fix", .error(.notFound), .value(M313F.fix))
    client.script("opportunity", .value(M313F.opportunity("ready_for_approval")))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(model.plan?.phase == .designing)
    #expect(await model.planStep() == nil)
    #expect(model.plan?.phase == .ready(M313F.fix))
  }

  // MARK: OKBUILD

  @Test("OKBUILD: posts exactly the four hashes read and cap_usd 4, signed over those bytes")
  @MainActor func okBuildSignedBody() async throws {
    let signer = M313Signer()
    let transport = RecordingTransport(replies: [
      .json(200, M313F.opportunityJSON("ready_for_approval")), .json(200, M313F.fixJSON),
      .json(202, #"{"build_id":"b_new"}"#), .json(200, M313F.fanningOutJSON),
    ])
    let core = APIClientCore(config: BackendConfig(baseURL: URL(string: "https://api.example.test")!, tokens: M313Token()),
                             transport: transport, signer: signer, now: { M313F.date("2026-11-22T12:00:00Z") })
    let model = BuildProgressModel(mode: M313F.cloudMode, client: HTTPBuildsClient(core: core), store: MemoryBuildRecordStore(),
                                   sleeper: M313Sleeper(), now: { M313F.date("2026-11-22T12:00:00Z") }, timeZone: M313F.utc)
    model.activate()
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(transport.requests.count == 2)
    await model.okBuild()
    let req = try #require(transport.requests.count > 2 ? transport.requests[2] : nil)
    let expected = #"{"brief_hash":""# + M313F.briefHash + #"","cap_usd":4,"check_set_hash":""# + M313F.checkSetHash
      + #"","fixture_set_hash":""# + M313F.fixtureSetHash + #"","held_out_hash":""# + M313F.heldOutHash + #""}"#
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/fixes/fix_1/build-approvals")
    #expect(req.httpBody == Data(expected.utf8))
    #expect(signer.bodies == [Data(expected.utf8)])
    #expect(req.value(forHTTPHeaderField: "Offload-Signature") == M313Signer.header)
    #expect(transport.requests.filter { $0.url?.path.hasSuffix("/build-approvals") == true }.count == 1)
  }

  @Test("OKBUILD: 202 records the build on this Mac and selects it")
  @MainActor func okBuildRecords() async {
    let client = M313Client()
    let store = MemoryBuildRecordStore()
    client.script("answer", .value(M313F.opportunity("ready_for_approval")))
    client.script("fix", .value(M313F.fix))
    client.script("okBuild", .value(BuildStarted(buildID: "b_new")))
    client.script("build", .value(M313F.fanningOut))
    let model = M313M.cloud(client, store: store)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    await model.okBuild()
    #expect(client.okBuildHashes == [M313F.fix.hashes])
    #expect(client.okBuildHashes.first?.capUSD == 4)
    #expect(store.records() == [BuildRecord(buildID: "b_new", name: "PR pre-read tool", fixID: "fix_1",
                                            startedAt: M313F.date("2026-11-22T12:00:00Z"))])
    #expect(model.selected == "b_new")
    #expect(model.plan == nil)
    #expect(model.builds.map(\.id) == ["b_new"])
    #expect(model.detail?.headline == "One check failed. Fixing it.")
  }

  @Test("OKBUILD: 403 hash_mismatch reads the fix again, says the plan changed, and needs a new press")
  @MainActor func okBuildHashMismatch() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("ready_for_approval")))
    client.script("fix", .value(M313F.fix), .value(M313F.changedFix))
    client.script("okBuild", .error(M313F.server(403, "hash_mismatch", "brief_hash is not this fix's current value: review it again")),
                  .value(BuildStarted(buildID: "b_new")))
    client.script("build", .value(M313F.fanningOut))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    await model.okBuild()
    #expect(model.plan?.phase == .ready(M313F.changedFix))
    #expect(model.plan?.message == "The plan changed. Read it again.")
    #expect(client.count("okBuild") == 1)
    #expect(client.count("fix") == 2)
    await model.okBuild()
    #expect(client.okBuildHashes == [M313F.fix.hashes, M313F.changedFix.hashes])
  }

  @Test("OKBUILD: 409 already_running says a build of this plan is already running and shows the list")
  @MainActor func okBuildAlreadyRunning() async {
    let client = M313Client()
    let store = MemoryBuildRecordStore()
    client.script("answer", .value(M313F.opportunity("ready_for_approval")))
    client.script("fix", .value(M313F.fix))
    client.script("okBuild", .error(M313F.server(409, "already_running", "a build of this fix is queued or running")))
    let model = M313M.cloud(client, store: store)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    await model.okBuild()
    #expect(model.plan == nil)
    #expect(model.notice == "A build of this plan is already running.")
    #expect(store.records().isEmpty)
  }

  @Test("OKBUILD: policy_denied shows the server's message and keeps the plan")
  @MainActor func okBuildPolicyDenied() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("ready_for_approval")))
    client.script("fix", .value(M313F.fix))
    client.script("okBuild", .error(M313F.server(403, "policy_denied", "Builds are paused for this workspace.")))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    await model.okBuild()
    #expect(model.plan?.phase == .ready(M313F.fix))
    #expect(model.plan?.message == "Builds are paused for this workspace.")
  }

  @Test("OKBUILD: nothing is posted without the press, and not before the plan is ready")
  @MainActor func okBuildNeedsPress() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("designing")))
    client.script("opportunity", .value(M313F.opportunity("ready_for_approval")))
    client.script("fix", .value(M313F.fix))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(!model.canOKBuild)
    await model.okBuild()
    #expect(client.count("okBuild") == 0)
    _ = await model.planStep()
    #expect(model.canOKBuild)
    #expect(client.count("okBuild") == 0)
  }

  @Test("OKBUILD: without a signer nothing is sent and it says why")
  @MainActor func okBuildNoSigner() async {
    let transport = RecordingTransport(replies: [.json(200, M313F.opportunityJSON("ready_for_approval")), .json(200, M313F.fixJSON)],
                                       fallback: .json(202, #"{"build_id":"b_new"}"#))
    let core = APIClientCore(config: BackendConfig(baseURL: URL(string: "https://api.example.test")!, tokens: M313Token()),
                             transport: transport, signer: nil)
    let store = MemoryBuildRecordStore()
    let model = BuildProgressModel(mode: M313F.cloudMode, client: HTTPBuildsClient(core: core), store: store,
                                   sleeper: M313Sleeper(), timeZone: M313F.utc)
    model.activate()
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    await model.okBuild()
    #expect(transport.requests.count == 2)
    #expect(model.plan?.message == "Building needs this Mac to be enrolled.")
    #expect(store.records().isEmpty)
  }

  // MARK: INSTALL

  @Test("INSTALL: Install is disabled until the definition was read; See what changed lists its words")
  @MainActor func installNeedsDefinition() async {
    let (model, client, _) = await M313M.selected(M313F.ready)
    #expect(model.detail?.actions.offerInstall == true)
    #expect(model.canReadDefinition)
    #expect(!model.canInstall)
    await model.install()
    #expect(client.count("deploy") == 0)
    client.script("definition", .value(M313F.definition))
    await model.readDefinition()
    #expect(model.installState.definition?.words == ["When a pull request opens", "Reads the pull request, never writes to it",
                                                "Posts a summary card on this Mac"])
    #expect(model.canInstall)
  }

  @Test("INSTALL: posts the build's artifact and receipt hashes and the definition's hash, signed")
  @MainActor func installSignedBody() async throws {
    let signer = M313Signer()
    let transport = RecordingTransport(replies: [
      .json(200, M313F.readyJSON), .json(200, M313F.definitionJSON),
      .json(201, #"{"routine_id":"rt_1","version":1}"#), .json(200, M313F.readyJSON.replacingOccurrences(of: #""deployed":false"#, with: #""deployed":true"#)),
      .json(404, #"{"error":{"code":"not_found","message":"no such route"}}"#),
    ])
    let core = APIClientCore(config: BackendConfig(baseURL: URL(string: "https://api.example.test")!, tokens: M313Token()),
                             transport: transport, signer: signer)
    let model = BuildProgressModel(mode: M313F.cloudMode, client: HTTPBuildsClient(core: core),
                                   store: MemoryBuildRecordStore([M313F.record(fixID: nil)]), sleeper: M313Sleeper(),
                                   now: { M313F.date("2026-11-22T12:10:00Z") }, timeZone: M313F.utc)
    model.activate()
    await model.refresh()
    await model.readDefinition()
    await model.install()
    let deploy = try #require(transport.requests.first { $0.url?.path.hasSuffix("/deploy") == true })
    let expected = #"{"artifact_sha256":""# + M313F.artifact + #"","definition_hash":""# + M313F.definitionHash
      + #"","receipt_hash":""# + M313F.receipt + #""}"#
    #expect(deploy.url?.absoluteString == "https://api.example.test/v1/builds/\(M313F.buildID)/deploy")
    #expect(deploy.httpBody == Data(expected.utf8))
    #expect(signer.bodies == [Data(expected.utf8)])
    #expect(deploy.value(forHTTPHeaderField: "Offload-Signature") == M313Signer.header)
    #expect(model.installLine == "Installed · version 1")
    #expect(model.detail?.saving?.text == "measured after install, from M4")
  }

  @Test("INSTALL: 201 shows the version, keeps the routine on the record and reads its measured saving")
  @MainActor func installInstalled() async {
    let (model, client, store) = await M313M.selected(M313F.ready)
    client.script("definition", .value(M313F.definition))
    client.script("deploy", .value(Deployed(routineID: "rt_1", version: 1)))
    client.script("build", .value(M313F.readyAs(.ready, deployed: true)))
    client.script("outcomes", .value([M313F.outcome("pending", weeks: "[]")]))
    await model.readDefinition()
    await model.install()
    #expect(model.installLine == "Installed · version 1")
    #expect(model.installState.installed == Deployed(routineID: "rt_1", version: 1))
    #expect(store.records().first?.routineID == "rt_1")
    #expect(store.records().first?.installedAt == M313F.date("2026-11-22T12:00:00Z"))
    #expect(client.calls.contains("outcomes 2026-11"))
    #expect(model.detail?.saving?.text == "measuring · week 1 of 4")
    #expect(model.detail?.actions.offerInstall == false)
    #expect(!model.canInstall)
    #expect(client.deployHashes == [M313F.ready.deployHashes!])
  }

  @Test("INSTALL: 403 hash_mismatch reads the build and the definition again and needs a new press")
  @MainActor func installHashMismatch() async {
    let (model, client, _) = await M313M.selected(M313F.ready)
    client.script("definition", .value(M313F.definition), .value(M313F.changedDefinition))
    client.script("deploy", .error(M313F.server(403, "hash_mismatch", "definition_hash is not current")),
                  .value(Deployed(routineID: "rt_1", version: 2)))
    client.script("build", .value(M313F.ready), .value(M313F.readyAs(.ready, deployed: true)))
    client.fallback("outcomes", .value([FixOutcome]()))
    await model.readDefinition()
    await model.install()
    #expect(model.installState.message == "It changed since you read it. Read it again.")
    #expect(model.installLine == "It changed since you read it. Read it again.")
    #expect(model.installState.definition == M313F.changedDefinition)
    #expect(client.count("deploy") == 1)
    #expect(client.calls.suffix(2) == ["build \(M313F.buildID)", "definition \(M313F.buildID)"])
    await model.install()
    #expect(client.deployHashes.map(\.definitionHash) == [M313F.definitionHash, String(repeating: "f", count: 64)])
  }

  @Test("INSTALL: 409 state_conflict reads the build again")
  @MainActor func installStateConflict() async {
    let (model, client, _) = await M313M.selected(M313F.ready)
    client.script("definition", .value(M313F.definition))
    client.script("deploy", .error(M313F.server(409, "state_conflict", "only a ready build can be deployed")))
    client.script("build", .value(M313F.readyAs(.ready, deployed: true)))
    client.fallback("outcomes", .error(.notFound))
    await model.readDefinition()
    await model.install()
    #expect(client.count("build") == 2)
    #expect(model.detail?.actions.offerInstall == false)
    #expect(model.detail?.steps.last?.detail == "installed")
    #expect(!model.canInstall)
  }

  @Test("INSTALL: not offered unless the build is ready and not deployed")
  @MainActor func installNotOffered() async {
    for build in [M313F.fanningOut, M313F.readyAs(.failed), M313F.readyAs(.ready, deployed: true), M313F.readyAs(.unknown("x"))] {
      let client = M313Client()
      client.fallback("outcomes", .value([FixOutcome]()))
      let (model, _, _) = await M313M.selected(build, client: client)
      #expect(model.detail?.actions.offerInstall == false, "\(build.state.raw)")
      #expect(!model.canReadDefinition)
      await model.readDefinition()
      await model.install()
      #expect(client.count("definition") == 0)
      #expect(client.count("deploy") == 0)
    }
  }

  @Test("INSTALL: without a signer nothing is sent and it says Installing needs this Mac to be enrolled.")
  @MainActor func installNoSigner() async {
    let transport = RecordingTransport(replies: [.json(200, M313F.readyJSON), .json(200, M313F.definitionJSON)],
                                       fallback: .json(201, #"{"routine_id":"rt_1","version":1}"#))
    let core = APIClientCore(config: BackendConfig(baseURL: URL(string: "https://api.example.test")!, tokens: M313Token()),
                             transport: transport, signer: nil)
    let model = BuildProgressModel(mode: M313F.cloudMode, client: HTTPBuildsClient(core: core),
                                   store: MemoryBuildRecordStore([M313F.record(fixID: nil)]), sleeper: M313Sleeper(), timeZone: M313F.utc)
    model.activate()
    await model.refresh()
    await model.readDefinition()
    await model.install()
    #expect(transport.requests.count == 2)
    #expect(model.installLine == "Installing needs this Mac to be enrolled.")
    #expect(model.installState.installed == nil)
  }

  // MARK: POLL

  @Test("POLL: polls every 2 s while the build is live and stops when it is ready")
  @MainActor func pollEvery2s() async {
    let sleeper = M313Sleeper()
    let (model, client, _) = await M313M.selected(M313F.fanningOut, sleeper: sleeper)
    client.script("build", .value(M313F.fanningOut), .value(M313F.readyAs(.verifying)), .value(M313F.ready))
    await model.runPollLoop()
    #expect(sleeper.delays == [2, 2, 2])
    #expect(client.count("build") == 4)
    #expect(model.detail?.headline == "It's built and every check passed.")
    #expect(model.builds.first?.line == "ready to install")
  }

  @Test("POLL: live states keep polling; every other state stops it")
  @MainActor func pollEndStates() async {
    for state in [BuildState.queued, .building, .verifying, .fanningOut, .repairing] {
      let (model, client, _) = await M313M.selected(M313F.fanningOut)
      client.script("build", .value(M313F.readyAs(state)))
      #expect(await model.pollStep() == 2, "\(state.raw)")
    }
    for state in [BuildState.ready, .failed, .capped, .tampered, .cancelled, .infraFailed, .unknown("teleporting")] {
      let client = M313Client()
      client.fallback("outcomes", .value([FixOutcome]()))
      let (model, _, _) = await M313M.selected(M313F.fanningOut, client: client)
      client.script("build", .value(M313F.readyAs(state)))
      #expect(await model.pollStep() == nil, "\(state.raw)")
    }
    // A build already at an end state is not polled at all.
    let sleeper = M313Sleeper()
    let (done, client, _) = await M313M.selected(M313F.readyAs(.failed), sleeper: sleeper)
    await done.runPollLoop()
    #expect(sleeper.delays.isEmpty)
    #expect(client.count("build") == 1)
  }

  @Test("POLL: stops when the screen goes away")
  @MainActor func pollStopsOnDisappear() async {
    let sleeper = M313Sleeper()
    let (model, client, _) = await M313M.selected(M313F.fanningOut, sleeper: sleeper)
    client.fallback("build", .value(M313F.fanningOut))
    model.disappear()
    #expect(await model.pollStep() == nil)
    await model.runPollLoop()
    #expect(sleeper.delays.isEmpty)
    #expect(client.count("build") == 1)
    #expect(!model.isActive)
  }

  @Test("POLL: on errors it backs off 2, 4, 8 … 60 s and says Can't reach Offload. Retrying.")
  @MainActor func pollBackoff() async {
    let sleeper = M313Sleeper()
    let (model, client, _) = await M313M.selected(M313F.fanningOut, sleeper: sleeper)
    client.script("build", .error(M313F.offline))
    #expect(await model.pollStep() == 2)
    #expect(model.connectionLine == "Can't reach Offload. Retrying.")
    client.script("build", .error(M313F.offline), .error(M313F.server(503, "server_error")), .error(M313F.offline),
                  .error(M313F.offline), .error(M313F.offline), .error(M313F.offline), .value(M313F.ready))
    await model.runPollLoop()
    // The first wait follows the one error so far (2 s), then six more errors: 4, 8, 16, 32, 60, 60.
    #expect(sleeper.delays == [2, 4, 8, 16, 32, 60, 60])
    #expect(model.connectionLine == nil)
    #expect(BuildProgressModel.backoff(1) == 2)
    #expect(BuildProgressModel.backoff(5) == 32)
    #expect(BuildProgressModel.backoff(6) == 60)
    #expect(BuildProgressModel.backoff(40) == 60)
  }

  @Test("POLL: a build that disappears (404) stops polling and shows the gone line")
  @MainActor func pollGone() async {
    let (model, client, _) = await M313M.selected(M313F.fanningOut)
    client.script("build", .error(.notFound))
    #expect(await model.pollStep() == nil)
    #expect(model.builds.first?.line == "This build is no longer available.")
    #expect(model.builds.first?.canRemove == true)
    #expect(model.detail == nil)
  }

  // MARK: STATES

  @Test("STATES: no builds in .cloud says how to start one")
  @MainActor func statesNoBuilds() async {
    let model = M313M.cloud(M313Client())
    await model.refresh()
    #expect(model.builds.isEmpty)
    #expect(model.emptyLine == "No builds yet. Press OK, build on a suggested fix in Today.")
    #expect(model.detail == nil)
  }

  @Test("STATES: offline says Can't reach Offload. Retrying. and the row waits")
  @MainActor func statesOffline() async {
    let client = M313Client()
    client.script("build", .error(M313F.offline))
    let model = M313M.cloud(client, store: MemoryBuildRecordStore([M313F.record(fixID: nil)]))
    await model.refresh()
    #expect(model.connectionLine == "Can't reach Offload. Retrying.")
    #expect(model.builds.first?.line == "checking")
    #expect(model.builds.first?.canRemove == false)
  }

  @Test("STATES: every APIError has one plain sentence, without request ids or hashes")
  func statesSentences() {
    let cases: [(APIError, String)] = [
      (.notFound, "Offload doesn't have this."),
      (.signingUnavailable, "This needs this Mac to be enrolled."),
      (.refusedPath, "Offload's address can't be used, so nothing was sent."),
      (.notSignedIn, "This Mac isn't signed in, so nothing was sent."),
      (.invalidBody, "This Mac couldn't write the request, so nothing was sent."),
      (M313F.offline, "Can't reach Offload."),
      (.badResponse(status: 502), "Offload's answer couldn't be read."),
      (M313F.server(403, "policy_denied", "Builds are paused for this workspace."), "Builds are paused for this workspace."),
      (M313F.server(403, "policy_denied"), "A rule on your account says no."),
      (M313F.server(403, "hash_mismatch", "brief_hash is not current"), "It changed since you read it. Read it again."),
      (M313F.server(409, "already_running"), "A build of this plan is already running."),
      (M313F.server(409, "state_conflict"), "It changed on Offload. Showing the latest."),
      (M313F.server(409, "approval_used"), "That approval was already used. Read it again."),
      (M313F.server(409, "approval_expired"), "That approval was already used. Read it again."),
      (M313F.server(401, "unauthenticated"), "This Mac needs to sign in again."),
      (M313F.server(401, "token_expired"), "This Mac needs to sign in again."),
      (M313F.server(403, "forbidden"), "This account can't do that."),
      (M313F.server(422, "budget_exceeded"), "This would go over this month's budget."),
      (M313F.server(429, "rate_limited"), "Offload is busy. Try again in a minute."),
      (M313F.server(500, "server_error"), "Offload had a problem. Try again later."),
      (M313F.server(503, "teapot"), "Offload had a problem. Try again later."),
      (M313F.server(400, "schema_invalid", "cap_usd: expected 4"), "Offload couldn't do that."),
    ]
    for (error, sentence) in cases {
      #expect(BuildCopy.sentence(for: error) == sentence, "\(error)")
      #expect(!BuildCopy.sentence(for: error).contains("req_"))
    }
  }

  // MARK: HANDOFF

  @Test("HANDOFF: an .opportunity hand-off starts the plan step")
  @MainActor func handOffOpportunity() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("designing")))
    client.fallback("opportunity", .value(M313F.opportunity("designing")))
    let model = M313M.cloud(client, sleeper: M313Sleeper(limit: 2))
    model.appear(pending: .opportunity(id: "opp_1", optionID: "fix_1"))
    await model.startTask?.value
    #expect(client.calls.first == "answer opp_1 build fix_1")
    #expect(model.plan?.phase == .designing)
    model.disappear()
  }

  @Test("HANDOFF: a .localRepeat hand-off opens the labelled sample with the repeat's name")
  @MainActor func handOffLocalRepeat() async {
    let store = MemoryBuildRecordStore()
    let model = M313M.local(store: store)
    model.appear(pending: .localRepeat(key: "k_1", name: "Weekly report", minutesPerWeek: 90))
    #expect(model.notice == "Building “Weekly report” needs the cloud. This sample shows what a build looks like.")
    #expect(model.selected == SampleBuild.rowID)
    #expect(model.builds.count == 1)
    #expect(model.provenance == .sample)
    model.disappear()
    #expect(store.records().isEmpty)
  }

  @Test("HANDOFF: the pending request is consumed once, so coming back to Builds starts nothing again")
  @MainActor func handOffOnce() async {
    let navigation = NavigationModel()
    navigation.startBuild(.opportunity(id: "opp_1", optionID: "fix_1"))
    #expect(navigation.selection == .builds)
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("ready_for_approval")))
    client.fallback("fix", .value(M313F.fix))
    let model = M313M.cloud(client, sleeper: M313Sleeper(limit: 1))
    model.appear(navigation: navigation)
    #expect(navigation.pendingBuild == nil)
    await model.startTask?.value
    model.disappear()
    model.appear(navigation: navigation)
    await model.startTask?.value
    model.disappear()
    #expect(client.count("answer") == 1)
  }

  @Test("HANDOFF: in .cloud a .localRepeat says it needs the cloud's view of it and shows no sample")
  @MainActor func handOffLocalRepeatInCloud() async {
    let model = M313M.cloud(M313Client(), sleeper: M313Sleeper(limit: 1))
    model.appear(pending: .localRepeat(key: "k_1", name: "Weekly report", minutesPerWeek: 90))
    await model.startTask?.value
    #expect(model.notice == "“Weekly report” was counted on this Mac. Build it from a suggestion in Today once Offload has seen it.")
    #expect(model.builds.isEmpty)
    #expect(model.provenance == .cloud)
    model.disappear()
  }
}
