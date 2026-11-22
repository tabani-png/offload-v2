import Combine
import Foundation

// The live Today screen's model (m3-11): which day is shown, what state the screen is in, the answers on the
// suggested fix, the hand-off to Build progress and the keys. It only decides and publishes; the numbers come from
// TodayContent's builders, the data from m3-10's insights (`.local`) or the brain and builds clients (`.cloud`).

/// A key the fix card handles: 1, 2, 3 pick an option, Return presses the primary button.
public enum TodayKey: Equatable, Sendable {
  case digit(Int)
  case `return`
}

/// Why a cloud read failed, as one sentence each (SPEC Design note, States).
public enum TodayError: Equatable, Sendable {
  /// `unauthenticated`, `token_expired`, or no member token.
  case signIn
  /// The request did not reach Offload.
  case offline
  /// Any other code.
  case other(String)

  public init(_ error: any Error) {
    if let e = error as? APIError {
      switch e {
      case .notSignedIn: self = .signIn
      case .server(_, let code, _, _, _):
        switch code {
        case .unauthenticated, .tokenExpired: self = .signIn
        default: self = .other(code.raw)
        }
      case .transport: self = .offline
      case .notFound: self = .other(APIErrorCode.notFound.raw)
      case .badResponse(let status): self = .other("status \(status)")
      case .refusedPath: self = .other("refused_path")
      case .signingUnavailable: self = .other("signing_unavailable")
      case .invalidBody: self = .other("invalid_body")
      }
    } else if error is URLError {
      self = .offline
    } else {
      self = .other("unknown")
    }
  }

  public var sentence: String {
    switch self {
    case .signIn: return TodayCopy.signInAgain
    case .offline: return TodayCopy.offline
    case .other(let code): return TodayCopy.couldNotLoad(code)
    }
  }
}

@MainActor
public final class TodayLiveModel: ObservableObject {
  public enum State: Equatable, Sendable {
    /// `.local` with nothing counted: "Nothing counted yet."
    case empty
    /// An import is reading (`of > 0`), or local insights are counting (`of == 0`). `content` holds what was already
    /// counted.
    case importing(file: Int, of: Int)
    case ready(TodayContent)
    /// `.cloud`: the brain has no record of this day (404).
    case notRecorded(String)
    case failed(TodayError)
  }

  @Published public private(set) var state: State = .empty
  /// What was counted for the shown day; nil when nothing was (never an old day's numbers after a failure).
  @Published public private(set) var content: TodayContent?
  /// The shown day (YYYY-MM-DD).
  @Published public private(set) var day: String?
  /// `.local`: the days with data, oldest first.
  @Published public private(set) var days: [String] = []
  /// The picked option on the card (index), nil without options.
  @Published public private(set) var selectedOption: Int?
  /// The repeats (and header items) whose how line is open.
  @Published public private(set) var shownHow: Set<String> = []
  /// The fix card has keyboard focus: only then do 1, 2, 3 and Return act.
  @Published public var cardFocused = false
  /// One sentence when an answer could not be saved or sent.
  @Published public private(set) var answerError: String?
  /// `.cloud`: true until the first read of the shown day has finished.
  @Published public private(set) var isLoading = false

  public let app: AppModel
  public let timeZone: TimeZone
  private let now: @Sendable () -> Date
  private let reloadRanking: @MainActor () async -> Void
  private var snapshot: InsightsSnapshot
  private var phase: RecordingsImportModel.Phase
  private var analysing: Bool
  /// `.local`: the day the person stepped to, kept while it has data.
  private var pinnedDay: String?
  /// `.cloud`: the last read, for the once-a-minute rule.
  private var lastCloudRead: (day: String, at: Date)?
  private var cloudRecord: DayRecord?
  private var cloudWeek: WeekRecord?
  private var cloudOpportunities: [Opportunity] = []
  /// `.cloud`: today's record, for the menu bar line.
  @Published private var cloudToday: DayRecord?
  private var cardIdentity: String?
  /// An import just finished, so the recount that follows is its days: only that recount (or one with nothing shown
  /// yet) shows the counting line, not live capture's minute-by-minute recount (review 1, finding 4).
  private var importRecount = false
  /// The menu line's own read of today (`.cloud`) or recount of today (`.local` while capturing), once a minute.
  private var lastMenuRefresh: Date?
  /// `.cloud`: the person stepped to a day that is not today; else Today follows the calendar past midnight.
  private var dayPinned = false
  /// The day `menuTick` last saw, so a day change is published once (review 2, finding 1).
  private var lastTodaySeen = ""
  private var cancellables: Set<AnyCancellable> = []

