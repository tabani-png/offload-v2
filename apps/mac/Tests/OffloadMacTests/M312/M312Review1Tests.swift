import Foundation
import Testing
@testable import OffloadMac

// Review 1 (slices/m3-12-mac-weekly-review/SPEC.md "Review 1"): the notification offered on the review screen, the
// notification opening this week's review, loading while local insights are counted, the cloud's 404 for a past
// week, a slot read from the profile moving the notification, and the hub at launch.

/// A clock the test moves.
final class M312MovingClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(_ date: Date) { current = date }

  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func set(_ date: Date) {
    lock.lock()
    current = date
    lock.unlock()
  }
}

/// Counts calls from the main actor.
@MainActor final class M312Counter {
  var count = 0
}

extension M312 {
  @MainActor static func hub(_ insights: InsightsModel, clock: M312MovingClock, navigation: NavigationModel = NavigationModel(),
                             backends: Backends = .local, store: MemoryReviewSettingsStore = MemoryReviewSettingsStore(),
                             notifier: FakeReviewNotifier = FakeReviewNotifier()) -> WeeklyReviewHub {
    WeeklyReviewHub(backends: backends, insights: insights, navigation: navigation, goals: { [] }, rhythm: { nil },
                    store: store, notifier: notifier, now: { clock.now })
  }

  // MARK: The offer on the review screen (finding 1)

  @Test("NOTIFY: the review screen offers the notification while it is off; accepting asks macOS once and schedules it")
  @MainActor func notifyOfferAccepted() async {
    let notifier = FakeReviewNotifier(status: .notDetermined, grants: true)
    let store = MemoryReviewSettingsStore()
    let settings = Self.settings(store: store, notifier: notifier)
    #expect(settings.showsNotificationOffer)
    #expect(ReviewCopy.offerLine == "Get one notification a week, at your review slot, when your review is ready.")
    #expect(ReviewCopy.offerDismiss == "No thanks")
    await settings.acceptNotificationOffer()
    #expect(notifier.askCount == 1)
    #expect(notifier.pending == [Self.reviewID: Self.fridayTrigger])
    #expect(settings.notifyOn)
    #expect(store.offerDone)
    #expect(!settings.showsNotificationOffer)
  }

  @Test("NOTIFY: No thanks hides the offer for good without asking; a refusal hides it and shows the line")
  @MainActor func notifyOfferDeclined() async {
    let notifier = FakeReviewNotifier(status: .notDetermined, grants: true)
    let store = MemoryReviewSettingsStore()
    let settings = Self.settings(store: store, notifier: notifier)
    settings.dismissNotificationOffer()
    #expect(!settings.showsNotificationOffer)
    #expect(store.offerDone)
    #expect(notifier.askCount == 0)
    #expect(!Self.settings(store: store, notifier: notifier).showsNotificationOffer)

    let refusing = FakeReviewNotifier(status: .notDetermined, grants: false)
    let other = Self.settings(store: MemoryReviewSettingsStore(), notifier: refusing)
    await other.acceptNotificationOffer()
    #expect(!other.showsNotificationOffer)
    #expect(other.scheduler.line == ReviewCopy.notificationsOff)
    #expect(!other.notifyOn)
  }

  @Test("NOTIFY: no offer while the notification is already on; the offered flag is kept in UserDefaults")
  @MainActor func notifyOfferNotWhenOn() throws {
    let on = Self.settings(store: MemoryReviewSettingsStore(notify: true), notifier: FakeReviewNotifier(status: .authorized))
    #expect(!on.showsNotificationOffer)
    let suite = "m312r1.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let one = UserDefaultsReviewSettingsStore(defaults: defaults)
    #expect(!one.offerDone)
    one.offerDone = true
    #expect(UserDefaultsReviewSettingsStore(defaults: defaults).offerDone)
    #expect(defaults.bool(forKey: "ai.offload.review.offered"))
  }

  @Test("NOTIFY: at launch the hub keeps a notification that is on, without asking")
  @MainActor func notifyHubStartKeepsIt() async {
    let notifier = FakeReviewNotifier(status: .authorized)
    let insights = await M312Kit.insights([])
    let hub = Self.hub(insights, clock: M312MovingClock(M312Clock.now), store: MemoryReviewSettingsStore(notify: true),
                       notifier: notifier)
    await hub.startAndWait()
    #expect(hub.settings.notifyOn)
    #expect(notifier.pending == [Self.reviewID: Self.fridayTrigger])
    #expect(notifier.askCount == 0)
  }

  // MARK: Opening the notification (finding 2)

