import Combine
import Foundation
import OffloadImport

// The local insights cache. `InsightsStore` (an actor, off the main actor) keeps one DayInsights per day and
// recomputes only the days an import touched; `InsightsModel` publishes snapshots for the screens; the coordinator
// listens to the recordings import and asks for the right days.

public struct InsightsSnapshot: Equatable, Sendable {
  /// Days with data, oldest first.
  public var days: [DayInsights]
  /// Every repeat, ranked; declined ones stay with score 0.
  public var repeats: [RepeatPattern]
  /// The days with data ("2026-11-20").
  public var observedDays: [String]
  public var lastUpdated: Date?

  public init(days: [DayInsights], repeats: [RepeatPattern], observedDays: [String], lastUpdated: Date?) {
    self.days = days
    self.repeats = repeats
    self.observedDays = observedDays
    self.lastUpdated = lastUpdated
  }

  public static let empty = InsightsSnapshot(days: [], repeats: [], observedDays: [], lastUpdated: nil)

  /// Repeats not declined: what "9 things you repeat" counts.
  public var thingsYouRepeat: [RepeatPattern] { repeats.filter { !$0.isDeclined } }
  /// The top 5 things you repeat.
  public var topRepeats: [RepeatPattern] { LocalInsights.top(repeats) }
  public var isEmpty: Bool { days.isEmpty }

  public func day(_ label: String) -> DayInsights? { days.first { $0.day == label } }
}

public actor InsightsStore {
  public struct Sources: Sendable {
    public var reader: any InsightEventReader
    public var live: (any LocalEventSource)?
    /// The Never watch list as rules, read on every recompute (so a new entry applies without a new import).
    public var exclusions: @Sendable () -> [ImportExclusionRule]
    public var answers: any LocalAnswerStore
    /// The person's goal ids, for the goal weight.
    public var goals: @Sendable () -> [String]
    public var timeZone: TimeZone
    public var now: @Sendable () -> Date

    public init(reader: any InsightEventReader, live: (any LocalEventSource)? = nil,
                exclusions: @escaping @Sendable () -> [ImportExclusionRule] = { [] },
                answers: any LocalAnswerStore = MemoryLocalAnswerStore(), goals: @escaping @Sendable () -> [String] = { [] },
                timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }) {
      self.reader = reader
      self.live = live
      self.exclusions = exclusions
      self.answers = answers
      self.goals = goals
      self.timeZone = timeZone
      self.now = now
    }
  }

  public nonisolated let sources: Sources
  private var cache: [String: DayInsights] = [:]
  private var updated: Date?
  /// Every day recomputed, in order (tests count them).
  public private(set) var recomputed: [String] = []

  public init(sources: Sources) { self.sources = sources }

  public nonisolated var timeZone: TimeZone { sources.timeZone }

  /// Recomputes these days (YYYY-MM-DD) from the imports kept on this Mac, plus live events for today.
  @discardableResult
  public func recompute(days labels: [String]) -> InsightsSnapshot {
    let tz = sources.timeZone
    let wanted = Array(Set(labels)).sorted()
    let intervals = wanted.compactMap { LocalDays.interval(of: $0, timeZone: tz) }
    guard let lo = intervals.map(\.start).min(), let hi = intervals.map(\.end).max() else { return snapshot() }
    // A span can start the evening before; read a day on each side once.
    let cal = LocalDays.calendar(tz)
    let from = cal.date(byAdding: .day, value: -1, to: lo) ?? lo
    let to = cal.date(byAdding: .day, value: 1, to: hi) ?? hi
    let imported = sources.reader.events(in: DateInterval(start: from, end: to))
    let rules = sources.exclusions()
    let now = sources.now()
    let today = LocalDays.label(now, timeZone: tz)
    for label in wanted {
      var events = imported
      if label == today, let live = sources.live, let interval = LocalDays.interval(of: label, timeZone: tz) {
        events += LocalEventInsightSource(source: live).events(in: DateInterval(start: interval.start, end: min(interval.end, now)))
      }
      let d = LocalInsights.day(events, day: label, timeZone: tz, exclusions: rules, until: now)
      cache[label] = d.isEmpty ? nil : d
      recomputed.append(label)
    }
    updated = now
    return snapshot()
  }

  /// Recomputes every day from `from` to `to` (an import's first and last day).
  @discardableResult
  public func recompute(from: Date, to: Date) -> InsightsSnapshot {
    recompute(days: LocalDays.labels(from: from, to: to, timeZone: sources.timeZone))
  }

  /// Every day the imports hold, every cached day, and today when live capture can have data (at launch, and after a
  /// Never watch change).
  @discardableResult
  public func refreshAll() -> InsightsSnapshot {
    let tz = sources.timeZone
    var labels = Set(sources.reader.dayLabels(timeZone: tz)).union(cache.keys)
    if sources.live != nil { labels.insert(LocalDays.label(sources.now(), timeZone: tz)) }
    return recompute(days: Array(labels))
  }

  /// The cached days and the repeats ranked with the answers as they are now.
  public func snapshot() -> InsightsSnapshot {
    let days = cache.values.sorted { $0.day < $1.day }
    let adjustments = RankingAdjustments(store: sources.answers)
    let repeats = LocalInsights.repeats(days: days, now: sources.now(), timeZone: sources.timeZone,
                                        adjustments: adjustments, goals: sources.goals())
    return InsightsSnapshot(days: days, repeats: repeats, observedDays: days.map(\.day), lastUpdated: updated)
  }
}