  /// The cloud reads of one day are not repeated within this many seconds unless asked (Try again, a new day).
  public static let cloudReadInterval: TimeInterval = 60
  /// The screen refreshes this often while visible.
  public static let refreshInterval: TimeInterval = 60

  /// `reloadRanking` re-ranks the local repeats after an answer (default: `insights.reload()`).
  public init(app: AppModel, now: @escaping @Sendable () -> Date = { Date() },
              reloadRanking: (@MainActor () async -> Void)? = nil) {
    self.app = app
    self.now = now
    let insights = app.insights
    self.timeZone = insights.timeZone
    self.reloadRanking = reloadRanking ?? { await insights.reload() }
    self.snapshot = insights.snapshot
    self.analysing = insights.isAnalysing
    self.phase = app.recordings?.phase ?? .idle
    if isLocal {
      rebuildLocal()
    } else {
      day = todayLabel
      isLoading = true
    }
    lastTodaySeen = todayLabel
    // @Published sinks run before the property changes: the values they get are used, not the properties.
    insights.$snapshot.dropFirst()
      .sink { [weak self] s in MainActor.assumeIsolated { self?.snapshotChanged(s) } }
      .store(in: &cancellables)
    insights.$isAnalysing.dropFirst()
      .sink { [weak self] a in MainActor.assumeIsolated { self?.analysingChanged(a) } }
      .store(in: &cancellables)
    app.recordings?.$phase.dropFirst()
      .sink { [weak self] p in MainActor.assumeIsolated { self?.phaseChanged(p) } }
      .store(in: &cancellables)
  }

  private static var models: [ObjectIdentifier: TodayLiveModel] = [:]

  /// One model per app: the screen and the menu bar line read the same one, and the day picked survives a trip to
  /// another screen.
  public static func shared(for app: AppModel) -> TodayLiveModel {
    let id = ObjectIdentifier(app)
    if let m = models[id] { return m }
    let m = TodayLiveModel(app: app)
    models[id] = m
    m.startMenuClock()
    return m
  }

  public var isLocal: Bool { app.backends.mode.isLocal }

  private var todayLabel: String { LocalDays.label(now(), timeZone: timeZone) }

  /// The screen's title: the content's, else the shown day's ("Today · Thu, Nov 12"), else "Today".
  public var title: String {
    if let c = content { return c.title }
    guard let d = day else { return TodayCopy.today }
    return TodayCopy.title(day: d, today: todayLabel, timeZone: timeZone)
  }

  // MARK: Updates from m3-10 and m3-05

  private func snapshotChanged(_ s: InsightsSnapshot) {
    snapshot = s
    if isLocal { rebuildLocal() } else { objectWillChange.send() }
  }

  private func analysingChanged(_ a: Bool) {
    analysing = a
    if !a { importRecount = false }
    if isLocal { rebuildLocal() }
  }

  private func phaseChanged(_ p: RecordingsImportModel.Phase) {
    phase = p
    if case .done = p { importRecount = true }
    if isLocal { rebuildLocal() }
  }

  // MARK: Local

