import Foundation
import Testing
@testable import OffloadMac

// Review round 2 of m3-13 (logs/m3-13-mac-build-progress.review2.md). In the app, leaving Builds destroys the screen
// and its model, so the OK, build plan is kept in a store and a new model resumes it (finding 1); removing a gone
// build loads the next one (finding 3).

extension M313 {
  /// A second screen model over the same stores and client, as the app makes one each time Builds appears.
  @MainActor static func nextScreen(_ client: M313Client, store: MemoryBuildRecordStore, plans: MemoryPlanRecordStore,
                                    now: M313Now = M313Now()) -> BuildProgressModel {
    BuildProgressModel(mode: M313F.cloudMode, client: client, store: store, plans: plans, sleeper: M313Sleeper(limit: 5),
                       now: { now.date }, timeZone: M313F.utc)
  }

  @Test("PLAN: a plan waiting on its fix survives leaving Builds; the next screen resumes it without answering again")
  @MainActor func keptPlanResumes() async {
    let client = M313Client()
    let store = MemoryBuildRecordStore()
    let plans = MemoryPlanRecordStore()
    client.script("answer", .value(M313F.opportunity("designing")))
    client.fallback("opportunity", .value(M313F.opportunity("ready_for_approval")))
    client.fallback("fix", .value(M313F.fix))
    let first = M313M.cloud(client, store: store, plans: plans)
    await first.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(plans.load() == KeptPlan(opportunityID: "opp_1", optionID: "fix_1", fixID: "fix_1", title: "PR pre-read tool",
                                     startedAt: M313F.date("2026-11-22T12:00:00Z")))
    first.disappear()
    let second = Self.nextScreen(client, store: store, plans: plans)
    #expect(second.plan == nil)
    second.appear(pending: nil)
    await second.startTask?.value
    await second.planTask?.value
    #expect(second.plan?.phase == .ready(M313F.fix))
    #expect(second.plan?.title == "PR pre-read tool")
    #expect(client.count("answer") == 1)
    second.disappear()
  }

  @Test("PLAN: a plan cut off while its answer was on its way resumes on the next screen from the opportunity")
  @MainActor func keptPlanCutOffWhileAnswering() async {
    let gate = M313Gate()
    let client = M313Client(gate: gate, gated: ["answer"])
    let store = MemoryBuildRecordStore()
    let plans = MemoryPlanRecordStore()
    client.script("answer", .error(.transport(code: URLError.Code.cancelled.rawValue)))
    client.fallback("opportunity", .value(M313F.opportunity("ready_for_approval")))
    client.fallback("fix", .value(M313F.fix))
    let first = M313M.cloud(client, store: store, plans: plans, sleeper: M313Sleeper(limit: 1))
    first.appear(pending: .opportunity(id: "opp_1", optionID: "fix_1"))
    let start = first.startTask
    await gate.arrival()
    #expect(plans.load()?.opportunityID == "opp_1")
    first.disappear()
    gate.open()
    await start?.value
    let second = Self.nextScreen(client, store: store, plans: plans)
    second.appear(pending: nil)
    await second.startTask?.value
    await second.planTask?.value
    #expect(second.plan?.phase == .ready(M313F.fix))
    #expect(client.count("answer") == 1)
    second.disappear()
  }

  @Test("PLAN: a ready plan kept longer than 10 minutes is read again and shown, not cut off as too long")
  @MainActor func keptPlanReadyAfterTenMinutes() async {
    let client = M313Client()
    let store = MemoryBuildRecordStore()
    let plans = MemoryPlanRecordStore()
    let now = M313Now()
    client.script("answer", .value(M313F.opportunity("ready_for_approval")))
    client.fallback("opportunity", .value(M313F.opportunity("ready_for_approval")))
    client.fallback("fix", .value(M313F.fix))
    let first = M313M.cloud(client, store: store, plans: plans, now: now)
    await first.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(first.plan?.phase == .ready(M313F.fix))
    first.disappear()
    now.advance(900)
    let second = Self.nextScreen(client, store: store, plans: plans, now: now)
    second.appear(pending: nil)
    await second.startTask?.value
    await second.planTask?.value
    #expect(second.plan?.phase == .ready(M313F.fix))
    #expect(second.canOKBuild)
    second.disappear()
  }