/// Publishes local insights for the screens (Today, Weekly review, Recordings). Only publishes: every rule is in
/// LocalInsights and the store.
@MainActor
public final class InsightsModel: ObservableObject {
  @Published public private(set) var snapshot: InsightsSnapshot = .empty
  /// True while days are being recomputed (an import just finished, the launch refresh, a Never watch change).
  @Published public private(set) var isAnalysing = false

  public let store: InsightsStore
  public nonisolated let timeZone: TimeZone
  /// The weekly review answers on this Mac (m3-12 records through it; ranking reads it on every snapshot).
  public nonisolated let answers: any LocalAnswerStore
  private var running = 0
  private(set) var coordinator: InsightsCoordinator?
  private var cancellables: Set<AnyCancellable> = []
  private var lastExclusions: Set<Exclusion> = []

  public init(store: InsightsStore) {
    self.store = store
    self.timeZone = store.timeZone
    self.answers = store.sources.answers
  }

  /// Nothing imported and no live source.
  public static func empty(timeZone: TimeZone = .current) -> InsightsModel {
    InsightsModel(store: InsightsStore(sources: InsightsStore.Sources(reader: NoInsightEvents(), timeZone: timeZone)))
  }

  /// Marks the model as analysing at once, then runs `work` on the store and publishes its snapshot.
  @discardableResult
  public func schedule(_ work: @escaping @Sendable (InsightsStore) async -> InsightsSnapshot) -> Task<Void, Never> {
    running += 1
    isAnalysing = true
    let store = self.store
    return Task { @MainActor [weak self] in
      let s = await work(store)
      self?.finished(s)
    }
  }

  public func recompute(days: [String]) async {
    await schedule { await $0.recompute(days: days) }.value
  }

  public func refreshAll() async {
    await schedule { await $0.refreshAll() }.value
  }

  /// The ranking again, after an answer was recorded (no day is recomputed).
  public func reload() async {
    let s = await store.snapshot()
    snapshot = s
  }

  /// Listens to the recordings import (InsightsCoordinator) and keeps the coordinator.
  @discardableResult
  public func observe(_ recordings: RecordingsImportModel) -> InsightsCoordinator {
    let c = InsightsCoordinator(insights: self)
    c.observe(recordings)
    coordinator = c
    return c
  }