  private func rebuildLocal() {
    let available = snapshot.days.filter { $0.activeSeconds.value > 0 }.map(\.day)
    days = available
    if let p = pinnedDay, !available.contains(p) { pinnedDay = nil }
    let today = todayLabel
    let shown = pinnedDay ?? (available.contains(today) ? today : available.last)
    day = shown
    let built = shown.flatMap { label in
      TodayContent.local(snapshot: snapshot, day: label, rhythm: app.onboarding.state.profile.rhythm, timeZone: timeZone,
                         answers: app.insights.answers.answers(), now: now())
    }
    setContent(built)
    if case .reading(let file, let total) = phase {
      state = .importing(file: file, of: total)
    } else if analysing && (built == nil || importRecount) {
      state = .importing(file: 0, of: 0)
    } else if let built {
      state = .ready(built)
    } else {
      state = .empty
    }
  }

  private func setContent(_ c: TodayContent?) {
    content = c
    let identity = c?.fix?.identity
    if identity != cardIdentity {
      cardIdentity = identity
      selectedOption = c?.fix?.defaultSelection
    }
  }

  // MARK: Refresh

  /// When the screen appears and on Try again (`force`). `.local` rebuilds from the snapshot; `.cloud` reads the day,
  /// its week and the open opportunities, at most once a minute per day unless forced.
  public func refresh(force: Bool = false) async {
    if isLocal {
      rebuildLocal()
    } else {
      await readCloud(force: force)
    }
  }

  /// Every 60 s while the screen is visible: `.local` recounts today while live capture runs; `.cloud` reads again
  /// once the minute has passed.
  public func tick() async {
    if isLocal {
      if app.isCapturing {
        importRecount = false
        lastMenuRefresh = now()
        await app.insights.recompute(days: [todayLabel])
      }
      rebuildLocal()
    } else {
      await readCloud(force: false)
    }
  }

  public func tryAgain() async { await refresh(force: true) }

  private func readCloud(force: Bool) async {
    guard let brain = app.backends.brain else {
      // `.cloud` with no client (only a hand-built Backends): say so rather than read forever (review 2, finding 3).
      setContent(nil)
      isLoading = false
      state = .failed(.signIn)
      return
    }
    // Left on today, Today follows the calendar past midnight; a day the person picked stays (review 2, finding 1).
    let shown = dayPinned ? (day ?? todayLabel) : todayLabel
    day = shown
    let t = now()
    if !force, let last = lastCloudRead, last.day == shown, t.timeIntervalSince(last.at) < Self.cloudReadInterval { return }
    lastCloudRead = (shown, t)
    let isoWeek = LocalDays.start(of: shown, timeZone: timeZone).map { LocalDays.isoWeek($0, timeZone: timeZone) }
    do {
      let record: DayRecord
      do {
        record = try await brain.dayRecord(day: shown)
      } catch APIError.notFound {
        guard day == shown else { return }
        if shown == todayLabel { cloudToday = nil }
        cloudRecord = nil
        setContent(nil)
        isLoading = false
        state = .notRecorded(shown)
        return
      }
      var week: WeekRecord?
      if let isoWeek {
        do {
          week = try await brain.weekRecord(isoWeek: isoWeek)
        } catch APIError.notFound {
          week = nil
        }
      }
      let opportunities = try await app.backends.builds?.openOpportunities() ?? []
      // The person may have stepped to another day meanwhile.
      guard day == shown else { return }
      if shown == todayLabel {
        cloudToday = record
        lastMenuRefresh = t
      }
      cloudRecord = record
      cloudWeek = week
      cloudOpportunities = opportunities
      isLoading = false
      rebuildCloud()
    } catch {
      guard day == shown else { return }
      // The menu line shows nothing rather than an old number either (review 1, finding 5).
      if shown == todayLabel { cloudToday = nil }
      cloudRecord = nil
      setContent(nil)
      isLoading = false
      state = .failed(TodayError(error))
    }
  }

  private func rebuildCloud() {
    guard let record = cloudRecord else { return }
    let built = TodayContent.cloud(day: record, week: cloudWeek, opportunities: cloudOpportunities, today: todayLabel,
                                   timeZone: timeZone)
    setContent(built)
    state = built.map { .ready($0) } ?? .notRecorded(record.day)
  }

