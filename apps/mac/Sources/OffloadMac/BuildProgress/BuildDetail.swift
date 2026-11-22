import Foundation

// One build's detail, decided in pure code from the builds API's fields (SPEC m3-13 "BuildDetail", ADR 0003): the
// five step rows, the headline and its dot, one row per worker attempt, the held-out result, time and spend against
// the build cap, and the saving line. Views only draw these. Numbers are formatted here and never computed by a model.

// MARK: Steps

public enum StepStatus: Equatable, Sendable {
  case waiting, working, done, failed
}

public struct StepRow: Equatable, Sendable {
  public var title: String
  public var detail: String
  public var status: StepStatus
  /// Stages the Mac does not know, listed by name (row 3 only), never dropped.
  public var extras: [String]

  public init(title: String, detail: String, status: StepStatus, extras: [String] = []) {
    self.title = title
    self.detail = detail
    self.status = status
    self.extras = extras
  }
}

/// The build loop's `stages[]` onto the mockup's five rows.
public enum StepMapping {
  public static let checkStages: Set<String> = ["teeth_gate"]
  public static let workerStages: Set<String> = ["worker", "fan_out"]
  public static let matchStages: Set<String> = ["verification", "winner"]
  public static var knownStages: Set<String> { checkStages.union(workerStages).union(matchStages) }

  /// The first 6 hex characters of the fix's `brief_hash`, lowercased.
  public static func fingerprint(_ briefHash: String) -> String { String(briefHash.lowercased().prefix(6)) }

  public static func rows(build: Build, fix: Fix?) -> [StepRow] {
    var plan = BuildCopy.planLockedDetail
    if let fix { plan += " · " + BuildCopy.fingerprint(fingerprint(fix.briefHash)) }

    let checks = latest(build, in: checkStages)
    var checksDetail = BuildCopy.checksFrozenDetail
    if let note = checks?.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { checksDetail = note }

    let extras = build.stages.filter { !knownStages.contains($0.name) }
      .map { BuildCopy.otherStage($0.name, state: $0.state.raw) }

    let matchDetail: String
    switch HeldOutResult.of(build) {
    case .passed: matchDetail = BuildCopy.heldOutPassed
    case .failed: matchDetail = BuildCopy.heldOutFailed
    case .notRun: matchDetail = BuildCopy.matchesDetail
    }

    return [
      StepRow(title: BuildCopy.planLocked, detail: plan, status: .done),
      StepRow(title: BuildCopy.checksFrozen, detail: checksDetail, status: status(checks, live: build.state.isLive)),
      StepRow(title: BuildCopy.workersTesting, detail: workersDetail(build.attempts),
              status: status(latest(build, in: workerStages), live: build.state.isLive), extras: extras),
      StepRow(title: BuildCopy.matches, detail: matchDetail,
              status: status(latest(build, in: matchStages), live: build.state.isLive)),
      StepRow(title: BuildCopy.readyToShip, detail: build.deployed ? BuildCopy.installedDetail : BuildCopy.readyToShipDetail,
              status: build.state.isReady ? .done : .waiting),
    ]
  }

  /// The last stage (in the build's order) with one of `names`.
  static func latest(_ build: Build, in names: Set<String>) -> BuildStage? {
    build.stages.last(where: { names.contains($0.name) })
  }

  /// running is working, done is done; a failed stage of a build that is still live is being fixed, so it waits.
  static func status(_ stage: BuildStage?, live: Bool) -> StepStatus {
    guard let stage else { return .waiting }
    switch stage.state {
    case .running: return .working
    case .done: return .done
    case .failed: return live ? .waiting : .failed
    case .unknown: return .waiting
    }
  }

  static func isFailure(_ outcome: AttemptOutcome) -> Bool {
    switch outcome {
    case .fail, .cap, .tamper, .error: return true
    default: return false
    }
  }

  /// "1 failed · builder is fixing it" while a failed attempt has a later one running, else "2 of 3 attempts passing".
  static func workersDetail(_ attempts: [BuildAttempt]) -> String {
    guard !attempts.isEmpty else { return BuildCopy.workersWaiting }
    let running = attempts.filter { $0.outcome == .running }.map(\.ordinal)
    let beingFixed = attempts.filter { a in isFailure(a.outcome) && running.contains { $0 > a.ordinal } }
    if !beingFixed.isEmpty { return BuildCopy.failedFixing(beingFixed.count) }
    return BuildCopy.attemptsPassing(attempts.filter { $0.outcome == .pass }.count, of: attempts.count)
  }
}

