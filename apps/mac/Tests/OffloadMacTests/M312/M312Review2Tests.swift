import Foundation
import Testing
@testable import OffloadMac

// Review 2 (slices/m3-12-mac-weekly-review/SPEC.md "Review 2"): the notification's click asks for the main window,
// a passing slot loads nothing nobody asked for, and waking the Mac after the slot moves the screen.
extension M312 {
  @Test("NOTIFY: clicking the notification asks for the main window, once per click")
  @MainActor func notifyClickOpensWindow() async {
    let insights = await M312Kit.insights(M312Data.focusWeeks([(47, 60)]))
    let hub = Self.hub(insights, clock: M312MovingClock(M312Clock.now))
    #expect(hub.windowRequests == 0)
    await hub.openFromNotification()
    #expect(hub.windowRequests == 1)
    await hub.openFromNotification()
    #expect(hub.windowRequests == 2)
    #expect(WeeklyReviewWindow.mainWindowID == "main")
  }

  @Test("STATES: the slot passing moves the week but loads nothing while the screen was never opened")
  @MainActor func statesSlotPassesQuietly() async {
    let clock = M312MovingClock(M312Clock.date(2026, 11, 20, 15))
    let transport = RecordingTransport(replies: [.json(200, M312Fixtures.review)])
    let hub = Self.hub(InsightsModel.empty(timeZone: M312Clock.utc), clock: clock,
                       backends: M312Kit.cloudBackends(transport))
    #expect(hub.review.week.id == "2026-W46")
    clock.set(M312Clock.date(2026, 11, 20, 16, 5))
    await hub.review.slotPassed()
    #expect(hub.review.week.id == "2026-W47")
    #expect(transport.requests.isEmpty)
    await hub.review.refresh()
    #expect(transport.requests.count == 1)
  }

  @Test("STATES: waking the Mac after the slot moves an open screen to this week")
  @MainActor func statesWakeAfterSlot() async {
    let clock = M312MovingClock(M312Clock.date(2026, 11, 20, 15))
    let insights = await M312Kit.insights(M312Data.focusWeeks([(46, 60), (47, 60)]))
    let hub = Self.hub(insights, clock: clock)
    await hub.review.refresh()
    #expect(hub.review.week.id == "2026-W46")
    await hub.review.didWake()
    #expect(hub.review.week.id == "2026-W46")
    clock.set(M312Clock.date(2026, 11, 21, 8))
    await hub.review.didWake()
    #expect(hub.review.week.id == "2026-W47")
    #expect(hub.review.state == .ready)
  }
}
