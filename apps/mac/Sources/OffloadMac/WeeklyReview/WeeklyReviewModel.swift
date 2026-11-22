import AppKit
import Combine
import Foundation

// The weekly review's models (SPEC m3-12 Contract): the screen (`WeeklyReviewModel`), the Settings section
// (`ReviewSettingsModel`, with the notification's `ReviewScheduler`) and the hub AppModel keeps (`WeeklyReviewHub`).
// The backend mode decides where content comes from: `.local` counts on this Mac and never calls a client.

/// Why a cloud review could not be loaded, one sentence each.
public enum ReviewError: String, Equatable, Sendable {
  case offline, signedOut, busy, server, other

  public init(_ error: APIError) {
    if error.isOffline {
      self = .offline
      return
    }
    switch error {
    case .notSignedIn:
      self = .signedOut
    case .transport:
      self = .offline
    case .server(let status, let code, _, _, _):
      switch code {
      case .unauthenticated, .tokenExpired: self = .signedOut
      case .rateLimited: self = .busy
      case .serverError: self = .server
      default: self = status >= 500 ? .server : .other
      }
    case .badResponse(let status):
      self = status >= 500 ? .server : .other
    default:
      self = .other
    }
  }

  public var sentence: String {
    switch self {
    case .offline: return ReviewCopy.failedOffline
    case .signedOut: return ReviewCopy.failedSignedOut
    case .busy: return ReviewCopy.failedBusy
    case .server: return ReviewCopy.failedServer
    case .other: return ReviewCopy.failedOther
    }
  }
}

@MainActor
public final class WeeklyReviewModel: ObservableObject {
  public enum State: Equatable, Sendable {
    case loading
    case ready
    /// `.local`: nothing counted in the week.
    case empty
    /// The current week before its slot (never requested, never computed).
    case notYet(ISOWeek)
    /// `.cloud`: the brain has no review for a week whose slot has passed (a 404).
    case noReview(ISOWeek)
    case failed(ReviewError)
  }

  @Published public private(set) var week: ISOWeek
  @Published public private(set) var content: ReviewContent?
  @Published public private(set) var state: State = .loading
  /// A line under the questions when an answer was not taken.
  @Published public private(set) var answerError: String?
  /// Questions whose answer is being saved.
  @Published public private(set) var answering: Set<String> = []

  public let backends: Backends
  public let insights: InsightsModel
  public let navigation: NavigationModel
  private let goals: @MainActor () -> [String]
  private let slot: @MainActor () -> ReviewSlot
  private let now: @Sendable () -> Date
  /// True until the person steps to another week: the screen then follows the slot.
  private var followsNow = true
  /// True once the screen asked for content: a slot read at launch then moves the week without loading.
  private var hasRefreshed = false
  private var cancellables: Set<AnyCancellable> = []
  /// Wakes at the next slot so a screen left open moves to this week (review 1, finding 2).
  private var slotTimer: Task<Void, Never>?
  private var wakeObserver: NSObjectProtocol?

