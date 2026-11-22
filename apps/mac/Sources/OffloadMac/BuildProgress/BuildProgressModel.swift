import Foundation

// Build progress's state (SPEC m3-13 "BuildProgressModel"). In `.cloud` it reads and posts the builds API through
// m3-10's BuildsClient: the builds started on this Mac, the OK, build step from a hand-off, the poll of a live build,
// the deploy approval and the measured saving. In `.local` there is no client and no builder: it plays the labelled
// sample and never stores it. The two exact-hash approvals post exactly the hashes read and shown, only when the
// person presses the button, never again by themselves; a mismatch always reads again first (ADR 0004, ADR 0032).
//
// The timed loops (the build poll every 2 s, the plan poll every 5 s, the sample's 100 ms ticks) are steps that
// return the next delay or nil, run over an injected sleeper, so tests drive them without waiting.

/// Waits between loop steps. The app uses `TaskSleeper`; tests record the delays.
public protocol BuildSleeper: Sendable {
  func sleep(seconds: Double) async throws
}

public struct TaskSleeper: BuildSleeper {
  public init() {}
  public func sleep(seconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
  }
}

// MARK: List rows

public enum BuildRowState: Equatable, Sendable {
  /// Not read yet (or Offload could not be reached).
  case loading
  case build(BuildState, deployed: Bool)
  /// 404: the build is no longer available.
  case gone
  /// The labelled sample (`.local` only).
  case sample
}

public struct BuildRow: Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var state: BuildRowState
  /// "started 22 Nov, 11:50" in the person's time zone.
  public var started: String?
  public var dot: StatusDot

  public init(id: String, name: String, state: BuildRowState, started: String?, dot: StatusDot) {
    self.id = id
    self.name = name
    self.state = state
    self.started = started
    self.dot = dot
  }

  public var line: String {
    switch state {
    case .loading: return BuildCopy.checking
    case .build(let s, let deployed): return BuildCopy.stateWord(s, deployed: deployed)
    case .gone: return BuildCopy.gone
    case .sample: return BuildCopy.sampleRowLine
    }
  }

  /// Only a build that is gone can be removed from the list.
  public var canRemove: Bool { state == .gone }
  public var isSample: Bool { state == .sample }
}

// MARK: OK, build

public enum PlanPhase: Equatable, Sendable {
  /// `POST /v1/opportunities/{id}/answer` is on its way.
  case answering
  /// The fix is being designed; the opportunity is read every 5 s.
  case designing
  /// The opportunity waits for these providers to be connected.
  case needsConnection([String])
  /// 10 minutes passed while designing.
  case tooLong
  /// The fix as read: its plan, estimate and the four hashes OK, build will post.
  case ready(Fix)
  /// OK, build was pressed and is on its way.
  case starting
  /// It cannot go on (an error, or no fix to build).
  case stopped
}

public struct PlanState: Equatable, Sendable {
  public var opportunityID: String
  public var optionID: String?
  /// The option's id is its fix id (`FixOption.id`).
  public var fixID: String?
  public var title: String
  public var phase: PlanPhase
  /// The state line under the title ("Designing the fix…").
  public var line: String?
  /// What the last press led to ("The plan changed. Read it again.").
  public var message: String?
  public var startedAt: Date
}

/// What the plan panel shows for a fix: its summary, the estimate labelled estimated, and the cap OK, build posts.
public struct PlanSummary: Equatable, Sendable {
  public var summary: String
  public var estimate: String?
  public var cap: String
  /// "fingerprint 7c41e2": the brief whose hashes OK, build posts (review1.md finding 9).
  public var fingerprint: String

  public init(summary: String, estimate: String?, cap: String, fingerprint: String) {
    self.summary = summary
    self.estimate = estimate
    self.cap = cap
    self.fingerprint = fingerprint
  }

  public static func make(fix: Fix, title: String) -> PlanSummary {
    let candidates = [fix.brief["summary"]?.stringValue, fix.brief["title"]?.stringValue, title]
    let summary = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? BuildCopy.unnamed
    let estimate = fix.estimate.flatMap(WeeklyHours.of).map { BuildCopy.savesEstimated(Decimals.hours($0)) }
    return PlanSummary(summary: summary, estimate: estimate, cap: BuildCopy.buildCap(Money.usd(FixHashes.defaultCapUSD)),
                       fingerprint: BuildCopy.fingerprint(StepMapping.fingerprint(fix.briefHash)))
  }
}

