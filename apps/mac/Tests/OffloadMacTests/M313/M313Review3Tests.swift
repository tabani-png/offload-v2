import Foundation
import Testing
@testable import OffloadMac

// Review round 3 of m3-13 (logs/m3-13-mac-build-progress.review3.md): a plan past 10 minutes is kept and shown again
// once ready (finding 1); a kept plan whose opportunity moved on is not offered for building (finding 3); a plan can be
// dropped in every phase but starting (finding 4).

extension M313 {
  @Test("PLAN: a plan that took longer than 10 minutes and is ready on a later screen shows OK, build")
  @MainActor func tooLongThenReady() async {
    let client = M313Client()
    let store = MemoryBuildRecordStore()
    let plans = MemoryPlanRecordStore()
    let now = M313Now()
    client.script("answer", .value(M313F.opportunity("designing")))
    client.script("opportunity", .value(M313F.opportunity("ready_for_approval")))
    client.fallback("fix", .value(M313F.fix))
    let first = M313M.cloud(client, store: store, plans: plans, now: now)
    await first.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    now.advance(601)
    #expect(await first.planStep() == nil)
    #expect(first.plan?.phase == .tooLong)
    #expect(first.plan?.line == "Still designing. Check back later.")
    first.disappear()
    now.advance(3_600)
    let second = Self.nextScreen(client, store: store, plans: plans, now: now)
    second.appear(pending: nil)
    await second.startTask?.value
    await second.planTask?.value
    #expect(second.plan?.phase == .ready(M313F.fix))
    #expect(second.canOKBuild)
    #expect(client.count("answer") == 1)
    second.disappear()
  }

  @Test("PLAN: waiting on a connection past 10 minutes keeps saying which app to connect, and keeps the plan")
  @MainActor func needsConnectionPastTenMinutes() async {
    let client = M313Client()
    let plans = MemoryPlanRecordStore()
    let now = M313Now()
    client.script("answer", .value(M313F.opportunity("needs_connection", missing: ["github"])))
    let model = M313M.cloud(client, plans: plans, now: now)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    now.advance(601)
    #expect(await model.planStep() == nil)
    #expect(model.plan?.phase == .needsConnection(["github"]))
    #expect(model.plan?.line == "Connect GitHub first.")
    #expect(plans.load() != nil)
    #expect(client.count("opportunity") == 0)
  }

  @Test("PLAN: a kept plan whose suggestion was set aside or already built is stopped with a sentence, not offered again")
  @MainActor func keptPlanMovedOn() async {
    let cases: [(String, String)] = [
      ("never", "This suggestion was set aside, so nothing is built."),
      ("not_now", "This suggestion was set aside, so nothing is built."),
      ("left_alone", "This suggestion was set aside, so nothing is built."),
      ("building", "This suggestion is already being built or was built."),
      ("ready_to_ship", "This suggestion is already being built or was built."),
      ("shipped", "This suggestion is already being built or was built."),
      ("build_failed", "Its last build didn't pass. Nothing was installed."),
    ]
    for (state, line) in cases {
      let client = M313Client()
      let plans = MemoryPlanRecordStore(KeptPlan(opportunityID: "opp_1", optionID: "fix_1", fixID: "fix_1",
                                                 title: "PR pre-read tool", startedAt: M313F.date("2026-11-22T12:00:00Z")))
      client.fallback("opportunity", .value(M313F.opportunity(state)))
      client.fallback("fix", .value(M313F.fix))
      let model = Self.nextScreen(client, store: MemoryBuildRecordStore(), plans: plans)
      model.appear(pending: nil)
      await model.startTask?.value
      #expect(model.plan?.phase == .stopped, "\(state)")
      #expect(model.plan?.message == line, "\(state)")
      #expect(!model.canOKBuild)
      #expect(client.count("fix") == 0, "\(state)")
      #expect(plans.load() == nil, "\(state)")
      model.disappear()
    }
  }

  @Test("PLAN: Not now is offered in every phase but starting, and does nothing while OK, build is on its way")
  @MainActor func notNowEveryPhase() async {
    // Designing.
    let designing = M313Client()
    designing.script("answer", .value(M313F.opportunity("designing")))
    let m1 = M313M.cloud(designing)
    await m1.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(m1.canDismissPlan)
    // Needs a connection.
    let connect = M313Client()
    connect.script("answer", .value(M313F.opportunity("needs_connection", missing: ["github"])))
    let m2 = M313M.cloud(connect)
    await m2.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(m2.canDismissPlan)
    // Stopped.
    let failed = M313Client()
    failed.script("answer", .error(M313F.server(500, "server_error")))
    let m3 = M313M.cloud(failed)
    await m3.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(m3.plan?.phase == .stopped)
    #expect(m3.canDismissPlan)
    m3.dismissPlan()
    #expect(m3.plan == nil)
    // Starting: OK, build is on its way and cannot be dropped.
    let gate = M313Gate()
    let starting = M313Client(gate: gate, gated: ["okBuild"])
    starting.script("answer", .value(M313F.opportunity("ready_for_approval")))
    starting.script("fix", .value(M313F.fix))
    starting.script("okBuild", .value(BuildStarted(buildID: "b_new")))
    starting.script("build", .value(M313F.fanningOut))
    let m4 = M313M.cloud(starting)
    await m4.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(m4.canDismissPlan)
    let press = Task { await m4.okBuild() }
    await gate.arrival()
    #expect(m4.plan?.phase == .starting)
    #expect(!m4.canDismissPlan)
    m4.dismissPlan()
    #expect(m4.plan?.phase == .starting)
    gate.open()
    await press.value
    #expect(m4.selected == "b_new")
    #expect(m4.plan == nil)
  }
}