  public init(backends: Backends, insights: InsightsModel, navigation: NavigationModel,
              goals: @escaping @MainActor () -> [String], slot: @escaping @MainActor () -> ReviewSlot,
              now: @escaping @Sendable () -> Date = { Date() }) {
    self.backends = backends
    self.insights = insights
    self.navigation = navigation
    self.goals = goals
    self.slot = slot
    self.now = now
    week = ReviewSchedule.shownWeek(now: now(), slot: slot())
    if backends.mode.isLocal {
      // A finished import or a Never watch change publishes a new snapshot: the review follows it. `$snapshot` sends
      // the new value before the property changes, so the value it sends is used.
      insights.$snapshot.dropFirst().sink { [weak self] snapshot in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.rebuildLocal(snapshot, analysing: self.insights.isAnalysing)
        }
      }
      .store(in: &cancellables)
      // While a recount runs an empty week reads loading, not "Nothing counted" (review 1, finding 4).
      insights.$isAnalysing.dropFirst().sink { [weak self] analysing in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.rebuildLocal(self.insights.snapshot, analysing: analysing)
        }
      }
      .store(in: &cancellables)
    }
  }

  public var isLocal: Bool { backends.mode.isLocal }
  public var provenance: DataProvenance { backends.provenance }
  public var currentSlot: ReviewSlot { slot() }

  public var notYetLine: String? {
    if case .notYet = state { return ReviewCopy.notYet(slot()) }
    return nil
  }

  public var failureLine: String? {
    if case .failed(let e) = state { return e.sentence }
    return nil
  }

  /// The one line a state without content shows (not yet, no review, failed).
  public var stateLine: String? {
    switch state {
    case .notYet: return ReviewCopy.notYet(slot())
    case .noReview: return ReviewCopy.noReview
    case .failed(let e): return e.sentence
    case .loading, .ready, .empty: return nil
    }
  }

  /// The next slot after now: when the shown week moves next.
  public var nextSlot: Date { ReviewSchedule.next(after: now(), slot: slot()) }

  // MARK: Weeks

  private var currentWeek: ISOWeek { ReviewSchedule.currentWeek(now: now(), slot: slot()) }

  /// Weeks with data counted on this Mac.
  private var dataWeeks: [ISOWeek] { WeekStats.weeks(insights.snapshot.days, timeZone: slot().timeZone).map(\.week) }

  private var previousTarget: ISOWeek? {
    let shown = week
    return isLocal ? dataWeeks.last(where: { $0 < shown }) : shown.previous
  }

  private var nextTarget: ISOWeek? {
    let current = currentWeek
    guard week < current else { return nil }
    let shown = week
    if isLocal { return dataWeeks.first(where: { $0 > shown && !(current < $0) }) ?? current }
    return week.next
  }

  /// The latest week with data up to now, other than the shown one: the empty state offers it, because an imported
  /// archive often holds only older weeks.
  public var latestDataWeek: ISOWeek? {
    guard isLocal else { return nil }
    let current = currentWeek
    let shown = week
    return dataWeeks.last(where: { !(current < $0) && $0.id != shown.id })
  }

  public func showLatestData() async {
    guard let target = latestDataWeek else { return }
    followsNow = false
    await show(target)
  }

  public var canGoBack: Bool { previousTarget != nil }
  public var canGoForward: Bool { nextTarget != nil }

  public func previousWeek() async {
    guard let target = previousTarget else { return }
    followsNow = false
    await show(target)
  }

  public func nextWeek() async {
    guard let target = nextTarget else { return }
    followsNow = false
    await show(target)
  }

  public func show(_ target: ISOWeek) async {
    week = target
    await refresh()
  }

  /// When the screen appears: the shown week follows the slot unless the person stepped to another week.
  public func followNow() async {
    if followsNow { week = ReviewSchedule.shownWeek(now: now(), slot: slot()) }
    await refresh()
  }

  /// The slot changed (Settings, or the profile read at launch): the shown week follows it, and is loaded again only
  /// when the screen already asked for content.
  public func slotChanged() async {
    if slotTimer != nil { startFollowingSlot() }
    if followsNow { week = ReviewSchedule.shownWeek(now: now(), slot: slot()) }
    if hasRefreshed { await refresh() }
  }

  /// The slot passed: a screen that follows now moves to this week, and is loaded again only when the screen already
  /// asked for content (review 2, finding 3: no request nobody asked for).
  public func slotPassed() async {
    if followsNow { week = ReviewSchedule.shownWeek(now: now(), slot: slot()) }
    if hasRefreshed { await refresh() }
  }

  /// The Mac woke: if a slot passed while it slept, the screen moves now (review 2, finding 2).
  public func didWake() async {
    guard followsNow, ReviewSchedule.shownWeek(now: now(), slot: slot()).id != week.id else { return }
    await slotPassed()
  }

  /// The review notification was clicked: back to the week the slot shows, whichever week was open.
  public func returnToNow() async {
    followsNow = true
    await followNow()
  }

  /// Sleeps until each next slot (at most 6 hours at a time, on the continuous clock, which counts time the Mac slept)
  /// and then calls `slotPassed()`; waking the Mac checks at once.
  public func startFollowingSlot() {
    if wakeObserver == nil {
      wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        Task { @MainActor in await self.didWake() }
      }
    }
    slotTimer?.cancel()
    slotTimer = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let target = self?.nextSlot, let start = self?.now() else { return }
        let wait = min(max(target.timeIntervalSince(start), 1), 6 * 3600)
        try? await Task.sleep(for: .seconds(wait), clock: .continuous)
        guard !Task.isCancelled, let self else { return }
        if self.now() >= target { await self.slotPassed() }
      }
    }
  }

  /// The shown week again without loading (the slot was read at launch).
  public func followSlot() {
    if followsNow { week = ReviewSchedule.shownWeek(now: now(), slot: slot()) }
  }

  // MARK: Content

  public func refresh() async {
    answerError = nil
    hasRefreshed = true
    if ReviewSchedule.isNotYet(week, now: now(), slot: slot()) {
      content = nil
      state = .notYet(week)
      return
    }
    if isLocal {
      rebuildLocal(insights.snapshot, analysing: insights.isAnalysing)
      return
    }
    guard let brain = backends.brain else {
      content = nil
      state = .failed(.signedOut)
      return
    }
    let requested = week
    if content?.week.id != requested.id { state = .loading }
    do {
      let review = try await brain.weekReview(isoWeek: requested.id)
      guard requested.id == week.id else { return }
      content = .cloud(review: review, week: requested)
      state = .ready
    } catch let e as APIError {
      guard requested.id == week.id else { return }
      content = nil
      // Weeks before their slot are never requested, so a 404 means the brain has no review for this week.
      state = e == .notFound || e.code == .notFound ? .noReview(requested) : .failed(ReviewError(e))
    } catch {
      guard requested.id == week.id else { return }
      content = nil
      state = .failed(.other)
    }
  }

  private func rebuildLocal(_ snapshot: InsightsSnapshot, analysing: Bool) {
    guard isLocal else { return }
    if ReviewSchedule.isNotYet(week, now: now(), slot: slot()) {
      content = nil
      state = .notYet(week)
      return
    }
    if let c = ReviewContent.local(snapshot: snapshot, week: week, goals: goals(), answers: insights.answers.answers()) {
      content = c
      state = .ready
    } else {
      content = nil
      state = analysing ? .loading : .empty
    }
  }

  /// Empty state's **Choose recordings**.
  public func chooseRecordings() { navigation.selection = .recordings }

  // MARK: Answers

  /// One tap. `goalID` is the goal picked for **It's for another goal**. `.local` writes the answer on this Mac and
  /// ranking reads it at once; `.cloud` posts `POST /v1/review/answers`. **OK, build** opens Build progress.
  public func answer(_ question: WeekQuestion, _ chip: ReviewChip, goalID: String? = nil) async {
    answerError = nil
    let kind = chip.answer
    let goal: String?
    if kind == .otherGoal {
      goal = goalID ?? chip.goalID
      guard goal != nil else {
        answerError = ReviewCopy.pickGoal
        return
      }
    } else {
      goal = ReviewAnswerKind.goalAnswers.contains(kind) ? (chip.goalID ?? goalID) : nil
    }
    let answeredWeek = week
    answering.insert(question.subjectKey)
    defer { answering.remove(question.subjectKey) }
    if isLocal {
      guard let local = LocalAnswer(rawValue: kind.raw) else { return }
      let record = LocalReviewAnswer(isoWeek: answeredWeek.id, subjectKey: question.subjectKey, answer: local, goalID: goal,
                                     answeredAt: now(), minutesPerWeek: question.minutesPerWeek,
                                     questionKind: question.questionKind)
      do {
        try insights.answers.record(record)
      } catch {
        answerError = ReviewCopy.answerFailed
        return
      }
      await insights.reload()
      rebuildLocal(insights.snapshot, analysing: insights.isAnalysing)
    } else {
      guard let brain = backends.brain else {
        answerError = ReviewCopy.answerFailed
        return
      }
      do {
        _ = try await brain.answer(ReviewAnswerRequest(isoWeek: answeredWeek.id, subjectKey: question.subjectKey,
                                                        answer: kind, goalID: goal))
      } catch {
        answerError = ReviewCopy.answerFailed
        return
      }
      if answeredWeek.id == week.id, var c = content, let i = c.questions.firstIndex(where: { $0.subjectKey == question.subjectKey }) {
        c.questions[i].answered = kind
        c.questions[i].answeredGoalID = goal
        content = c
      }
    }
    if kind == .build {
      navigation.startBuild(isLocal
        ? .localRepeat(key: question.subjectKey, name: question.name, minutesPerWeek: question.minutesPerWeek)
        : .opportunity(id: question.subjectKey, optionID: nil))
    }
  }
}

