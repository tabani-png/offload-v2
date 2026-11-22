import Foundation
import Testing
@testable import OffloadMac

// The review notification, the Settings section and the copy (SPEC m3-12 red tests NOTIFY, SETTINGS, COPY). The
// notifier is FakeReviewNotifier everywhere: no test touches UNUserNotificationCenter.
extension M312 {
  @MainActor final class SlotBox {
    var slot: ReviewSlot
    init(_ slot: ReviewSlot) { self.slot = slot }
  }

  static let friday = ReviewSlot(day: .fri, time: "16:00", timeZone: M312Clock.utc)
  static let fridayTrigger = DateComponents(hour: 16, minute: 0, weekday: 6)
  static let reviewID = ReviewScheduler.notificationID

  @MainActor static func scheduler(_ notifier: FakeReviewNotifier, store: MemoryReviewSettingsStore = MemoryReviewSettingsStore(),
                                   box: SlotBox = SlotBox(M312.friday)) -> ReviewScheduler {
    ReviewScheduler(notifier: notifier, store: store, slot: { box.slot })
  }

  // MARK: NOTIFY

  @Test("NOTIFY: the toggle is off by default and nothing is asked or scheduled at launch")
  @MainActor func notifyOffByDefault() async {
    let notifier = FakeReviewNotifier()
    let store = MemoryReviewSettingsStore()
    let scheduler = Self.scheduler(notifier, store: store)
    await scheduler.start()
    #expect(!scheduler.isOn)
    #expect(!store.notify)
    #expect(notifier.askCount == 0)
    #expect(notifier.pending.isEmpty)
    #expect(scheduler.line == nil)
    #expect(ReviewScheduler.notificationID == "ai.offload.weekly-review")
  }

  @Test("NOTIFY: turning it on asks macOS once and keeps one repeating weekly trigger at the slot")
  @MainActor func notifyOnAsksOnce() async {
    let notifier = FakeReviewNotifier(status: .notDetermined, grants: true)
    let store = MemoryReviewSettingsStore()
    let scheduler = Self.scheduler(notifier, store: store)
    await scheduler.setOn(true)
    #expect(scheduler.isOn)
    #expect(store.notify)
    #expect(notifier.askCount == 1)
    #expect(notifier.pending == [Self.reviewID: Self.fridayTrigger])
    #expect(ReviewScheduler.trigger(for: Self.friday) == Self.fridayTrigger)
    await scheduler.setOn(false)
    await scheduler.setOn(true)
    #expect(notifier.askCount == 1)
    #expect(notifier.pending.count == 1)
  }

  @Test("NOTIFY: when macOS says no the toggle turns off with the line, and it is not asked again")
  @MainActor func notifyDenied() async {
    let notifier = FakeReviewNotifier(status: .notDetermined, grants: false)
    let store = MemoryReviewSettingsStore()
    let scheduler = Self.scheduler(notifier, store: store)
    await scheduler.setOn(true)
    #expect(!scheduler.isOn)
    #expect(!store.notify)
    #expect(scheduler.line == "Notifications are off for Offload in System Settings.")
    #expect(notifier.pending.isEmpty)
    #expect(notifier.askCount == 1)
    await scheduler.setOn(true)
    #expect(notifier.askCount == 1)
    #expect(!scheduler.isOn)
    #expect(scheduler.line == ReviewCopy.notificationsOff)
  }

  @Test("NOTIFY: a slot change reschedules, still one notification")
  @MainActor func notifySlotChange() async {
    let notifier = FakeReviewNotifier(status: .authorized)
    let box = SlotBox(Self.friday)
    let scheduler = Self.scheduler(notifier, box: box)
    await scheduler.setOn(true)
    #expect(notifier.askCount == 0)
    box.slot = ReviewSlot(day: .mon, time: "09:30", timeZone: M312Clock.utc)
    await scheduler.slotChanged()
    #expect(notifier.pending.count == 1)
    #expect(notifier.pending[Self.reviewID] == DateComponents(hour: 9, minute: 30, weekday: 2))
    #expect(notifier.scheduleCount == 2)
  }

  @Test("NOTIFY: turning it off removes the notification; a slot change while off schedules nothing")
  @MainActor func notifyOffRemoves() async {
    let notifier = FakeReviewNotifier(status: .authorized)
    let store = MemoryReviewSettingsStore()
    let box = SlotBox(Self.friday)
    let scheduler = Self.scheduler(notifier, store: store, box: box)
    await scheduler.setOn(true)
    await scheduler.setOn(false)
    #expect(!scheduler.isOn)
    #expect(!store.notify)
    #expect(notifier.pending.isEmpty)
    #expect(notifier.removed.contains(Self.reviewID))
    box.slot = ReviewSlot(day: .tue, time: "11:00", timeZone: M312Clock.utc)
    await scheduler.slotChanged()
    #expect(notifier.pending.isEmpty)
  }