  /// Recounts every day when the Never watch list changed, so an added entry applies without a new import.
  /// `rules` is read on the main actor first (app names are looked up there) and handed to the store through `box`.
  public func follow(exclusions source: any ExclusionSource, changes: ObservableObjectPublisher,
                     rules: @escaping @MainActor @Sendable () -> [ImportExclusionRule], box: ExclusionRulesBox) {
    lastExclusions = Set(source.currentExclusions())
    box.rules = rules()
    changes
      .sink { [weak self] _ in
        // objectWillChange fires before the change: look after it.
        Task { @MainActor [weak self] in self?.exclusionsMayHaveChanged(source, rules: rules, box: box) }
      }
      .store(in: &cancellables)
  }

  func exclusionsMayHaveChanged(_ source: any ExclusionSource, rules: @MainActor @Sendable () -> [ImportExclusionRule],
                                box: ExclusionRulesBox) {
    let now = Set(source.currentExclusions())
    guard now != lastExclusions else { return }
    lastExclusions = now
    box.rules = rules()
    schedule { await $0.refreshAll() }
  }

  /// For tests: publishes a snapshot as if it was computed.
  func publish(_ s: InsightsSnapshot) { snapshot = s }

  private func finished(_ s: InsightsSnapshot) {
    snapshot = s
    running = max(0, running - 1)
    isAnalysing = running > 0
  }
}

/// The Never watch rules for the store, set on the main actor and read off it.
public final class ExclusionRulesBox: @unchecked Sendable {
  private let lock = NSLock()
  private var current: [ImportExclusionRule]

  public init(_ rules: [ImportExclusionRule] = []) { current = rules }

  public var rules: [ImportExclusionRule] {
    get {
      lock.lock()
      defer { lock.unlock() }
      return current
    }
    set {
      lock.lock()
      current = newValue
      lock.unlock()
    }
  }
}

/// Recomputes the right days when the recordings import changes: a finished import's days (first to last), a removed
/// import's days, and everything once at launch. Nothing while no import has finished.
@MainActor
public final class InsightsCoordinator {
  public let insights: InsightsModel
  private var cancellables: Set<AnyCancellable> = []
  private var known: [ImportRecord] = []
  private var pending: [Task<Void, Never>] = []

  public init(insights: InsightsModel) { self.insights = insights }

  public func observe(_ recordings: RecordingsImportModel) {
    known = recordings.imports
    recordings.$phase
      .sink { [weak self] phase in MainActor.assumeIsolated { self?.phaseChanged(phase) } }
      .store(in: &cancellables)
    recordings.$imports
      .sink { [weak self] imports in MainActor.assumeIsolated { self?.importsChanged(imports) } }
      .store(in: &cancellables)
  }

  /// `.done` with something read: that import's days.
  public func phaseChanged(_ phase: RecordingsImportModel.Phase) {
    guard case .done(let report) = phase, report.space != nil, report.filesRead > 0,
          let first = report.firstDay, let last = report.lastDay else { return }
    let labels = LocalDays.labels(from: first, to: last, timeZone: insights.timeZone)
    run { await $0.recompute(days: labels) }
  }

  /// An import left the list ("Remove imported data"): its days.
  public func importsChanged(_ imports: [ImportRecord]) {
    let ids = Set(imports.map(\.space.id))
    let removed = known.filter { !ids.contains($0.space.id) }
    known = imports
    var labels: [String] = []
    for r in removed {
      guard let first = r.first ?? r.last, let last = r.last ?? r.first else { continue }
      labels += LocalDays.labels(from: first, to: last, timeZone: insights.timeZone)
    }
    guard !labels.isEmpty else { return }
    let days = labels
    run { await $0.recompute(days: days) }
  }

  /// At launch: every day, off the main actor (the store is an actor).
  public func start() {
    run { await $0.refreshAll() }
  }

  /// Waits until every recompute asked for so far has finished.
  public func idle() async {
    let tasks = pending
    for t in tasks { await t.value }
  }

  private func run(_ work: @escaping @Sendable (InsightsStore) async -> InsightsSnapshot) {
    pending.append(insights.schedule(work))
  }
}