/// The Settings section: the review slot (on this Mac in `.local`, the brain profile's `review_slot` in `.cloud`) and
/// the notification toggle (on this Mac in both).
@MainActor
public final class ReviewSettingsModel: ObservableObject {
  /// Shared with the scheduler, which reads the slot when it schedules.
  @MainActor final class SlotHolder {
    var slot: ReviewSlot
    init(_ slot: ReviewSlot) { self.slot = slot }
  }

  @Published public private(set) var error: String?
  public let scheduler: ReviewScheduler
  public let backends: Backends
  public let timeZone: TimeZone
  /// The hub sets it: the review screen follows a new slot.
  public var onSlotChange: (@MainActor () async -> Void)?

  private let holder: SlotHolder
  private let store: any ReviewSettingsStore
  private let rhythm: @MainActor () -> Rhythm?

  public init(backends: Backends, store: any ReviewSettingsStore, rhythm: @escaping @MainActor () -> Rhythm?,
              timeZone: TimeZone, notifier: any ReviewNotifier) {
    self.backends = backends
    self.store = store
    self.rhythm = rhythm
    self.timeZone = timeZone
    let holder = SlotHolder(ReviewSlot.resolve(store: backends.mode.isLocal ? store : nil, rhythm: rhythm(), timeZone: timeZone))
    self.holder = holder
    scheduler = ReviewScheduler(notifier: notifier, store: store, slot: { holder.slot })
  }