// MARK: Install

public struct InstallState: Equatable, Sendable {
  /// The definition read by See what changed; Install posts its hash.
  public var definition: BuildDefinition?
  /// The 201 of the deploy approval.
  public var installed: Deployed?
  public var busy = false
  public var message: String?

  public init() {}
}

// MARK: Model

@MainActor
public final class BuildProgressModel: ObservableObject {
  public static let pollSeconds: Double = 2
  public static let planSeconds: Double = 5
  public static let planLimitSeconds: Double = 600

  /// The wait after `errors` failed polls in a row: 2, 4, 8 … at most 60 s.
  public static func backoff(_ errors: Int) -> Double {
    guard errors > 0 else { return pollSeconds }
    return min(60, pow(2, Double(min(errors, 16))))
  }

  @Published public private(set) var builds: [BuildRow] = []
  @Published public private(set) var selected: String?
  @Published public private(set) var detail: BuildDetail?
  @Published public private(set) var plan: PlanState? {
    // Kept across screens: leaving Builds destroys this model (review2.md finding 1).
    didSet { persistPlan() }
  }
  @Published public private(set) var installState = InstallState()
  /// A line above the detail: the hand-off's needs-cloud line, already running, a cancel error.
  @Published public private(set) var notice: String?
  /// "Can't reach Offload. Retrying." while reads fail.
  @Published public private(set) var connectionLine: String?
  /// "No builds yet…" in `.cloud` with nothing started on this Mac.
  @Published public private(set) var emptyLine: String?
  @Published public private(set) var sampleTick = 0
  /// Set by the view from the system's Reduce Motion: the sample shows its final state at once.
  @Published public var reduceMotion = false

  /// `.sample` in `.local`, `.cloud` otherwise; the two never mix.
  public let provenance: DataProvenance
  public let isLocal: Bool
  public private(set) var isActive = false
  public private(set) var startTask: Task<Void, Never>?

  /// The plan poll's loop while the fix is designed (readable for tests).
  public private(set) var planTask: Task<Void, Never>?
  private var pollTask: Task<Void, Never>?
  private var sampleTask: Task<Void, Never>?
  private var loopsEnabled = false
  private var busy = false

  private let client: (any BuildsClient)?
  private let store: any BuildRecordStore
  private let plans: any PlanRecordStore
  private let sleeper: any BuildSleeper
  private let now: @Sendable () -> Date
  private let timeZone: TimeZone

  private var cache: [String: Build] = [:]
  private var fixes: [String: Fix] = [:]
  private var gone: Set<String> = []
  private var outcomes: [String: OutcomeLookup] = [:]
  private var pollErrors = 0

  public init(mode: BackendMode, client: (any BuildsClient)?, store: any BuildRecordStore,
              plans: any PlanRecordStore = MemoryPlanRecordStore(),
              sleeper: any BuildSleeper = TaskSleeper(), now: @escaping @Sendable () -> Date = { Date() },
              timeZone: TimeZone = .current) {
    isLocal = mode.isLocal
    provenance = mode.isLocal ? .sample : .cloud
    self.client = mode.isLocal ? nil : client
    self.store = store
    self.plans = plans
    self.sleeper = sleeper
    self.now = now
    self.timeZone = timeZone
    if isLocal { loadSample() }
  }

  /// The app's model: m3-10's backends and the builds started on this Mac.
  public convenience init(backends: Backends, store: any BuildRecordStore, plans: any PlanRecordStore) {
    self.init(mode: backends.mode, client: backends.builds, store: store, plans: plans)
  }

  // MARK: What the buttons may do

  public var canOKBuild: Bool {
    guard !busy, let phase = plan?.phase, case .ready = phase else { return false }
    return true
  }

  public var canReadDefinition: Bool {
    !isLocal && client != nil && detail?.actions.offerInstall == true && !installState.busy && installState.installed == nil
  }

  /// Install is enabled only after the definition was read.
  public var canInstall: Bool { canReadDefinition && installState.definition != nil }

  public var canCancel: Bool { !isLocal && client != nil && detail?.actions.offerCancel == true }

