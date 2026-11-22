import Foundation

// The labelled sample build shown in `.local` backend mode (SPEC m3-13 "SampleBuild"), where no builder exists on the
// Mac. It is the mockup's build (mockups source.canvas.tsx, "4. Build progress": WORKERS, T_END = 92, ticks of 100 ms)
// as a fixed fixture: every number below is the fixture's, never a count from this Mac, and every detail made from it
// carries `.sample` provenance, so the screen always shows "Sample data: cloud not connected" with it.

public enum SampleBuild {
  public static let rowID = "sample"
  public static let name = "PR pre-read tool"
  public static let fingerprint = "7c41e2"
  public static let testsWritten = 47
  public static let capUSD: Double = 4
  public static let finalCostUSD: Double = 0.84
  public static let finalSeconds = 372
  public static let estimateHoursPerWeek: Double = 1.4
}

public struct SampleWorkerSpec: Equatable, Sendable {
  public var name: String
  public var total: Int
  /// The check this worker fails before the builder fixes it.
  public var failAt: Int?
}

public enum SampleWorkerState: Equatable, Sendable {
  case waiting, running, failed, passed
}

public enum SampleBox: Equatable, Sendable {
  case passed, failed, empty
}

/// One of the sample's named workers at a tick, with a box per check.
public struct SampleWorker: Equatable, Sendable {
  public var name: String
  public var total: Int
  public var done: Int
  public var state: SampleWorkerState

  public init(name: String, total: Int, done: Int, state: SampleWorkerState) {
    self.name = name
    self.total = total
    self.done = done
    self.state = state
  }

  /// Green for the checks done, red for the one failing, empty for the rest.
  public var boxes: [SampleBox] {
    (0..<total).map { k in
      if k < done { return .passed }
      if state == .failed && k == done { return .failed }
      return .empty
    }
  }

  /// "3/7".
  public var countText: String { "\(done)/\(total)" }
}

public struct SampleState: Equatable, Sendable {
  public var tick: Int
  public var workers: [SampleWorker]
  public var passed: Int
  public var total: Int
  public var allPass: Bool
  public var failing: Bool
  public var intent: Bool
  public var ready: Bool
  public var costUSD: Double
  public var seconds: Int
}

/// The mockup's timeline, tick for tick. One change: a worker shows as waiting until its start tick (the mockup's
/// failing worker showed as running from tick 0).
public enum SampleTimeline {
  public static let endTick = 92
  public static let tickSeconds = 0.1

  public static let workers: [SampleWorkerSpec] = [
    SampleWorkerSpec(name: "parse PR diff", total: 6, failAt: nil),
    SampleWorkerSpec(name: "missing-tests rule", total: 5, failAt: nil),
    SampleWorkerSpec(name: "risky-files rule", total: 7, failAt: 4),
    SampleWorkerSpec(name: "summary card", total: 4, failAt: nil),
    SampleWorkerSpec(name: "GitHub read-only", total: 6, failAt: nil),
    SampleWorkerSpec(name: "masking", total: 5, failAt: nil),
    SampleWorkerSpec(name: "menu bar entry", total: 8, failAt: nil),
    SampleWorkerSpec(name: "intent check", total: 6, failAt: nil),
  ]

  public static func state(at tick: Int) -> SampleState {
    let t = min(max(tick, 0), endTick)
    let list = workers.enumerated().map { pair in worker(pair.element, index: pair.offset, tick: t) }
    let passed = list.reduce(0) { $0 + $1.done }
    let total = workers.reduce(0) { $0 + $1.total }
    let allPass = list.allSatisfy { $0.state == .passed }
    let failing = list.contains { $0.state == .failed }
    let intent = allPass && t >= 80
    let ready = intent && t >= 88
    let fraction = Double(t) / Double(endTick)
    return SampleState(
      tick: t, workers: list, passed: passed, total: total, allPass: allPass, failing: failing, intent: intent,
      ready: ready, costUSD: min(SampleBuild.finalCostUSD, fraction * SampleBuild.finalCostUSD),
      seconds: Int((fraction * Double(SampleBuild.finalSeconds)).rounded())
    )
  }

  static func worker(_ w: SampleWorkerSpec, index: Int, tick t: Int) -> SampleWorker {
    let start = 16 + index * 2
    guard t >= start else { return SampleWorker(name: w.name, total: w.total, done: 0, state: .waiting) }
    let raw = (t - start) / 4
    if let failAt = w.failAt {
      if raw < failAt { return SampleWorker(name: w.name, total: w.total, done: raw, state: .running) }
      if raw < failAt + 5 { return SampleWorker(name: w.name, total: w.total, done: failAt - 1, state: .failed) }
      let d = min(w.total, raw - 5)
      return SampleWorker(name: w.name, total: w.total, done: d, state: d >= w.total ? .passed : .running)
    }
    let d = min(w.total, raw)
    return SampleWorker(name: w.name, total: w.total, done: d, state: d >= w.total ? .passed : .running)
  }
}

extension BuildDetail {
  /// The sample at `tick` (0 to 92), always with `.sample` provenance.
  public static func sample(tick: Int) -> BuildDetail {
    let s = SampleTimeline.state(at: tick)
    let t = s.tick
    func status(on: Bool, active: Bool) -> StepStatus { on ? .done : (active ? .working : .waiting) }
    let failed = s.workers.filter { $0.state == .failed }.count
    let steps = [
      StepRow(title: BuildCopy.planLocked, detail: BuildCopy.planLockedDetail, status: status(on: t >= 5, active: t < 5)),
      StepRow(title: BuildCopy.checksFrozen,
              detail: BuildCopy.testsWritten(SampleBuild.testsWritten, fingerprint: SampleBuild.fingerprint),
              status: status(on: t >= 14, active: t >= 5 && t < 14)),
      StepRow(title: BuildCopy.workersInParallel(s.workers.count),
              detail: s.failing ? BuildCopy.failedFixing(failed) : BuildCopy.checksPassing(s.passed, of: s.total),
              status: status(on: s.allPass, active: t >= 14 && !s.allPass)),
      StepRow(title: BuildCopy.matches, detail: BuildCopy.matchesDetail, status: status(on: s.intent, active: s.allPass && !s.intent)),
      StepRow(title: BuildCopy.readyToShip, detail: BuildCopy.readyToShipDetail, status: status(on: s.ready, active: s.intent && !s.ready)),
    ]
    let headline = s.ready ? BuildCopy.headlineReady : (s.failing ? BuildCopy.headlineFixing : BuildCopy.headlineBuilding)
    let dot: StatusDot = s.ready ? .done : (s.failing ? .needsYou : .working)
    let saving = BuildCopy.savesEstimated(Decimals.oneDecimal(SampleBuild.estimateHoursPerWeek)) + " · " + BuildCopy.measuredAfter
    return BuildDetail(
      title: BuildCopy.title(SampleBuild.name), headline: headline, headlineNote: nil, dot: dot,
      meter: BudgetMeter(seconds: s.seconds, spentUSD: s.costUSD, capUSD: SampleBuild.capUSD), steps: steps, attempts: [],
      workers: s.workers, heldOut: s.ready ? .passed : .notRun, saving: SavingLine(text: saving),
      actions: BuildActions(offerInstall: s.ready, offerCancel: false), provenance: .sample
    )
  }
}
