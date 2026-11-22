import Foundation
import Testing
@testable import OffloadMac

// Review 1 of m3-13: a second hand-off cancels the first before it posts; only offline reads say "Retrying"; an empty
// needs_connection keeps designing; screen words for VoiceOver live in BuildCopy.

extension M313 {
  @Test("HANDOFF: a second hand-off cancels the first before it answers anything")
  @MainActor func handOffSecondCancelsFirst() async {
    let client = M313Client()
    client.fallback("answer", .value(M313F.opportunity("ready_for_approval")))
    client.fallback("fix", .value(M313F.fix))
    let model = M313M.cloud(client, sleeper: M313Sleeper(limit: 1))
    model.appear(pending: .opportunity(id: "opp_1", optionID: "fix_1"))
    let first = model.startTask
    model.appear(pending: .opportunity(id: "opp_2", optionID: "fix_1"))
    await first?.value
    await model.startTask?.value
    model.disappear()
    #expect(client.count("answer opp_1") == 0)
    #expect(client.count("answer opp_2") == 1)
    #expect(model.plan?.opportunityID == "opp_2")
  }

  @Test("STATES: a read that reached Offload and failed says so in words, not Retrying")
  @MainActor func statesServerErrorNotOffline() async {
    let client = M313Client()
    client.script("build", .error(M313F.server(500, "server_error")))
    let model = M313M.cloud(client, store: MemoryBuildRecordStore([M313F.record(fixID: nil)]))
    await model.refresh()
    #expect(model.connectionLine == "Offload had a problem. Try again later.")
  }

  @Test("PLAN: needs_connection without apps keeps designing and reads no fix")
  @MainActor func planEmptyNeedsConnection() async {
    let client = M313Client()
    client.script("answer", .value(M313F.opportunity("needs_connection")))
    client.fallback("fix", .value(M313F.fix))
    let model = M313M.cloud(client)
    await model.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(model.plan?.phase == .designing)
    #expect(client.count("fix") == 0)
  }

  @Test("COPY: the dot and step words read by VoiceOver come from BuildCopy")
  func copyDotWords() {
    #expect(BuildCopy.dotWord(.waiting) == "waiting")
    #expect(BuildCopy.dotWord(.working) == "working")
    #expect(BuildCopy.dotWord(.needsYou) == "needs you")
    #expect(BuildCopy.dotWord(.done) == "done")
    #expect(BuildCopy.dotWord(.failedCheck) == "failed")
    #expect(BuildCopy.stepWord(.failed) == "failed")
    #expect(BuildCopy.all.contains("needs you"))
  }
}