  /// The line next to Install, on screen (not only a tooltip): why it is off, or what happened (review1.md finding 2).
  public var installLine: String? {
    if isLocal { return BuildCopy.installNeedsCloud }
    if let installed = installState.installed { return BuildCopy.installed(version: installed.version) }
    if let message = installState.message { return message }
    if detail?.actions.offerInstall == true, installState.definition == nil { return BuildCopy.readFirst }
    return nil
  }

  /// What the plan panel shows while the plan is ready: summary, estimate, cap and the brief's fingerprint.
  public var planSummary: PlanSummary? {
    guard let p = plan, case .ready(let fix) = p.phase else { return nil }
    return PlanSummary.make(fix: fix, title: p.title)
  }

  // MARK: Lifecycle

  /// Lets the steps run. `appear` calls it; tests call it to drive the steps by hand.
  public func activate() { isActive = true }

  /// Reads the hand-off once (it is cleared), then appears.
  public func appear(navigation: NavigationModel) {
    appear(pending: navigation.takePendingBuild())
  }

  /// The screen appeared: take the hand-off and start the loops.
  public func appear(pending: BuildRequest?) {
    activate()
    loopsEnabled = true
    notice = nil
    if isLocal {
      loadSample()
      switch pending {
      case .localRepeat(_, let name, _)?: notice = BuildCopy.repeatNeedsCloud(name)
      case .opportunity?: notice = BuildCopy.opportunityNeedsCloud
      case nil: break
      }
      restartSample()
      return
    }
    if case .localRepeat(_, let name, _)? = pending { notice = BuildCopy.repeatCountedHere(name) }
    startTask?.cancel()
    startTask = Task { [weak self] in await self?.startCloud(pending) }
  }

  /// The screen went away: every loop stops and every step returns nil.
  public func disappear() {
    isActive = false
    loopsEnabled = false
    startTask?.cancel()
    planTask?.cancel()
    pollTask?.cancel()
    sampleTask?.cancel()
    planTask = nil
    pollTask = nil
    sampleTask = nil
  }

  /// Checks for cancellation after every wait: a later hand-off cancels this one, which then posts nothing
  /// (pre-review finding 4).
  private func startCloud(_ pending: BuildRequest?) async {
    guard !Task.isCancelled else { return }
    await refresh()
    guard !Task.isCancelled else { return }
    if case .opportunity(let id, let optionID)? = pending {
      await startPlan(opportunityID: id, optionID: optionID)
      guard !Task.isCancelled else { return }
    } else if plan == nil, let kept = plans.load() {
      // A plan kept by an earlier screen (review2.md finding 1).
      await resumePlan(kept)
      guard !Task.isCancelled else { return }
    }
    // Also resumes a plan that was waiting when the screen went away (review1.md finding 5).
    restartPlanLoop()
    restartPolling()
  }

  // MARK: List

  /// Reads every build started on this Mac (`.cloud`), or shows the sample (`.local`).
  public func refresh() async {
    if isLocal {
      loadSample()
      return
    }
    guard let client else { return }
    let records = store.records()
    var failure: (any Error)?
    for record in records {
      do {
        let build = try await client.build(id: record.buildID)
        cache[record.buildID] = build
        gone.remove(record.buildID)
      } catch APIError.notFound {
        gone.insert(record.buildID)
        cache[record.buildID] = nil
      } catch {
        failure = error
      }
    }
    connectionLine = failure.map { connectionWords($0) }
    rebuildRows()
    if selected == nil || !records.contains(where: { $0.buildID == selected }) {
      selected = records.first(where: { !gone.contains($0.buildID) })?.buildID ?? records.first?.buildID
      installState = InstallState()
    }
    await loadSelected()
  }

  public func select(_ id: String) async {
    guard !isLocal, store.record(id) != nil else { return }
    if selected != id { installState = InstallState() }
    selected = id
    await loadSelected()
    restartPolling()
  }

  /// Removes a build that is gone from the list on this Mac.
  public func remove(buildID: String) async {
    guard !isLocal else { return }
    store.remove(buildID: buildID)
    cache[buildID] = nil
    gone.remove(buildID)
    outcomes[buildID] = nil
    rebuildRows()
    if selected == buildID {
      // The next build is chosen as a person would choose it: loaded and polled (review2.md finding 3).
      selected = nil
      installState = InstallState()
      if let next = store.records().first?.buildID {
        await select(next)
        return
      }
    }
    recompute()
  }

