import Foundation
import Testing
@testable import OffloadMac

// Review 2 of m3-13 (logs/m3-13-mac-build-progress.review1.md): tests for behaviour that had none (cancel, select,
// Not now, the plan's failures, a missing definition) and red tests for the findings that change behaviour.

extension M313 {
  // MARK: Finding 1: cancel

  @Test("CANCEL: Cancel build is offered only while the build is live; otherwise nothing is posted")
  @MainActor func cancelOnlyWhileLive() async {
    let (live, _, _) = await M313M.selected(M313F.fanningOut)
    #expect(live.detail?.actions.offerCancel == true)
    #expect(live.canCancel)
    for build in [M313F.ready, M313F.readyAs(.failed), M313F.readyAs(.cancelled)] {
      let (model, client, _) = await M313M.selected(build)
      #expect(model.detail?.actions.offerCancel == false, "\(build.state.raw)")
      #expect(!model.canCancel)
      await model.cancel()
      #expect(client.count("cancel") == 0)
    }
    let local = M313M.local()
    await local.refresh()
    #expect(!local.canCancel)
  }

  @Test("CANCEL: the build cancel returns replaces the one shown; an error becomes a notice")
  @MainActor func cancelReplacesBuild() async {
    let (model, client, _) = await M313M.selected(M313F.fanningOut)
    client.script("cancel", .value(M313F.readyAs(.cancelled)))
    await model.cancel()
    #expect(client.calls.last == "cancel \(M313F.buildID)")
    #expect(model.detail?.headline == "Cancelled. Nothing was installed.")
    #expect(model.builds.first?.line == "cancelled")
    #expect(!model.canCancel)
    #expect(model.notice == nil)

    let (failing, failingClient, _) = await M313M.selected(M313F.fanningOut)
    failingClient.script("cancel", .error(M313F.server(409, "state_conflict", "the build already ended")))
    await failing.cancel()
    #expect(failing.notice == "It changed on Offload. Showing the latest.")
    #expect(failing.detail?.headline == "One check failed. Fixing it.")
  }