  @Test("PLAN: the kept plan is cleared once OK, build is accepted, on Not now, when it stops and when already running; kept after 10 minutes")
  @MainActor func keptPlanCleared() async {
    // Accepted (202).
    let accepted = M313Client()
    accepted.script("answer", .value(M313F.opportunity("ready_for_approval")))
    accepted.script("fix", .value(M313F.fix))
    accepted.script("okBuild", .value(BuildStarted(buildID: "b_new")))
    accepted.script("build", .value(M313F.fanningOut))
    let plans1 = MemoryPlanRecordStore()
    let m1 = M313M.cloud(accepted, plans: plans1)
    await m1.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(plans1.load() != nil)
    await m1.okBuild()
    #expect(plans1.load() == nil)

    // Not now.
    let notNow = M313Client()
    notNow.script("answer", .value(M313F.opportunity("designing")))
    let plans2 = MemoryPlanRecordStore()
    let m2 = M313M.cloud(notNow, plans: plans2)
    await m2.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(plans2.load() != nil)
    m2.dismissPlan()
    #expect(plans2.load() == nil)

    // Stopped.
    let stopped = M313Client()
    stopped.script("answer", .error(M313F.server(500, "server_error")))
    let plans3 = MemoryPlanRecordStore()
    let m3 = M313M.cloud(stopped, plans: plans3)
    await m3.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(m3.plan?.phase == .stopped)
    #expect(plans3.load() == nil)

    // Too long.
    let slow = M313Client()
    let now = M313Now()
    slow.script("answer", .value(M313F.opportunity("designing")))
    let plans4 = MemoryPlanRecordStore()
    let m4 = M313M.cloud(slow, plans: plans4, now: now)
    await m4.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    now.advance(601)
    #expect(await m4.planStep() == nil)
    #expect(m4.plan?.phase == .tooLong)
    // Too long stops the poll but keeps the plan, so "Check back later" can be kept (review3.md finding 1).
    #expect(plans4.load() != nil)

    // Already running.
    let running = M313Client()
    running.script("answer", .value(M313F.opportunity("ready_for_approval")))
    running.script("fix", .value(M313F.fix))
    running.script("okBuild", .error(M313F.server(409, "already_running")))
    let plans5 = MemoryPlanRecordStore()
    let m5 = M313M.cloud(running, plans: plans5)
    await m5.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    await m5.okBuild()
    #expect(plans5.load() == nil)
  }

  @Test("PLAN: the UserDefaults plan store round-trips, clears, and reads an unreadable value as none; .local keeps nothing")
  @MainActor func keptPlanStore() async {
    let suite = "m313-plan-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let kept = KeptPlan(opportunityID: "opp_1", optionID: nil, fixID: "fix_1", title: "PR pre-read tool",
                        startedAt: M313F.date("2026-11-22T12:00:00Z"))
    UserDefaultsPlanRecordStore(defaults: defaults).save(kept)
    #expect(UserDefaultsPlanRecordStore(defaults: defaults).load() == kept)
    UserDefaultsPlanRecordStore(defaults: defaults).clear()
    #expect(UserDefaultsPlanRecordStore(defaults: defaults).load() == nil)
    #expect(defaults.data(forKey: UserDefaultsPlanRecordStore.key) == nil)
    defaults.set(Data("not json".utf8), forKey: UserDefaultsPlanRecordStore.key)
    #expect(UserDefaultsPlanRecordStore(defaults: defaults).load() == nil)

    let plans = MemoryPlanRecordStore()
    let local = BuildProgressModel(mode: .local, client: nil, store: MemoryBuildRecordStore(), plans: plans,
                                   sleeper: M313Sleeper(), timeZone: M313F.utc)
    local.appear(pending: .opportunity(id: "opp_1", optionID: "fix_1"))
    await local.startPlan(opportunityID: "opp_1", optionID: "fix_1")
    #expect(plans.load() == nil)
    local.disappear()
  }

  @Test("LIST: removing a gone build selects the next one and loads it (its fix, its detail)")
  @MainActor func removeLoadsNext() async {
    let store = MemoryBuildRecordStore([
      M313F.record(fixID: nil),
      M313F.record("b_two", name: "Weekly report", fixID: "fix_1", at: "2026-11-22T10:00:00Z"),
    ])
    let client = M313Client()
    // b_two's first read fails, so it was never loaded when the gone build is removed (review3.md finding 2).
    client.script("build", .error(.notFound), .error(M313F.offline), .value(M313F.fanningOut))
    client.fallback("fix", .value(M313F.fix))
    let model = M313M.cloud(client, store: store)
    await model.refresh()
    #expect(model.selected == "b_two")
    #expect(model.detail == nil)
    // Choose the gone one, then remove it.
    await model.select(M313F.buildID)
    #expect(model.detail == nil)
    let before = client.count("build b_two")
    await model.remove(buildID: M313F.buildID)
    #expect(client.count("build b_two") == before + 1)
    #expect(model.selected == "b_two")
    #expect(model.detail?.title == "Building · Weekly report")
    #expect(model.detail?.steps.first?.detail == "what it builds and what it must not touch · fingerprint 7c41e2")
    #expect(model.builds.map(\.id) == ["b_two"])
  }
}