  private func rebuildRows() {
    guard !isLocal else { return }
    let records = store.records()
    builds = records.map { r in
      let state: BuildRowState
      let dot: StatusDot
      if gone.contains(r.buildID) {
        state = .gone
        dot = .needsYou
      } else if let b = cache[r.buildID] {
        state = .build(b.state, deployed: b.deployed)
        dot = HeadlineMap.dot(b)
      } else {
        state = .loading
        dot = .waiting
      }
      return BuildRow(id: r.buildID, name: r.name, state: state,
                      started: BuildCopy.started(BuildTime.started(r.startedAt, timeZone: timeZone)), dot: dot)
    }
    emptyLine = records.isEmpty ? BuildCopy.noBuilds : nil
  }

  private func loadSelected() async {
    guard let id = selected, let record = store.record(id) else {
      recompute()
      return
    }
    if let client, let fixID = record.fixID, fixes[fixID] == nil {
      if let fix = try? await client.fix(id: fixID) { fixes[fixID] = fix }
    }
    if cache[id]?.deployed == true { await loadOutcome(id) }
    recompute()
  }

  private func loadOutcome(_ id: String) async {
    guard let client, let record = store.record(id), let routine = record.routineID else {
      outcomes[id] = .missing
      return
    }
    do {
      let list = try await client.outcomes(month: BuildTime.month(record.installedAt ?? now()))
      outcomes[id] = list.first(where: { $0.routineID == routine }).map(OutcomeLookup.found) ?? .missing
    } catch APIError.notFound {
      outcomes[id] = .routeMissing
    } catch {
      outcomes[id] = .notLoaded
    }
  }

  private func recompute() {
    if isLocal {
      detail = BuildDetail.sample(tick: sampleTick)
      return
    }
    guard let id = selected, let build = cache[id], !gone.contains(id) else {
      detail = nil
      return
    }
    let record = store.record(id)
    let fix = record?.fixID.flatMap { fixes[$0] }
    detail = BuildDetail.make(build: build, fix: fix, outcome: outcomes[id] ?? .notLoaded, now: now(), name: record?.name ?? "")
  }

  // MARK: Poll

  /// One poll of the selected build: the next delay (2 s while live, the backoff after an error) or nil to stop.
  public func pollStep() async -> Double? {
    guard isActive, !isLocal, let client, let id = selected, store.record(id) != nil, !gone.contains(id) else { return nil }
    do {
      let build = try await client.build(id: id)
      guard isActive, selected == id else { return nil }
      pollErrors = 0
      connectionLine = nil
      cache[id] = build
      if build.deployed { await loadOutcome(id) }
      rebuildRows()
      recompute()
      return build.state.isLive ? Self.pollSeconds : nil
    } catch APIError.notFound {
      gone.insert(id)
      cache[id] = nil
      rebuildRows()
      recompute()
      return nil
    } catch {
      guard isActive else { return nil }
      // In words; "Retrying" only when offline, and no retry when this Mac must sign in again (review1.md finding 4).
      connectionLine = connectionWords(error)
      if Self.isSignedOut(error) { return nil }
      pollErrors += 1
      return Self.backoff(pollErrors)
    }
  }

  /// Polls while the selected build is live; stops at any other state, on a 404 or when the screen goes away.
  public func runPollLoop() async {
    var delay = initialPollDelay()
    while let d = delay {
      do {
        try await sleeper.sleep(seconds: d)
      } catch {
        return
      }
      if Task.isCancelled { return }
      delay = await pollStep()
    }
  }

  private func initialPollDelay() -> Double? {
    guard isActive, !isLocal, let id = selected, store.record(id) != nil, !gone.contains(id) else { return nil }
    if pollErrors > 0 { return Self.backoff(pollErrors) }
    guard let build = cache[id] else { return Self.pollSeconds }
    return build.state.isLive ? Self.pollSeconds : nil
  }

  private func restartPolling() {
    pollTask?.cancel()
    pollTask = nil
    guard loopsEnabled, isActive, !isLocal else { return }
    pollTask = Task { [weak self] in await self?.runPollLoop() }
  }

  // MARK: OK, build