  @Test("NOTIFY: at launch a setting left on is scheduled again, or turned off when macOS now says no")
  @MainActor func notifyAtLaunch() async {
    let store = MemoryReviewSettingsStore()
    store.notify = true
    let allowed = FakeReviewNotifier(status: .authorized)
    let on = Self.scheduler(allowed, store: store)
    await on.start()
    #expect(on.isOn)
    #expect(allowed.pending == [Self.reviewID: Self.fridayTrigger])
    #expect(allowed.askCount == 0)
    let refused = FakeReviewNotifier(status: .denied)
    let off = Self.scheduler(refused, store: store)
    await off.start()
    #expect(!off.isOn)
    #expect(!store.notify)
    #expect(off.line == ReviewCopy.notificationsOff)
    #expect(refused.askCount == 0)
  }

  @Test("NOTIFY: the notification says the review is ready, with no number and no name")
  func notifyTextHasNoNumber() {
    #expect(ReviewCopy.notificationBody == "Your weekly review is ready.")
    #expect(ReviewCopy.notificationTitle == "Offload")
    for s in [ReviewCopy.notificationTitle, ReviewCopy.notificationBody] {
      #expect(s.firstMatch(of: try! Regex("[0-9]")) == nil, "number: \(s)")
      #expect(!s.contains(m312PatternName))
    }
  }

  // MARK: SETTINGS

  @MainActor static func settings(_ backends: Backends = .local, store: MemoryReviewSettingsStore = MemoryReviewSettingsStore(),
                                  rhythm: Rhythm? = nil, notifier: FakeReviewNotifier = FakeReviewNotifier()) -> ReviewSettingsModel {
    ReviewSettingsModel(backends: backends, store: store, rhythm: { rhythm }, timeZone: M312Clock.utc, notifier: notifier)
  }

  @Test("SETTINGS: the section shows the slot in words and the toggle, off")
  @MainActor func settingsShowsSlotAndToggle() {
    let settings = Self.settings()
    #expect(settings.slotText == "Fri 4:00 PM")
    #expect(!settings.notifyOn)
    #expect(ReviewCopy.notifyToggle == "Tell me when my review is ready")
    #expect(ReviewCopy.slotTitle == "Review slot")
    let fromRhythm = Self.settings(rhythm: Rhythm(reviewDay: .wed, reviewTime: "10:30", timezone: "UTC"))
    #expect(fromRhythm.slotText == "Wed 10:30 AM")
  }

  @Test("SETTINGS: in .local an edited slot is saved on this Mac, reschedules and moves the shown week")
  @MainActor func settingsLocalSaves() async throws {
    let store = MemoryReviewSettingsStore()
    let notifier = FakeReviewNotifier(status: .authorized)
    let insights = await M312Kit.insights(M312Data.focusWeeks([(46, 60), (47, 60)]))
    let hub = WeeklyReviewHub(backends: .local, insights: insights, navigation: NavigationModel(), goals: { [] },
                              rhythm: { nil }, store: store, notifier: notifier, now: { M312Clock.now })
    await hub.startAndWait()
    await hub.review.refresh()
    #expect(hub.review.week.id == "2026-W47")
    await hub.settings.scheduler.setOn(true)
    await hub.settings.setSlot(day: .sat, time: "09:30")
    let stored = try #require(store.storedSlot())
    #expect(stored.day == .sat)
    #expect(stored.time == "09:30")
    #expect(hub.settings.slotText == "Sat 9:30 AM")
    #expect(notifier.pending == [Self.reviewID: DateComponents(hour: 9, minute: 30, weekday: 7)])
    // Fri 20 Nov 18:00 is before Saturday 9:30, so last week is shown again.
    #expect(hub.review.week.id == "2026-W46")
  }

  @Test("SETTINGS: in .cloud the slot comes from GET /v1/profile and an edit sends PATCH /v1/profile with only review_slot")
  @MainActor func settingsCloudPatch() async throws {
    let transport = RecordingTransport(replies: [.json(200, M312Fixtures.profile(day: "thu", time: "10:00")),
                                                 .json(200, M312Fixtures.profile(day: "fri", time: "17:00"))])
    let store = MemoryReviewSettingsStore()
    let settings = Self.settings(M312Kit.cloudBackends(transport), store: store)
    await settings.load()
    #expect(settings.slotText == "Thu 10:00 AM")
    #expect(transport.requests.first?.httpMethod == "GET")
    #expect(transport.requests.first?.url?.absoluteString == "https://api.example.test/v1/profile")
    await settings.setSlot(day: .fri, time: "17:00")
    let patch = try #require(transport.requests.last)
    #expect(transport.requests.count == 2)
    #expect(patch.httpMethod == "PATCH")
    #expect(patch.url?.absoluteString == "https://api.example.test/v1/profile")
    #expect(M312Kit.body(patch) == #"{"review_slot":{"day":"fri","time":"17:00"}}"#)
    #expect(settings.slotText == "Fri 5:00 PM")
    #expect(store.storedSlot() == nil)
    #expect(settings.error == nil)
  }

