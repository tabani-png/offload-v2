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
    /// The current week before its slot, or a week the brain has no review for yet.
    case notYet(ISOWeek)
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
  private var cancellable: AnyCancellable?

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
      cancellable = insights.$snapshot.dropFirst().sink { [weak self] snapshot in
        MainActor.assumeIsolated { self?.rebuildLocal(snapshot) }
      }
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

  /// The slot changed (Settings): the shown week follows it.
  public func slotChanged() async {
    if followsNow { week = ReviewSchedule.shownWeek(now: now(), slot: slot()) }
    await refresh()
  }

  /// The shown week again without loading (the slot was read at launch).
  public func followSlot() {
    if followsNow { week = ReviewSchedule.shownWeek(now: now(), slot: slot()) }
  }

  // MARK: Content

  public func refresh() async {
    answerError = nil
    if ReviewSchedule.isNotYet(week, now: now(), slot: slot()) {
      content = nil
      state = .notYet(week)
      return
    }
    if isLocal {
      rebuildLocal(insights.snapshot)
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
      state = e == .notFound || e.code == .notFound ? .notYet(requested) : .failed(ReviewError(e))
    } catch {
      guard requested.id == week.id else { return }
      content = nil
      state = .failed(.other)
    }
  }

  private func rebuildLocal(_ snapshot: InsightsSnapshot) {
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
      state = .empty
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
      rebuildLocal(insights.snapshot)
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
  final class SlotHolder {
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

  /// `.local`: the slot kept on this Mac, else the rhythm. `.cloud`: `GET /v1/profile` (the slot shown so far stays
  /// when it fails).
  public func load() async {
    if backends.mode.isLocal {
      set(ReviewSlot.resolve(store: store, rhythm: rhythm(), timeZone: timeZone))
      return
    }
    guard let brain = backends.brain else { return }
    if let profile = try? await brain.profile(), let s = ReviewSlot(brain: profile.reviewSlot, timeZone: timeZone) {
      set(s)
    }
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

  private func set(_ s: ReviewSlot) {
    guard s != holder.slot else { return }
    objectWillChange.send()
    holder.slot = s
  }
}

/// What AppModel keeps for the weekly review: the screen's model, the Settings section and the notification. Built
/// from AppModel's parts; it keeps no reference to AppModel.
@MainActor
public final class WeeklyReviewHub {
  public let review: WeeklyReviewModel
  public let settings: ReviewSettingsModel

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
  }

  /// The app's: goals and rhythm from onboarding's profile answers, the slot and toggle in `UserDefaults`, macOS
  /// notifications that open Weekly review when clicked.
  public convenience init(app: AppModel) {
    let onboarding = app.onboarding
    let navigation = app.navigation
    self.init(backends: app.backends, insights: app.insights, navigation: navigation,
              goals: { [weak onboarding] in onboarding?.state.profile.goals ?? [] },
              rhythm: { [weak onboarding] in onboarding?.state.profile.rhythm },
              store: UserDefaultsReviewSettingsStore(),
              notifier: LiveReviewNotifier(onOpen: { [weak navigation] in
                navigation?.selection = .weeklyReview
                NSApp.activate()
              }))
  }

  /// At launch, off the main path: read the slot (the profile in `.cloud`) and keep the notification if it is on.
  public func start() {
    Task { await startAndWait() }
  }

  public func startAndWait() async {
    await settings.load()
    review.followSlot()
    await settings.scheduler.start()
  }
}