  public var slot: ReviewSlot { holder.slot }
  /// "Fri 4:00 PM".
  public var slotText: String { slot.text }
  public var notifyOn: Bool { scheduler.isOn }

  /// The review screen offers the notification while it is off and was never offered, accepted or declined
  /// (ONBOARDING section 12: "notification offered here for the first time").
  public var showsNotificationOffer: Bool { !scheduler.isOn && !store.offerDone }

  /// **Tell me when my review is ready** on the review screen: macOS is asked once (by the scheduler).
  public func acceptNotificationOffer() async {
    markOffered()
    await scheduler.setOn(true)
  }

  /// **No thanks**: the offer does not come back; the toggle stays in Settings.
  public func dismissNotificationOffer() { markOffered() }

  /// The Settings toggle: the same as answering the offer.
  public func setNotify(_ on: Bool) async {
    markOffered()
    await scheduler.setOn(on)
  }

  private func markOffered() {
    guard !store.offerDone else { return }
    objectWillChange.send()
    store.offerDone = true
  }

  /// `.local`: the slot kept on this Mac, else the rhythm. `.cloud`: `GET /v1/profile` (the slot shown so far stays
  /// when it fails).
  /// A slot that differs from the one shown moves the notification and the review screen (review 1, finding 6).
  public func load() async {
    var read: ReviewSlot?
    if backends.mode.isLocal {
      read = ReviewSlot.resolve(store: store, rhythm: rhythm(), timeZone: timeZone)
    } else if let brain = backends.brain, let profile = try? await brain.profile() {
      read = ReviewSlot(brain: profile.reviewSlot, timeZone: timeZone)
    }
    guard let read, set(read) else { return }
    await scheduler.slotChanged()
    await onSlotChange?()
  }

