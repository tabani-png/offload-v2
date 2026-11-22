import Foundation
import Testing
@testable import OffloadMac

// Review round 6 of m3-13 (logs/m3-13-mac-build-progress.review6.md): a plan whose opportunity is still `open` never
// reached Offload, so it is stopped with a sentence instead of "Designing the fix…" (finding 2).

extension M313 {
  @Test("PLAN: a kept plan whose opportunity is still open says OK, build didn't reach Offload, reads no fix and drops the plan")
  @MainActor func keptPlanStillOpen() async {
    let client = M313Client()
    let plans = MemoryPlanRecordStore(KeptPlan(opportunityID: "opp_1", optionID: "fix_1", fixID: "fix_1",
                                               title: "PR pre-read tool", startedAt: M313F.date("2026-11-22T12:00:00Z")))
    client.fallback("opportunity", .value(M313F.opportunity("open")))
    client.fallback("fix", .value(M313F.fix))
    let model = Self.nextScreen(client, store: MemoryBuildRecordStore(), plans: plans)
    model.appear(pending: nil)
    await model.startTask?.value
    #expect(model.plan?.phase == .stopped)
    #expect(model.plan?.message == "Your OK, build didn't reach Offload. Press OK, build in Today again.")
    #expect(model.plan?.line == nil)
    #expect(client.count("fix") == 0)
    #expect(plans.load() == nil)
    model.disappear()
  }

  @Test("PLAN: a poll that finds the opportunity open stops the plan with the same sentence")
  @MainActor func pollFindsOpen() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("chosen")))
    client.script("opportunity", .value(M313F.opportunity("open")))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(model.plan?.phase == .designing)
    #expect(await model.planStep() == nil)
    #expect(model.plan?.phase == .stopped)
    #expect(model.plan?.message == "Your OK, build didn't reach Offload. Press OK, build in Today again.")
  }
}