  @Test("STATES: opening the notification after the slot shows this week's review, even from another week or screen")
  @MainActor func statesOpenFromNotification() async {
    let clock = M312MovingClock(M312Clock.date(2026, 11, 20, 15))
    let insights = await M312Kit.insights(M312Data.focusWeeks([(45, 60), (46, 60), (47, 60)]))
    let navigation = NavigationModel()
    let hub = Self.hub(insights, clock: clock, navigation: navigation)
    await hub.startAndWait()
    await hub.review.refresh()
    #expect(hub.review.week.id == "2026-W46")
    await hub.review.previousWeek()
    #expect(hub.review.week.id == "2026-W45")
    clock.set(M312Clock.date(2026, 11, 20, 16, 5))
    navigation.selection = .today
    await hub.openFromNotification()
    #expect(navigation.selection == .weeklyReview)
    #expect(hub.review.week.id == "2026-W47")
    #expect(hub.review.state == .ready)
  }

  @Test("STATES: a screen left open moves to this week when the slot passes")
  @MainActor func statesSlotPasses() async {
    let clock = M312MovingClock(M312Clock.date(2026, 11, 20, 15))
    let insights = await M312Kit.insights(M312Data.focusWeeks([(46, 60), (47, 60)]))
    let hub = Self.hub(insights, clock: clock)
    await hub.review.refresh()
    #expect(hub.review.week.id == "2026-W46")
    #expect(hub.review.nextSlot == M312Clock.date(2026, 11, 20, 16))
    clock.set(M312Clock.date(2026, 11, 20, 16, 0, 1))
    await hub.review.slotPassed()
    #expect(hub.review.week.id == "2026-W47")
    #expect(hub.review.nextSlot == M312Clock.date(2026, 11, 27, 16))
  }

  // MARK: Counting in progress (finding 4)

  @Test("STATES: while local insights are being counted an empty week reads loading, then the counted review")
  @MainActor func statesLoadingWhileCounting() async {
    let insightsStore = InsightsStore(sources: InsightsStore.Sources(reader: M312Reader(M312Data.tilesWeek),
                                                                     timeZone: M312Clock.utc, now: { M312Clock.now }))
    let insights = InsightsModel(store: insightsStore)
    let (stream, gate) = AsyncStream<Void>.makeStream()
    let counting = insights.schedule { store in
      for await _ in stream { break }
      return await store.refreshAll()
    }
    let model = M312Kit.model(insights: insights)
    #expect(insights.isAnalysing)
    await model.refresh()
    #expect(model.state == .loading)
    gate.yield(())
    await counting.value
    #expect(model.state == .ready)
    #expect(model.content?.tiles.first?.valueText == "2.7 h")
  }

  // MARK: The cloud's 404 for a past week (finding 5)

  @Test("CLOUD: a 404 for a past week says there is no review for it; only a week before its slot reads not yet")
  @MainActor func cloudNoReviewForPastWeek() async {
    let (model, transport) = Self.cloudModel([.json(200, M312Fixtures.review), .json(404, M312Fixtures.notFound)])
    await model.refresh()
    await model.previousWeek()
    #expect(model.week.id == "2026-W46")
    #expect(model.state == .noReview(M312Clock.week("2026-W46")))
    #expect(model.stateLine == "There is no review for this week.")
    #expect(model.notYetLine == nil)
    #expect(transport.requests.count == 2)

    let wednesday = M312Clock.date(2026, 11, 18, 12)
    let (early, sent) = Self.cloudModel([.json(200, M312Fixtures.review)], now: wednesday)
    await early.refresh()
    await early.nextWeek()
    #expect(early.state == .notYet(M312Clock.week("2026-W47")))
    #expect(early.stateLine == "Your review for this week lands Friday at 4:00 PM.")
    #expect(sent.requests.count == 1)
  }

  @Test("CLOUD: .cloud without a brain client reads signed out and sends nothing")
  @MainActor func cloudWithoutClient() async {
    let config = BackendConfig(baseURL: URL(string: "https://api.example.test")!, tokens: M312Token())
    let backends = Backends(mode: .cloud(config), brain: nil, builds: nil, provenance: .cloud)
    let model = M312Kit.model(backends: backends, insights: InsightsModel.empty(timeZone: M312Clock.utc))
    await model.refresh()
    #expect(model.state == .failed(.signedOut))
    #expect(model.content == nil)
  }

  // MARK: A slot read from the profile (finding 6)

  @Test("SETTINGS: a slot read from the profile moves the notification and tells the screen")
  @MainActor func settingsLoadedSlotMoves() async {
    let transport = RecordingTransport(replies: [.json(200, M312Fixtures.profile(day: "thu", time: "10:00"))])
    let notifier = FakeReviewNotifier(status: .authorized)
    let settings = Self.settings(M312Kit.cloudBackends(transport), notifier: notifier)
    let told = M312Counter()
    settings.onSlotChange = { told.count += 1 }
    await settings.scheduler.setOn(true)
    #expect(notifier.pending == [Self.reviewID: Self.fridayTrigger])
    await settings.load()
    #expect(notifier.pending == [Self.reviewID: DateComponents(hour: 10, minute: 0, weekday: 5)])
    #expect(told.count == 1)
  }
}