// MARK: Headline

/// The status colours: blue working, amber needs you, green done, red a failed check, grey waiting.
public enum StatusDot: Equatable, Sendable {
  case waiting, working, needsYou, done, failedCheck
}

public enum HeadlineMap {
  public static func headline(_ state: BuildState) -> String {
    switch state {
    case .queued: return BuildCopy.headlineQueued
    case .building: return BuildCopy.headlineBuilding
    case .verifying: return BuildCopy.headlineVerifying
    case .fanningOut, .repairing: return BuildCopy.headlineFixing
    case .ready: return BuildCopy.headlineReady
    case .failed: return BuildCopy.headlineFailed
    case .capped: return BuildCopy.headlineCapped
    case .tampered: return BuildCopy.headlineTampered
    case .cancelled: return BuildCopy.headlineCancelled
    case .infraFailed: return BuildCopy.headlineInfraFailed
    case .unknown(let raw): return BuildCopy.headlineUnknown(raw)
    }
  }

  /// The latest stage's note, as the server wrote it.
  public static func note(_ build: Build) -> String? {
    guard let note = build.stages.last?.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
    return note
  }

  /// Green when ready, red when it failed, amber when it needs you (capped, tampered, infra_failed, cancelled, an
  /// unknown state, or any failed stage of a live build), else blue.
  public static func dot(_ build: Build) -> StatusDot {
    switch build.state {
    case .ready: return .done
    case .failed: return .failedCheck
    case .capped, .tampered, .infraFailed, .cancelled, .unknown: return .needsYou
    case .queued, .building, .verifying, .fanningOut, .repairing:
      return build.stages.contains { $0.state == .failed } ? .needsYou : .working
    }
  }
}

// MARK: Attempts

public enum CheckMark: Equatable, Sendable {
  case passed, failed, notRun

  public var text: String {
    switch self {
    case .passed: return BuildCopy.markPassed
    case .failed: return BuildCopy.markFailed
    case .notRun: return BuildCopy.notRun
    }
  }

  /// From the attempt's flag when it has one, else from its check group, else not run.
  static func of(flag: Bool?, group: CheckGroupName, in groups: [CheckGroup]) -> CheckMark {
    if let flag { return flag ? .passed : .failed }
    let matching = groups.filter { $0.name == group }
    if matching.contains(where: { $0.failed > 0 }) { return .failed }
    if matching.contains(where: { $0.passed > 0 }) { return .passed }
    return .notRun
  }
}

public struct AttemptRow: Equatable, Sendable {
  public var ordinal: Int
  public var name: String
  public var dot: StatusDot
  public var frozen: CheckMark
  public var heldOut: CheckMark
  public var spend: String

  public init(ordinal: Int, name: String, dot: StatusDot, frozen: CheckMark, heldOut: CheckMark, spend: String) {
    self.ordinal = ordinal
    self.name = name
    self.dot = dot
    self.frozen = frozen
    self.heldOut = heldOut
    self.spend = spend
  }

  /// One row per attempt, by ordinal.
  public static func rows<S: Sequence>(_ attempts: S) -> [AttemptRow] where S.Element == BuildAttempt {
    attempts.sorted { $0.ordinal < $1.ordinal }.map { a in
      AttemptRow(
        ordinal: a.ordinal, name: BuildCopy.workerName(a.ordinal), dot: dot(a.outcome),
        frozen: CheckMark.of(flag: a.frozenPass, group: .frozen, in: a.checkGroups),
        heldOut: CheckMark.of(flag: a.heldOutPass, group: .heldOut, in: a.checkGroups),
        spend: Money.usd(a.spentUSD)
      )
    }
  }

  public static func dot(_ outcome: AttemptOutcome) -> StatusDot {
    switch outcome {
    case .running: return .working
    case .pass: return .done
    case .fail: return .failedCheck
    case .cap, .tamper, .error, .unknown: return .needsYou
    }
  }
}

// MARK: Held-out check

public enum HeldOutResult: Equatable, Sendable {
  case passed, failed, notRun

  /// From the winner attempt, else the latest attempt (highest ordinal).
  public static func of(_ build: Build) -> HeldOutResult {
    let winner = build.winnerAttemptID.flatMap { id in build.attempts.first { $0.id == id } }
    guard let attempt = winner ?? build.attempts.max(by: { $0.ordinal < $1.ordinal }) else { return .notRun }
    switch CheckMark.of(flag: attempt.heldOutPass, group: .heldOut, in: attempt.checkGroups) {
    case .passed: return .passed
    case .failed: return .failed
    case .notRun: return .notRun
    }
  }
}

