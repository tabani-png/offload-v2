import Foundation
import Testing
@testable import OffloadMac

// Review round 4 of m3-13 (logs/m3-13-mac-build-progress.review4.md): a design that stopped (`needs_you`) is said so
// and an unknown state keeps waiting, the fix is read only in `ready_for_approval` (finding 2); Not now posts the
// glossary's answer and a failure keeps the plan (finding 3); the capped headline names the build's own cap (finding 8).

extension M313 {
  @Test("PLAN: needs_you says the design stopped and needs the person, reads no fix and drops the kept plan")
  @MainActor func planNeedsYou() async {
    let client = M313Client()
    let plans = MemoryPlanRecordStore()
    client.script("answer", .value(M313F.opportunity("needs_you")))
    client.fallback("fix", .value(M313F.fix))
    let model = M313M.cloud(client, plans: plans)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(model.plan?.phase == .stopped)
    #expect(model.plan?.message == "Designing this fix stopped and needs you. Nothing is built until then.")
    #expect(!model.canOKBuild)
    #expect(client.count("fix") == 0)
    #expect(plans.load() == nil)

    // A kept plan whose design stopped since.
    let later = M313Client()
    let kept = MemoryPlanRecordStore(KeptPlan(opportunityID: "opp_1", optionID: "fix_1", fixID: "fix_1",
                                              title: "PR pre-read tool", startedAt: M313F.date("2026-11-22T12:00:00Z")))
    later.fallback("opportunity", .value(M313F.opportunity("needs_you")))
    later.fallback("fix", .value(M313F.fix))
    let screen = Self.nextScreen(later, store: MemoryBuildRecordStore(), plans: kept)
    screen.appear(pending: nil)
    await screen.startTask?.value
    #expect(screen.plan?.phase == .stopped)
    #expect(later.count("fix") == 0)
    #expect(kept.load() == nil)
    screen.disappear()
  }

  @Test("PLAN: the fix is read only in ready_for_approval; an unknown state keeps waiting without reading it")
  @MainActor func planUnknownStateWaits() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("teleporting")))
    client.script("opportunity", .value(M313F.opportunity("teleporting")), .value(M313F.opportunity("ready_for_approval")))
    client.fallback("fix", .value(M313F.fix))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(model.plan?.phase == .designing)
    #expect(model.plan?.line == "Designing the fix…")
    #expect(await model.planStep() == 5)
    #expect(client.count("fix") == 0)
    #expect(await model.planStep() == nil)
    #expect(model.plan?.phase == .ready(M313F.fix))
    #expect(client.count("fix") == 1)
  }

  @Test("PLAN: a Not now that fails keeps the plan and the kept plan, and says why")
  @MainActor func planNotNowFails() async {
    let client = M313Client()
    let plans = MemoryPlanRecordStore()
    client.script("answer", .value(M313F.opportunity("designing")), .error(M313F.server(500, "server_error")))
    let model = M313M.cloud(client, plans: plans)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    await model.setAside()
    #expect(client.calls.last == "answer opp_1 not_now -")
    #expect(model.plan?.phase == .designing)
    #expect(model.plan?.message == "Offload had a problem. Try again later.")
    #expect(plans.load() != nil)
    #expect(model.notice == nil)
    #expect(BuildCopy.notNow == "Not now")
    #expect(BuildCopy.close == "Close")
  }

  @Test("HEADLINE: the capped headline names the build's own cap, as the meter does")
  func headlineCapFromBuild() {
    #expect(HeadlineMap.headline(.capped, capUSD: 5) == "It reached the $5.00 cap. Nothing was installed.")
    #expect(HeadlineMap.headline(.capped) == "It reached the $4.00 cap. Nothing was installed.")
    var b = M313F.readyAs(.capped)
    b.capUSD = 5
    b.spentUSD = 5
    let detail = BuildDetail.make(build: b, fix: nil, outcome: .notLoaded, now: M313F.date("2026-11-22T13:00:00Z"), name: "PR pre-read tool")
    #expect(detail.headline == "It reached the $5.00 cap. Nothing was installed.")
    #expect(detail.meter.text == "6m 12s · $5.00 of $5.00")
  }
}