  /// The hand-off's OK, build: answers the opportunity with `build`, then reads its fix when it exists.
  public func startPlan(opportunityID: String, optionID: String?) async {
    guard !isLocal, let client else { return }
    notice = nil
    plan = PlanState(opportunityID: opportunityID, optionID: optionID, fixID: optionID, title: "", phase: .answering,
                     line: BuildCopy.answering, message: nil, startedAt: now())
    do {
      let opportunity = try await client.answerOpportunity(id: opportunityID, answer: .build, optionID: optionID)
      guard plan?.opportunityID == opportunityID else { return }
      await apply(opportunity)
    } catch {
      // A later plan is not stopped by this one's failure (review1.md finding 5).
      guard plan?.opportunityID == opportunityID else { return }
      if Task.isCancelled || Self.isCancellation(error) {
        // The screen went away while the answer was on its way: not an error. The plan waits on the opportunity,
        // which tells whether the answer arrived.
        plan?.phase = .designing
        plan?.line = BuildCopy.designing
        plan?.message = nil
        return
      }
      stopPlan(words(error))
    }
  }

  /// Brings back a kept plan: it reads the opportunity once at once (so a plan that was ready shows again even after
  /// 10 minutes), then the plan loop goes on from the kept start time. The answer is never posted again.
  public func resumePlan(_ kept: KeptPlan) async {
    guard !isLocal, let client else { return }
    plan = PlanState(opportunityID: kept.opportunityID, optionID: kept.optionID, fixID: kept.fixID, title: kept.title,
                     phase: .designing, line: BuildCopy.designing, message: nil, startedAt: kept.startedAt)
    do {
      let opportunity = try await client.opportunity(id: kept.opportunityID)
      guard plan?.opportunityID == kept.opportunityID else { return }
      connectionLine = nil
      await apply(opportunity)
    } catch {
      connectionLine = connectionWords(error)
    }
  }

  /// Saves the plan while it waits or is ready; clears it once it is gone, stopped or too long.
  private func persistPlan() {
    guard !isLocal else { return }
    guard let p = plan else {
      plans.clear()
      return
    }
    switch p.phase {
    case .stopped, .tooLong:
      plans.clear()
    default:
      plans.save(KeptPlan(opportunityID: p.opportunityID, optionID: p.optionID, fixID: p.fixID, title: p.title,
                          startedAt: p.startedAt))
    }
  }

  /// One read of the opportunity while its fix is designed: 5 s while it waits, nil when the plan is ready, stopped
  /// or 10 minutes have passed.
  public func planStep() async -> Double? {
    guard isActive, !isLocal, let client, let current = plan, planIsWaiting else { return nil }
    if now().timeIntervalSince(current.startedAt) >= Self.planLimitSeconds {
      plan?.phase = .tooLong
      plan?.line = BuildCopy.stillDesigning
      return nil
    }
    do {
      let opportunity = try await client.opportunity(id: current.opportunityID)
      guard isActive, plan?.opportunityID == current.opportunityID else { return nil }
      connectionLine = nil
      await apply(opportunity)
    } catch {
      connectionLine = connectionWords(error)
      if Self.isSignedOut(error) { return nil }
    }
    return planIsWaiting ? Self.planSeconds : nil
  }

  public func runPlanLoop() async {
    var delay: Double? = planIsWaiting ? Self.planSeconds : nil
    while let d = delay {
      do {
        try await sleeper.sleep(seconds: d)
      } catch {
        return
      }
      if Task.isCancelled { return }
      delay = await planStep()
    }
  }

  private var planIsWaiting: Bool {
    switch plan?.phase {
    case .designing?, .needsConnection?: return true
    default: return false
    }
  }

  private func restartPlanLoop() {
    planTask?.cancel()
    planTask = nil
    guard loopsEnabled, isActive, planIsWaiting else { return }
    planTask = Task { [weak self] in await self?.runPlanLoop() }
  }

  private func apply(_ opportunity: Opportunity) async {
    guard var p = plan else { return }
    if !opportunity.title.isEmpty { p.title = opportunity.title }
    if p.fixID == nil {
      p.fixID = (opportunity.options.first(where: { $0.recommended }) ?? opportunity.options.first)?.id
    }
    switch opportunity.state {
    case .open, .chosen, .capturingFixtures, .designing:
      p.phase = .designing
      p.line = BuildCopy.designing
      plan = p
    case .needsConnection where !opportunity.missingConnections.isEmpty:
      p.phase = .needsConnection(opportunity.missingConnections)
      p.line = BuildCopy.connectFirst(opportunity.missingConnections)
      plan = p
    case .needsConnection:
      // No apps named: keep designing, never read the fix while a connection is missing (pre-review finding 6).
      p.phase = .designing
      p.line = BuildCopy.designing
      plan = p
    default:
      plan = p
      await readFix()
    }
  }