// MARK: Money, hours and time

public enum Money {
  /// Whole cents, rounded half up from the decimal the number prints as (0.845 is 85), never negative.
  public static func cents(_ usd: Double) -> Int { Decimals.scaled(usd, places: 2) }

  /// "$0.84".
  public static func usd(_ usd: Double) -> String {
    let c = cents(usd)
    return "$\(c / 100)." + Decimals.pad(c % 100, 2)
  }
}

enum Decimals {
  /// `value` × 10^places rounded half up, as an integer; 0 for negative, NaN or infinite values.
  static func scaled(_ value: Double, places: Int) -> Int {
    guard value.isFinite, value > 0 else { return 0 }
    var exact = Decimal(string: "\(value)", locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(value)
    var rounded = Decimal()
    NSDecimalRound(&rounded, &exact, places, .plain)
    var factor = Decimal(1)
    for _ in 0..<places { factor *= 10 }
    return NSDecimalNumber(decimal: rounded * factor).intValue
  }

  static func pad(_ n: Int, _ width: Int) -> String {
    let s = String(n)
    return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
  }

  /// One decimal, half up: 1.204 is "1.2", 2 is "2.0".
  static func oneDecimal(_ value: Double) -> String {
    let tenths = scaled(value, places: 1)
    return "\(tenths / 10).\(tenths % 10)"
  }
}

/// Hours per week from a Figure: hours as they are, minutes divided by 60; another unit has no hours.
enum WeeklyHours {
  static func of(_ figure: Figure) -> Double? {
    switch figure.unit {
    case "hours_per_week", "hours", "h_per_week": return figure.value
    case "minutes_per_week", "minutes": return figure.value / 60
    default: return nil
    }
  }
}

/// Server timestamps (UTC `Z`, with or without milliseconds), and the list's start time in the person's time zone.
enum BuildTime {
  static func parse(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
  }

  /// "22 Nov, 11:50".
  static func started(_ date: Date, timeZone: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "d MMM, HH:mm"
    return f.string(from: date)
  }

  /// "2026-11" in UTC, for `GET /v1/outcomes?month=`.
  static func month(_ date: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let c = cal.dateComponents([.year, .month], from: date)
    return "\(c.year ?? 1970)-" + Decimals.pad(c.month ?? 1, 2)
  }
}

// MARK: Budget meter

/// Time from `started_at` to `ended_at` (or now) and spend against the build cap: "6m 12s · $0.84 of $4.00".
public struct BudgetMeter: Equatable, Sendable {
  public var elapsedSeconds: Int
  public var spent: String
  public var cap: String
  /// At or over the cap: drawn amber.
  public var atCap: Bool

  public init(seconds: Int, spentUSD: Double, capUSD: Double) {
    elapsedSeconds = max(0, seconds)
    spent = Money.usd(spentUSD)
    cap = Money.usd(capUSD)
    atCap = Money.cents(spentUSD) >= Money.cents(capUSD)
  }

  public init(build: Build, now: Date) {
    var seconds = 0
    if let start = BuildTime.parse(build.startedAt) {
      let end = BuildTime.parse(build.endedAt) ?? now
      let delta = end.timeIntervalSince(start)
      seconds = delta.isFinite && delta > 0 ? Int(delta.rounded(.down)) : 0
    }
    self.init(seconds: seconds, spentUSD: build.spentUSD, capUSD: build.capUSD)
  }

  /// "6m 12s".
  public static func elapsed(_ seconds: Int) -> String { "\(seconds / 60)m " + Decimals.pad(seconds % 60, 2) + "s" }

  public var text: String { BuildCopy.meter(elapsed: Self.elapsed(elapsedSeconds), spent: spent, cap: cap) }
  public var items: [String] { MetaItems.split(text) }
}

// MARK: Saving

/// The routine's outcome after install, as the Mac found it.
public enum OutcomeLookup: Equatable, Sendable {
  /// Not read (yet).
  case notLoaded
  /// `GET /v1/outcomes` answered 404: the route is not built yet (M4).
  case routeMissing
  /// The month's outcomes have none for this routine.
  case missing
  case found(FixOutcome)
}

public struct SavingLine: Equatable, Sendable {
  public var text: String

  public init(text: String) { self.text = text }