  // MARK: Days

  public var canGoBack: Bool {
    if isLocal {
      guard let d = day, let i = days.firstIndex(of: d) else { return false }
      return i > 0
    }
    return day != nil
  }

  public var canGoForward: Bool {
    if isLocal {
      guard let d = day, let i = days.firstIndex(of: d) else { return false }
      return i < days.count - 1
    }
    guard let d = day else { return false }
    return d < todayLabel
  }

  /// `.local`: the previous day with data. `.cloud`: the calendar day before.
  public func previousDay() async { await step(-1) }

  /// `.local`: the next day with data. `.cloud`: the calendar day after, never past today.
  public func nextDay() async { await step(1) }

  private func step(_ by: Int) async {
    if isLocal {
      guard let d = day, let i = days.firstIndex(of: d), days.indices.contains(i + by) else { return }
      pinnedDay = days[i + by]
      rebuildLocal()
      return
    }
    guard let d = day, let start = LocalDays.start(of: d, timeZone: timeZone),
          let next = LocalDays.calendar(timeZone).date(byAdding: .day, value: by, to: start) else { return }
    let label = LocalDays.label(next, timeZone: timeZone)
    guard label <= todayLabel, label != d else { return }
    dayPinned = label != todayLabel
    day = label
    await readCloud(force: true)
  }

  // MARK: How it was counted

  public func toggleHow(_ key: String) {
    if shownHow.contains(key) { shownHow.remove(key) } else { shownHow.insert(key) }
  }

  public func isHowShown(_ key: String) -> Bool { shownHow.contains(key) }

  // MARK: The suggested fix

  public func selectOption(_ index: Int) {
    guard let card = content?.fix, card.options.indices.contains(index) else { return }
    selectedOption = index
  }

  /// "OK, build" or "Leave it alone" (when that option is picked); nil without a card.
  public var primaryLabel: String? { content?.fix?.primaryLabel(selected: selectedOption) }

  /// **OK, build**: hands the card to Build progress and opens Builds.
  public func okBuild() {
    guard let card = content?.fix else { return }
    switch card.source {
    case .localRepeat(let key, let name, let minutesPerWeek, _):
      app.navigation.startBuild(.localRepeat(key: key, name: name, minutesPerWeek: minutesPerWeek))
    case .opportunity(let id):
      guard !card.leavesAlone(selected: selectedOption) else { return }
      let option = selectedOption.flatMap { card.options.indices.contains($0) ? card.options[$0] : nil }
      app.navigation.startBuild(.opportunity(id: id, optionID: option?.id))
    }
  }

  /// The primary button: Leave it alone when that option is picked, else OK, build.
  public func pressPrimary() async {
    guard let card = content?.fix else { return }
    if card.leavesAlone(selected: selectedOption) {
      await leaveAlone()
    } else {
      okBuild()
    }
  }

  /// **Not now**: `not_now` for this repeat and week on this Mac, or for the opportunity in the cloud.
  public func notNow() async { await answer(local: .notNow, cloud: .notNow) }

  /// **Leave it alone**: `leave_alone`.
  public func leaveAlone() async { await answer(local: .leaveAlone, cloud: .leaveAlone) }

  private func answer(local: LocalAnswer, cloud: OpportunityAnswer) async {
    guard let card = content?.fix else { return }
    answerError = nil
    switch card.source {
    case .localRepeat(let key, _, let minutesPerWeek, let isoWeek):
      do {
        try app.insights.answers.record(LocalReviewAnswer(isoWeek: isoWeek, subjectKey: key, answer: local,
                                                          answeredAt: now(), minutesPerWeek: minutesPerWeek))
      } catch {
        answerError = TodayCopy.answerNotSaved
        return
      }
      // The card moves on at once; the store then ranks with the answer (Weekly review reads the same ranking).
      rebuildLocal()
      await reloadRanking()
    case .opportunity(let id):
      guard let builds = app.backends.builds else { return }
      do {
        _ = try await builds.answerOpportunity(id: id, answer: cloud, optionID: nil)
      } catch {
        answerError = TodayError(error).sentence
        return
      }
      cloudOpportunities.removeAll { $0.id == id }
      rebuildCloud()
    }
  }