  private func readFix() async {
    guard let client, let fixID = plan?.fixID else {
      stopPlan(BuildCopy.noFixYet)
      return
    }
    do {
      let fix = try await client.fix(id: fixID)
      fixes[fix.id] = fix
      plan?.phase = .ready(fix)
      plan?.line = nil
    } catch APIError.notFound {
      plan?.phase = .designing
      plan?.line = BuildCopy.designing
    } catch {
      stopPlan(words(error))
    }
  }

  private func stopPlan(_ message: String) {
    plan?.phase = .stopped
    plan?.line = nil
    plan?.message = message
  }

  /// OK, build: posts the four hashes of the fix as read, with the $4 cap, signed. Only from the button.
  public func okBuild() async {
    guard !isLocal, let client, !busy, var p = plan, case .ready(let fix) = p.phase else { return }
    busy = true
    defer { busy = false }
    p.phase = .starting
    p.line = BuildCopy.starting
    p.message = nil
    plan = p
    do {
      let started = try await client.okBuild(fixID: fix.id, hashes: fix.hashes)
      store.add(BuildRecord(buildID: started.buildID, name: p.title.isEmpty ? BuildCopy.unnamed : p.title, fixID: fix.id,
                            startedAt: now()))
      plan = nil
      notice = nil
      selected = started.buildID
      installState = InstallState()
      await refresh()
      restartPolling()
    } catch let error as APIError {
      switch error.code {
      case .hashMismatch?:
        // Read the fix again; the person reads the new plan and presses again. Never re-posted by itself.
        do {
          let again = try await client.fix(id: fix.id)
          fixes[again.id] = again
          plan?.phase = .ready(again)
          plan?.line = nil
          plan?.message = BuildCopy.planChanged
        } catch {
          stopPlan(BuildCopy.planChanged)
        }
      case .alreadyRunning?:
        plan = nil
        notice = BuildCopy.alreadyRunning
        await refresh()
      default:
        plan?.phase = .ready(fix)
        plan?.line = nil
        plan?.message = error == .signingUnavailable ? BuildCopy.buildNeedsEnrollment : BuildCopy.sentence(for: error)
      }
    } catch {
      plan?.phase = .ready(fix)
      plan?.line = nil
      plan?.message = words(error)
    }
  }

  /// Leaves the plan without building.
  public func dismissPlan() {
    plan = nil
    planTask?.cancel()
    planTask = nil
  }

  // MARK: Install (deploy approval)

  /// See what changed: reads the definition whose hash Install will post.
  public func readDefinition() async {
    guard canReadDefinition, let client, let id = selected else { return }
    installState.busy = true
    defer { installState.busy = false }
    // Every result is kept only while the same build is still chosen (review1.md finding 3).
    do {
      let definition = try await client.definition(id: id)
      guard selected == id else { return }
      installState.definition = definition
      installState.message = nil
    } catch APIError.notFound {
      guard selected == id else { return }
      installState.definition = nil
      installState.message = BuildCopy.definitionMissing
    } catch {
      guard selected == id else { return }
      installState.message = words(error)
    }
  }

  /// Install: posts the build's artifact and receipt hashes and the definition's hash, signed. Only from the button.
  public func install() async {
    guard canInstall, let client, let id = selected, let build = cache[id], let definition = installState.definition else { return }
    guard let artifact = build.artifactSHA256, let receipt = build.receiptHash else {
      installState.message = BuildCopy.installChanged
      return
    }
    let hashes = DeployHashes(artifactSHA256: artifact, receiptHash: receipt, definitionHash: definition.definitionHash)
    installState.busy = true
    do {
      let deployed = try await client.deploy(id: id, hashes: hashes)
      // The install belongs to its build's record whatever is chosen now; the screen shows it only for that build
      // (review1.md finding 3).
      if var record = store.record(id) {
        record.routineID = deployed.routineID
        record.installedAt = now()
        store.add(record)
      }
      if selected == id {
        installState.busy = false
        installState.installed = deployed
        installState.message = nil
      }
      await rereadBuild(id)
    } catch let error as APIError {
      guard selected == id else {
        await rereadBuild(id)
        return
      }
      installState.busy = false
      switch error.code {
      case .hashMismatch?:
        // Read the build and the definition again; Install needs a new press.
        installState.definition = nil
        await rereadBuild(id)
        let again = try? await client.definition(id: id)
        guard selected == id else { return }
        installState.definition = again
        installState.message = BuildCopy.installChanged
      case .stateConflict?:
        installState.message = BuildCopy.sentence(for: error)
        await rereadBuild(id)
      default:
        installState.message = error == .signingUnavailable ? BuildCopy.installNeedsEnrollment : BuildCopy.sentence(for: error)
      }
    } catch {
      guard selected == id else { return }
      installState.busy = false
      installState.message = words(error)
    }
  }