  /// Before install the fix's estimate, labelled estimated; after install the outcome (the server's hs-1 numbers,
  /// formatted here).
  public static func make(fix: Fix?, installed: Bool, outcome: OutcomeLookup) -> SavingLine? {
    guard installed else {
      if let estimate = fix?.estimate, let hours = WeeklyHours.of(estimate) {
        return SavingLine(text: BuildCopy.savesEstimated(Decimals.oneDecimal(hours)) + " · " + BuildCopy.measuredAfter)
      }
      return SavingLine(text: BuildCopy.measuredAfter)
    }
    switch outcome {
    case .notLoaded: return nil
    case .routeMissing: return SavingLine(text: BuildCopy.measuredFromM4)
    case .missing: return SavingLine(text: BuildCopy.notMeasured)
    case .found(let o):
      switch o.flag {
      case .pending:
        let measured = o.weeks.filter { $0 != .null }.count
        return SavingLine(text: BuildCopy.measuring(week: min(4, measured + 1)))
      case .onTrack, .partial, .under:
        guard let ratio = o.ratio?.value, let estimated = o.estimatedMinutesPerWeek?.value, ratio.isFinite, estimated.isFinite
        else { return SavingLine(text: BuildCopy.notMeasured) }
        return SavingLine(text: BuildCopy.savedMeasured(Decimals.oneDecimal(ratio * estimated / 60),
                                                        estimated: Decimals.oneDecimal(estimated / 60)))
      case .unmeasured, .unknown:
        return SavingLine(text: BuildCopy.notMeasured)
      }
    }
  }
}

// MARK: Detail

public struct BuildActions: Equatable, Sendable {
  /// Install and See what changed are offered: the build is ready and not installed.
  public var offerInstall: Bool
  /// Cancel is offered while the build is live.
  public var offerCancel: Bool

  public init(offerInstall: Bool, offerCancel: Bool) {
    self.offerInstall = offerInstall
    self.offerCancel = offerCancel
  }
}

public struct BuildDetail: Equatable, Sendable {
  public var title: String
  public var headline: String
  public var headlineNote: String?
  public var dot: StatusDot
  public var meter: BudgetMeter
  public var steps: [StepRow]
  public var attempts: [AttemptRow]
  /// The sample's named workers with a box per check; empty for real builds (the API reports check groups per
  /// attempt, not single checks).
  public var workers: [SampleWorker]
  public var heldOut: HeldOutResult
  public var saving: SavingLine?
  public var actions: BuildActions
  public var provenance: DataProvenance

  public init(title: String, headline: String, headlineNote: String?, dot: StatusDot, meter: BudgetMeter, steps: [StepRow],
              attempts: [AttemptRow], workers: [SampleWorker], heldOut: HeldOutResult, saving: SavingLine?,
              actions: BuildActions, provenance: DataProvenance) {
    self.title = title
    self.headline = headline
    self.headlineNote = headlineNote
    self.dot = dot
    self.meter = meter
    self.steps = steps
    self.attempts = attempts
    self.workers = workers
    self.heldOut = heldOut
    self.saving = saving
    self.actions = actions
    self.provenance = provenance
  }

  /// A real build from the builds API. `name` is the record's (the API's build has none).
  public static func make(build: Build, fix: Fix?, outcome: OutcomeLookup, now: Date, name: String) -> BuildDetail {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return BuildDetail(
      title: BuildCopy.title(trimmed.isEmpty ? BuildCopy.unnamed : trimmed),
      headline: HeadlineMap.headline(build.state),
      headlineNote: HeadlineMap.note(build),
      dot: HeadlineMap.dot(build),
      meter: BudgetMeter(build: build, now: now),
      steps: StepMapping.rows(build: build, fix: fix),
      attempts: AttemptRow.rows(build.attempts),
      workers: [],
      heldOut: HeldOutResult.of(build),
      saving: SavingLine.make(fix: fix, installed: build.deployed, outcome: outcome),
      actions: BuildActions(offerInstall: build.state.isReady && !build.deployed, offerCancel: build.state.isLive),
      provenance: .cloud
    )
  }

  /// Every string the detail shows, for the copy and figure tests.
  public var allText: [String] {
    var out = [title, headline, meter.text]
    if let headlineNote { out.append(headlineNote) }
    for s in steps { out += [s.title, s.detail] + s.extras }
    for a in attempts { out += [a.name, a.spend, a.frozen.text, a.heldOut.text] }
    for w in workers { out += [w.name, w.countText] }
    if let saving { out.append(saving.text) }
    return out
  }
}