  @Test("SETTINGS: a failed PATCH keeps the old slot and says so; the UserDefaults store keeps slot and toggle")
  @MainActor func settingsFailureAndDefaults() async throws {
    let transport = RecordingTransport(replies: [.json(200, M312Fixtures.profile(day: "thu", time: "10:00")), .offline])
    let settings = Self.settings(M312Kit.cloudBackends(transport))
    await settings.load()
    await settings.setSlot(day: .mon, time: "08:00")
    #expect(settings.slotText == "Thu 10:00 AM")
    #expect(settings.error == ReviewCopy.slotSaveFailed)

    let suite = "m312.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let one = UserDefaultsReviewSettingsStore(defaults: defaults)
    #expect(one.storedSlot() == nil)
    #expect(!one.notify)
    one.saveSlot(day: .tue, time: "07:45")
    one.notify = true
    let two = UserDefaultsReviewSettingsStore(defaults: defaults)
    #expect(two.storedSlot()?.day == .tue)
    #expect(two.storedSlot()?.time == "07:45")
    #expect(two.notify)
    #expect(defaults.string(forKey: "ai.offload.review.day") == "tue")
    #expect(defaults.string(forKey: "ai.offload.review.time") == "07:45")
    #expect(defaults.bool(forKey: "ai.offload.review.notify"))
  }

  // MARK: COPY

  @Test("COPY: no em dash, banned word, ADR 0016 term, exclamation mark or internal term in any review string")
  func copyRules() {
    let banned = try! Regex("(?i)\\b(generous|unlock|seamless|powerful|at scale|robust|everything you need|built for teams that)\\b")
    let adr0016 = try! Regex("(?i)" + "dry" + "[ _-]?" + "run|" + "preview" + " run")
    let internalTerms = try! Regex("\\b(MCP|token|tokens|LLM|gate|OCR|TCC|ingest|tenant|pseudonym|opportunity|subject_key|k_)\\b")
    let all = ReviewCopy.all
    #expect(all.count > 40)
    for s in all {
      #expect(!s.contains("\u{2014}"), "em dash: \(s)")
      #expect(s.firstMatch(of: banned) == nil, "banned word: \(s)")
      #expect(s.firstMatch(of: adr0016) == nil, "ADR 0016 term: \(s)")
      #expect(s.firstMatch(of: internalTerms) == nil, "internal term: \(s)")
      #expect(!s.contains("!"), "exclamation mark: \(s)")
    }
  }

  @Test("COPY: captions are lowercase (Mac and Offload aside) and facts are separate items, never one dotted string")
  func copyCaptions() {
    for c in ReviewCopy.captions {
      let plain = c.replacingOccurrences(of: "Mac", with: "mac").replacingOccurrences(of: "Offload", with: "offload")
      #expect(plain == plain.lowercased(), "not lowercase: \(c)")
      #expect(!c.contains("\u{00B7}"), "dotted item: \(c)")
    }
    let items = ReviewCopy.counterItems(answered: 2, total: 4) + ReviewCopy.buildNoteItems + ReviewCopy.goalTrendItems(up: false, weeks: 3)
      + ReviewCopy.titleItems(M312Clock.week("2026-W46"))
    for item in items { #expect(!item.contains("\u{00B7}"), "dotted item: \(item)") }
    #expect(ReviewCopy.captions.contains("every number opens to how it was counted"))
    #expect(ReviewCopy.captions.contains("each answer tunes next week"))
  }

  @Test("COPY: the title is \"Week of Nov 9 · review\", drawn from separate items; lines use the true minus sign")
  func copyTitle() {
    let w46 = M312Clock.week("2026-W46")
    #expect(ReviewCopy.titleItems(w46) == ["Week of Nov 9", "review"])
    #expect(ReviewCopy.title(w46) == "Week of Nov 9 \u{00B7} review")
    #expect(ReviewCopy.weekOf(M312Clock.week("2026-W53")) == "Week of Dec 28")
    #expect(ReviewCopy.vsUsual(percent: -2) == "\u{2212}2% vs your usual")
    #expect(ReviewCopy.vsUsual(percent: 6) == "+6% vs your usual")
    #expect(ReviewCopy.vsUsual(percent: 0) == "same as your usual")
    #expect(ReviewCopy.running(up: false, weeks: 3) == "down 3 weeks running")
    #expect(ReviewCopy.goalTrendItems(up: true, weeks: 4) == ["\u{2191} 4 weeks"])
    #expect(ReviewCopy.goalTrendItems(up: false, weeks: 3) == ["\u{2193} 3 weeks", "drifting"])
    #expect(ReviewCopy.notYet(Self.friday) == "Your review for this week lands Friday at 4:00 PM.")
  }
}