  @Test("CANCEL: posts POST /v1/builds/{id}/cancel with no body and no signature")
  @MainActor func cancelRoute() async throws {
    let transport = RecordingTransport(replies: [
      .json(200, M313F.fanningOutJSON),
      .json(200, M313F.readyJSON.replacingOccurrences(of: #""state":"ready""#, with: #""state":"cancelled""#)),
    ])
    let core = APIClientCore(config: BackendConfig(baseURL: URL(string: "https://api.example.test")!, tokens: M313Token()),
                             transport: transport, signer: M313Signer())
    let model = BuildProgressModel(mode: M313F.cloudMode, client: HTTPBuildsClient(core: core),
                                   store: MemoryBuildRecordStore([M313F.record(fixID: nil)]), sleeper: M313Sleeper(),
                                   timeZone: M313F.utc)
    model.activate()
    await model.refresh()
    await model.cancel()
    let req = try #require(transport.requests.count == 2 ? transport.requests[1] : nil)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.example.test/v1/builds/\(M313F.buildID)/cancel")
    #expect(req.httpBody == nil)
    #expect(req.value(forHTTPHeaderField: "Offload-Signature") == nil)
    #expect(model.detail?.headline == "Cancelled. Nothing was installed.")
  }

  // MARK: Finding 1: select, Not now, plan failures, missing definition

  @Test("LIST: choosing another build clears the definition read for the first; ids not on this Mac are refused")
  @MainActor func selectResetsInstall() async {
    let store = MemoryBuildRecordStore([
      M313F.record(fixID: nil), M313F.record("b_two", name: "Weekly report", fixID: nil, at: "2026-11-22T10:00:00Z"),
    ])
    let client = M313Client()
    client.script("build", .value(M313F.ready), .value(M313F.ready))
    client.script("definition", .value(M313F.definition))
    let model = M313M.cloud(client, store: store)
    await model.refresh()
    await model.readDefinition()
    #expect(model.canInstall)
    await model.select("b_two")
    #expect(model.selected == "b_two")
    #expect(model.installState.definition == nil)
    #expect(!model.canInstall)
    await model.select(M313F.buildID)
    #expect(model.installState.definition == nil)
    #expect(!model.canInstall)
    let calls = client.calls.count
    await model.select("b_elsewhere")
    #expect(model.selected == M313F.buildID)
    #expect(client.calls.count == calls)
  }

  @Test("PLAN: Not now closes the plan, posts nothing and stops reading the opportunity")
  @MainActor func planNotNow() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("designing")))
    client.fallback("opportunity", .value(M313F.opportunity("designing")))
    let model = M313M.cloud(client, sleeper: M313Sleeper(limit: 3))
    model.appear(pending: .opportunity(id: "opp_1", optionID: "fix_1"))
    await model.startTask?.value
    #expect(model.planTask != nil)
    model.dismissPlan()
    #expect(model.plan == nil)
    #expect(model.planTask == nil)
    #expect(await model.planStep() == nil)
    #expect(client.count("okBuild") == 0)
    model.disappear()
  }

  @Test("PLAN: a failed answer stops the plan with the error in words; no fix to build says so")
  @MainActor func planFailures() async {
    let client = M313Client()
    client.script("answer", .error(M313F.server(500, "server_error")))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(model.plan?.phase == .stopped)
    #expect(model.plan?.message == "Offload had a problem. Try again later.")
    #expect(client.count("fix") == 0)

    let bare = M313F.decode(Opportunity.self, #"{"id":"opp_1","title":"PR pre-read tool","state":"ready_for_approval","options":[]}"#)
    let noFix = M313Client()
    noFix.script("answer", .value(bare))
    let model2 = M313M.cloud(noFix)
    await model2.startPlan(opportunityID: "opp_1", optionID: nil)
    #expect(model2.plan?.phase == .stopped)
    #expect(model2.plan?.message == "This suggestion has no fix to build yet.")
    #expect(noFix.count("fix") == 0)
  }

  @Test("INSTALL: a definition the server does not have (404) says it can't be shown yet, and Install stays off")
  @MainActor func installDefinitionMissing() async {
    let (model, client, _) = await M313M.selected(M313F.ready)
    client.script("definition", .error(.notFound))
    await model.readDefinition()
    #expect(model.installState.definition == nil)
    #expect(model.installLine == "What it will do can't be shown yet.")
    #expect(!model.canInstall)
  }

  // MARK: Finding 2: disabled looks disabled; the reason is on screen

  @Test("INSTALL: before the definition is read the line says to read it first; disabled buttons are drawn faded")
  @MainActor func installReadFirstLine() async {
    let (model, client, _) = await M313M.selected(M313F.ready)
    #expect(model.installLine == "Read what it will do first.")
    #expect(ActionLook.opacity(enabled: model.canInstall) == ActionLook.disabledOpacity)
    client.script("definition", .value(M313F.definition))
    await model.readDefinition()
    #expect(model.installLine == nil)
    #expect(ActionLook.opacity(enabled: model.canInstall) == 1)
    let (live, _, _) = await M313M.selected(M313F.fanningOut)
    #expect(live.installLine == nil)
    // The sample at its end looks built, but its Install is drawn faded with the reason under it.
    let local = M313M.local()
    await local.refresh()
    await local.runSampleLoop()
    #expect(local.detail?.actions.offerInstall == true)
    #expect(ActionLook.opacity(enabled: local.canInstall) == ActionLook.disabledOpacity)
    #expect(local.installLine == "Installing needs the cloud.")
    #expect(ActionLook.disabledOpacity < 0.5)
  }

  // MARK: Finding 3: results stay with their build

  @Test("INSTALL: a definition read for one build never shows under another chosen while it was read")
  @MainActor func installDefinitionStaysWithItsBuild() async {
    let gate = M313Gate()
    let client = M313Client(gate: gate, gated: ["definition"])
    let store = MemoryBuildRecordStore([
      M313F.record(fixID: nil), M313F.record("b_two", name: "Weekly report", fixID: nil, at: "2026-11-22T10:00:00Z"),
    ])
    client.script("build", .value(M313F.ready), .value(M313F.ready))
    client.script("definition", .value(M313F.definition))
    let model = M313M.cloud(client, store: store)
    await model.refresh()
    let read = Task { await model.readDefinition() }
    await gate.arrival()
    await model.select("b_two")
    gate.open()
    await read.value
    #expect(model.selected == "b_two")
    #expect(model.installState.definition == nil)
    #expect(!model.canInstall)
  }

  @Test("INSTALL: an install that finishes after another build was chosen is kept on its record, not shown under the other")
  @MainActor func installStaysWithItsBuild() async {
    let gate = M313Gate()
    let client = M313Client(gate: gate, gated: ["deploy"])
    let store = MemoryBuildRecordStore([
      M313F.record(fixID: nil), M313F.record("b_two", name: "Weekly report", fixID: nil, at: "2026-11-22T10:00:00Z"),
    ])
    client.script("build", .value(M313F.ready), .value(M313F.ready))
    client.script("definition", .value(M313F.definition))
    client.script("deploy", .value(Deployed(routineID: "rt_1", version: 1)))
    client.fallback("build", .value(M313F.readyAs(.ready, deployed: true)))
    client.fallback("outcomes", .value([FixOutcome]()))
    let model = M313M.cloud(client, store: store)
    await model.refresh()
    await model.readDefinition()
    let install = Task { await model.install() }
    await gate.arrival()
    await model.select("b_two")
    gate.open()
    await install.value
    #expect(model.selected == "b_two")
    #expect(model.installState.installed == nil)
    #expect(model.installLine == "Read what it will do first.")
    #expect(store.record(M313F.buildID)?.routineID == "rt_1")
  }

  // MARK: Finding 4: Retrying only when offline, in the poll and the plan too

  @Test("POLL: a failure that reached Offload is said in words; signed out stops polling")
  @MainActor func pollErrorWords() async {
    let (model, client, _) = await M313M.selected(M313F.fanningOut)
    client.script("build", .error(M313F.server(500, "server_error")))
    #expect(await model.pollStep() == 2)
    #expect(model.connectionLine == "Offload had a problem. Try again later.")
    client.script("build", .error(M313F.server(401, "token_expired")))
    #expect(await model.pollStep() == nil)
    #expect(model.connectionLine == "This Mac needs to sign in again.")
    client.script("build", .error(M313F.offline))
    let (other, otherClient, _) = await M313M.selected(M313F.fanningOut)
    otherClient.script("build", .error(M313F.offline))
    #expect(await other.pollStep() == 2)
    #expect(other.connectionLine == "Can't reach Offload. Retrying.")
  }

  @Test("PLAN: a failed read of the opportunity is said in words, Retrying only when offline")
  @MainActor func planErrorWords() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("designing")))
    client.script("opportunity", .error(M313F.server(500, "server_error")), .error(M313F.offline))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(await model.planStep() == 5)
    #expect(model.connectionLine == "Offload had a problem. Try again later.")
    #expect(await model.planStep() == 5)
    #expect(model.connectionLine == "Can't reach Offload. Retrying.")
  }

  // MARK: Finding 5: the plan step after leaving, cancellation and a later plan

  @Test("PLAN: coming back to Builds while the fix is designed reads the opportunity again")
  @MainActor func planResumesOnAppear() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("designing")))
    client.fallback("opportunity", .value(M313F.opportunity("ready_for_approval")))
    client.fallback("fix", .value(M313F.fix))
    let model = M313M.cloud(client, sleeper: M313Sleeper(limit: 5))
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    model.disappear()
    model.appear(pending: nil)
    await model.startTask?.value
    await model.planTask?.value
    #expect(model.plan?.phase == .ready(M313F.fix))
    #expect(client.count("answer") == 1)
    model.disappear()
  }

  @Test("PLAN: leaving while the answer is on its way is not an error; the plan waits on the opportunity")
  @MainActor func planCancelledAnswer() async {
    let gate = M313Gate()
    let client = M313Client(gate: gate, gated: ["answer"])
    client.script("answer", .error(.transport(code: URLError.Code.cancelled.rawValue)))
    let model = M313M.cloud(client, sleeper: M313Sleeper(limit: 1))
    model.appear(pending: .opportunity(id: "opp_1", optionID: "fix_1"))
    let start = model.startTask
    await gate.arrival()
    model.disappear()
    gate.open()
    await start?.value
    #expect(model.plan?.phase == .designing)
    #expect(model.plan?.line == "Designing the fix…")
    #expect(model.plan?.message == nil)
  }

  @Test("PLAN: an earlier plan's failed answer does not stop a later plan")
  @MainActor func planEarlierFailureIgnored() async {
    let gate = M313Gate()
    let client = M313Client(gate: gate, gated: ["answer"])
    client.script("answer", .error(.badResponse(status: 502)), .value(M313F.opportunity("ready_for_approval")))
    client.fallback("fix", .value(M313F.fix))
    let model = M313M.cloud(client)
    let first = Task { await model.startPlan(opportunityID: "opp_1", optionID: "fix_1") }
    await gate.arrival()
    await model.startPlan(opportunityID: "opp_2", optionID: "fix_1")
    #expect(model.plan?.phase == .ready(M313F.fix))
    gate.open()
    await first.value
    #expect(model.plan?.opportunityID == "opp_2")
    #expect(model.plan?.phase == .ready(M313F.fix))
    #expect(model.plan?.message == nil)
  }

  // MARK: Finding 6: hours half to even (ADR 0022)

  @Test("SAVING: hours are shown to one decimal rounded half to even, as hs-1 shows them")
  func savingHalfEven() {
    func estimate(_ hours: Double) -> String? {
      var f = M313F.fix
      f.estimate = Figure(id: "fig_0000000000000006", value: hours, unit: "hours_per_week", arithmetic: "\(hours) h", evidence: [],
                          sourcePurgedAt: nil)
      return SavingLine.make(fix: f, installed: false, outcome: .notLoaded)?.text
    }
    #expect(estimate(1.25) == "saves 1.2 h/wk, estimated · measured for 4 weeks after you install")
    #expect(estimate(1.35) == "saves 1.4 h/wk, estimated · measured for 4 weeks after you install")
    #expect(estimate(0.05) == "saves 0.0 h/wk, estimated · measured for 4 weeks after you install")
    #expect(estimate(2.75) == "saves 2.8 h/wk, estimated · measured for 4 weeks after you install")
    // 0.75 × 100 min ÷ 60 = 1.25 h measured; 100 min ÷ 60 = 1.67 h estimated.
    #expect(SavingLine.make(fix: nil, installed: true, outcome: .found(M313F.outcome("on_track", ratio: "0.75", estimated: "100")))?.text
      == "saved 1.2 h/wk measured · 1.7 h estimated")
  }

  // MARK: Finding 8: provider names

  @Test("COPY: known providers keep their brand names; others are title-cased")
  func copyProviderNames() {
    #expect(BuildCopy.appName("github") == "GitHub")
    #expect(BuildCopy.appName("google_sheets") == "Google Sheets")
    #expect(BuildCopy.appName("hubspot") == "HubSpot")
    #expect(BuildCopy.appName("quickbooks") == "QuickBooks")
    #expect(BuildCopy.appName("slack") == "Slack")
    #expect(BuildCopy.appName("acme_crm") == "Acme Crm")
    #expect(BuildCopy.connectFirst(["github"]) == "Connect GitHub first.")
  }

  // MARK: Finding 9: the plan shows the fingerprint OK, build binds

  @Test("PLAN: the plan shows the brief's fingerprint, and the new one after the plan changed")
  @MainActor func planShowsFingerprint() async {
    #expect(PlanSummary.make(fix: M313F.fix, title: "PR pre-read tool").fingerprint == "fingerprint 7c41e2")
    #expect(PlanSummary.make(fix: M313F.changedFix, title: "PR pre-read tool").fingerprint == "fingerprint 9f00d1")
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("ready_for_approval")))
    client.script("fix", .value(M313F.fix), .value(M313F.changedFix))
    client.script("okBuild", .error(M313F.server(403, "hash_mismatch")))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(model.planSummary?.fingerprint == "fingerprint 7c41e2")
    await model.okBuild()
    #expect(model.planSummary?.fingerprint == "fingerprint 9f00d1")
  }

  // MARK: Finding 10: an ended build's time stands still

  @Test("BUDGET: an ended build without ended_at stops at its last stage's end, never counting on to now")
  func budgetEndedWithoutEnd() {
    let stage = BuildStage(name: "teeth_gate", state: .failed, startedAt: "2026-11-22T11:50:00.000Z",
                           endedAt: "2026-11-22T11:55:00.000Z", note: nil)
    let failed = M313F.build(.failed, stages: [stage], ended: nil)
    #expect(BudgetMeter(build: failed, now: M313F.date("2026-11-22T13:00:00Z")).text == "5m 00s · $0.00 of $4.00")
    #expect(BudgetMeter(build: failed, now: M313F.date("2026-11-23T13:00:00Z")).elapsedSeconds == 300)
    let noEnds = M313F.build(.cancelled, stages: [M313F.stage("teeth_gate", .running)], ended: nil)
    #expect(BudgetMeter(build: noEnds, now: M313F.date("2026-11-22T13:00:00Z")).elapsedSeconds == 0)
    // A live build still counts to now.
    #expect(BudgetMeter(build: M313F.build(.building, stages: [stage]), now: M313F.date("2026-11-22T12:00:00Z")).elapsedSeconds == 600)
  }
}