  // MARK: Keys

  /// Whether `key` does something now (the view handles it only then).
  public func accepts(_ key: TodayKey) -> Bool {
    guard cardFocused, let card = content?.fix else { return false }
    switch key {
    case .digit(let n): return n >= 1 && n <= card.options.count
    case .return: return true
    }
  }

  /// 1, 2, 3 pick an option and Return presses the primary button, only while the card has focus. True when handled.
  @discardableResult
  public func handleKey(_ key: TodayKey) async -> Bool {
    guard accepts(key) else { return false }
    switch key {
    case .digit(let n): selectOption(n - 1)
    case .return: await pressPrimary()
    }
    return true
  }

  // MARK: States and banners

  /// The line above the content while importing or counting.
  public var importingLine: String? {
    guard case .importing(let file, let total) = state else { return nil }
    return total == 0 ? TodayCopy.counting : TodayCopy.importing(file: file, of: total)
  }

  /// **Choose recordings** (empty state): the Recordings screen.
  public func chooseRecordings() { app.navigation.selection = .recordings }

  /// m3-04's banners, unchanged.
  public var banners: [TodayBanner] { app.today.banners }

  public func tapBanner(_ banner: TodayBanner) {
    app.tapBanner(banner)
    objectWillChange.send()
  }

  public func dismissBanner(_ banner: TodayBanner) {
    app.dismissBanner(banner)
    objectWillChange.send()
  }

  // MARK: Menu bar

  /// The menu's own refresh, at most once a minute, so its line is there without Today open: `.cloud` reads today's
  /// record (a failure or 404 clears the line); `.local` recounts today while live capture runs, and otherwise the
  /// line is the snapshot's and nothing is read.
  public func refreshMenuLine(force: Bool = false) async {
    let t = now()
    if !force, let last = lastMenuRefresh, t.timeIntervalSince(last) < Self.cloudReadInterval { return }
    if isLocal {
      guard app.isCapturing else { return }
      lastMenuRefresh = t
      await app.insights.recompute(days: [todayLabel])
      return
    }
    guard let brain = app.backends.brain else { return }
    lastMenuRefresh = t
    let today = todayLabel
    do {
      let record = try await brain.dayRecord(day: today)
      cloudToday = record
    } catch {
      cloudToday = nil
    }
  }

  /// The model's own clock for the menu bar line, every minute for the app's life (the menu bar's `.menu` style does
  /// not re-run a view's `.task` when it opens) and at the calendar's day change. A new day is published at once, so a
  /// line for yesterday goes away; in `.cloud` the new day is read without waiting a minute (review 2, finding 1).
  public func menuTick() async {
    let today = todayLabel
    let rolled = today != lastTodaySeen
    lastTodaySeen = today
    if rolled {
      objectWillChange.send()
      if isLocal { rebuildLocal() }
    }
    await refreshMenuLine(force: rolled)
  }

  /// Starts `menuTick` now, every minute, and on `NSCalendarDayChanged`. The shared model lives as long as the app.
  func startMenuClock() {
    let model = self
    Task { @MainActor in
      while !Task.isCancelled {
        await model.menuTick()
        try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
      }
    }
    _ = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
      Task { @MainActor in await model.menuTick() }
    }
  }

  /// "today · 3 h 10 m · mostly Xcode"; nil when nothing was counted today. A cloud record of another day is never
  /// shown as today's.
  public var menuLine: String? {
    if isLocal { return TodayMenuSummary.line(snapshot: snapshot, day: todayLabel) }
    let today = todayLabel
    return cloudToday.flatMap { $0.day == today ? TodayMenuSummary.line(record: $0) : nil }
  }
}