  private func rereadBuild(_ id: String) async {
    guard let client else { return }
    do {
      let build = try await client.build(id: id)
      cache[id] = build
      if build.deployed { await loadOutcome(id) }
    } catch APIError.notFound {
      gone.insert(id)
      cache[id] = nil
    } catch {
      connectionLine = connectionWords(error)
    }
    rebuildRows()
    recompute()
  }

  /// Cancels a live build (`POST /v1/builds/{id}/cancel`).
  public func cancel() async {
    guard canCancel, let client, let id = selected else { return }
    do {
      cache[id] = try await client.cancel(id: id)
      notice = nil
    } catch {
      notice = words(error)
      if (error as? APIError)?.code == .stateConflict {
        // "Showing the latest" reads the latest (review2.md finding 2).
        await rereadBuild(id)
        return
      }
    }
    rebuildRows()
    recompute()
  }

  // MARK: Sample

  private func loadSample() {
    selected = SampleBuild.rowID
    emptyLine = nil
    recompute()
    builds = [BuildRow(id: SampleBuild.rowID, name: BuildCopy.sampleRowName, state: .sample, started: nil,
                       dot: detail?.dot ?? .working)]
  }

  /// Replay: from tick 0 (Reduce Motion: the final state).
  public func replaySample() {
    guard isLocal else { return }
    sampleTick = reduceMotion ? SampleTimeline.endTick : 0
    loadSample()
    restartSample()
  }

  /// One tick of the sample: the delay before the next, or nil at the end.
  public func sampleStep() -> Double? {
    guard isActive, isLocal, sampleTick < SampleTimeline.endTick else { return nil }
    sampleTick = reduceMotion ? SampleTimeline.endTick : sampleTick + 1
    loadSample()
    return sampleTick < SampleTimeline.endTick ? SampleTimeline.tickSeconds : nil
  }

  /// Plays the sample once to tick 92; with Reduce Motion it shows tick 92 at once.
  public func runSampleLoop() async {
    guard isActive, isLocal else { return }
    if reduceMotion {
      sampleTick = SampleTimeline.endTick
      loadSample()
      return
    }
    var delay: Double? = sampleTick < SampleTimeline.endTick ? SampleTimeline.tickSeconds : nil
    while let d = delay {
      do {
        try await sleeper.sleep(seconds: d)
      } catch {
        return
      }
      if Task.isCancelled { return }
      delay = sampleStep()
    }
  }

  private func restartSample() {
    sampleTask?.cancel()
    sampleTask = nil
    guard loopsEnabled, isActive, isLocal else { return }
    sampleTask = Task { [weak self] in await self?.runSampleLoop() }
  }

  // MARK: Words

  /// "Can't reach Offload. Retrying." only when the Mac is offline; any other failure in its own words (pre-review
  /// finding 5).
  private func connectionWords(_ error: any Error) -> String {
    if let e = error as? APIError, !e.isOffline { return BuildCopy.sentence(for: e) }
    return BuildCopy.offline
  }

  /// The Mac must sign in again: retrying cannot help.
  static func isSignedOut(_ error: any Error) -> Bool {
    guard let e = error as? APIError else { return false }
    return e == .notSignedIn || e.code == .unauthenticated || e.code == .tokenExpired
  }

  /// The request was cancelled on this Mac (the screen went away), not refused.
  static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? APIError) == .transport(code: URLError.Code.cancelled.rawValue)
  }

  private func words(_ error: any Error) -> String {
    if let e = error as? APIError { return BuildCopy.sentence(for: e) }
    return BuildCopy.sentence(for: .badResponse(status: 0))
  }
}