  /// A new slot: saved on this Mac in `.local`, `PATCH /v1/profile { review_slot }` in `.cloud`; then the
  /// notification and the screen follow it.
  public func setSlot(day: Weekday, time: String) async {
    guard ReviewSlot.parse(time) != nil else { return }
    let next = ReviewSlot(day: day, time: time, timeZone: timeZone)
    if backends.mode.isLocal {
      store.saveSlot(day: day, time: time)
      set(next)
    } else {
      guard let brain = backends.brain else {
        error = ReviewCopy.slotSaveFailed
        return
      }
      var patch = BrainProfilePatch()
      patch.setReviewSlot(next.brain)
      do {
        let profile = try await brain.updateProfile(patch)
        set(ReviewSlot(brain: profile.reviewSlot, timeZone: timeZone) ?? next)
      } catch {
        self.error = ReviewCopy.slotSaveFailed
        return
      }
    }
    error = nil
    await scheduler.slotChanged()
    await onSlotChange?()
  }

  /// True when the slot changed.
  @discardableResult
  private func set(_ s: ReviewSlot) -> Bool {
    guard s != holder.slot else { return false }
    objectWillChange.send()
    holder.slot = s
    return true
  }
}

/// What AppModel keeps for the weekly review: the screen's model, the Settings section and the notification. Built
/// from AppModel's parts; it keeps no reference to AppModel.
@MainActor
public final class WeeklyReviewHub: ObservableObject {
  /// Each click on the review notification adds one: `WeeklyReviewWindowOpener` (on the always-present menu bar
  /// label) answers with `openWindow(id: "main")`, so the review shows even when the main window was closed.
  @Published public private(set) var windowRequests = 0
  public let review: WeeklyReviewModel
  public let settings: ReviewSettingsModel
  public let navigation: NavigationModel

  public init(backends: Backends, insights: InsightsModel, navigation: NavigationModel,
              goals: @escaping @MainActor () -> [String], rhythm: @escaping @MainActor () -> Rhythm?,
              store: any ReviewSettingsStore, notifier: any ReviewNotifier, now: @escaping @Sendable () -> Date = { Date() }) {
    let settings = ReviewSettingsModel(backends: backends, store: store, rhythm: rhythm, timeZone: insights.timeZone,
                                       notifier: notifier)
    let review = WeeklyReviewModel(backends: backends, insights: insights, navigation: navigation, goals: goals,
                                   slot: { [unowned settings] in settings.slot }, now: now)
    settings.onSlotChange = { [weak review] in await review?.slotChanged() }
    self.settings = settings
    self.review = review
    self.navigation = navigation
  }

  /// The review notification was clicked: Weekly review opens on the week the slot shows (review 1, finding 2).
  public func openFromNotification() async {
    windowRequests += 1
    navigation.selection = .weeklyReview
    await review.returnToNow()
  }

  /// The app's: goals and rhythm from onboarding's profile answers, the slot and toggle in `UserDefaults`, macOS
  /// notifications that open Weekly review when clicked.
  public convenience init(app: AppModel) {
    let onboarding = app.onboarding
    let opener = ReviewOpener()
    let notifier = LiveReviewNotifier(onOpen: {
      NSApp.activate()
      Task {
        await opener.hub?.openFromNotification()
        // An open main window (for example behind Settings) comes forward even if the opener is not mounted.
        NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(WeeklyReviewWindow.mainWindowID) == true })?
          .makeKeyAndOrderFront(nil)
      }
    })
    self.init(backends: app.backends, insights: app.insights, navigation: app.navigation,
              goals: { [weak onboarding] in onboarding?.state.profile.goals ?? [] },
              rhythm: { [weak onboarding] in onboarding?.state.profile.rhythm },
              store: UserDefaultsReviewSettingsStore(), notifier: notifier)
    opener.hub = self
    // At once, so a click that launched Offload finds its handler (review 1, finding 3).
    notifier.installPresenter()
  }

  /// At launch, off the main path: read the slot (the profile in `.cloud`) and keep the notification if it is on.
  public func start() {
    review.startFollowingSlot()
    Task { await startAndWait() }
  }

  public func startAndWait() async {
    await settings.load()
    review.followSlot()
    await settings.scheduler.start()
  }
}

/// Lets the notification's click handler, made before the hub, reach it.
@MainActor
final class ReviewOpener {
  weak var hub: WeeklyReviewHub?
}
