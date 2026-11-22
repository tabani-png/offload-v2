import Foundation
import Testing
@testable import OffloadMac

// ISO weeks and the review slot (SPEC m3-12 red tests WEEK and SLOT).
extension M312 {
  // MARK: WEEK

  @Test("WEEK: dates around New Year fall in 2026-W53 or 2027-W01; previous and next cross the year")
  func weekAroundNewYear() {
    let utc = M312Clock.utc
    #expect(ISOWeek(containing: M312Clock.date(2026, 12, 31, 12), timeZone: utc).id == "2026-W53")
    #expect(ISOWeek(containing: M312Clock.date(2027, 1, 1, 12), timeZone: utc).id == "2026-W53")
    #expect(ISOWeek(containing: M312Clock.date(2027, 1, 3, 23, 59), timeZone: utc).id == "2026-W53")
    #expect(ISOWeek(containing: M312Clock.date(2027, 1, 4, 0, 0), timeZone: utc).id == "2027-W01")
    let w53 = M312Clock.week("2026-W53")
    #expect(w53.next.id == "2027-W01")
    #expect(w53.next.previous == w53)
    #expect(M312Clock.week("2026-W01").previous.id == "2025-W52")
    #expect(M312Clock.week("2026-W47").next.id == "2026-W48")
    #expect(M312Clock.week("2026-W47").previous.id == "2026-W46")
    #expect(M312Clock.week("2026-W46") < M312Clock.week("2026-W47"))
    #expect(M312Clock.week("2026-W53") < M312Clock.week("2027-W01"))
  }

  @Test("WEEK: a week starts Monday 00:00 in the person's time zone, not UTC, and lasts 7 days")
  func weekMondayInTimeZone() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let w = ISOWeek("2026-W47", timeZone: tokyo)!
    #expect(w.from == M312Clock.date(2026, 11, 16, 0, 0, tz: tokyo))
    #expect(w.to == M312Clock.date(2026, 11, 23, 0, 0, tz: tokyo))
    // Mon 16 Nov 00:30 in Tokyo is still Sunday in UTC.
    let mondayTokyo = M312Clock.date(2026, 11, 16, 0, 30, tz: tokyo)
    #expect(ISOWeek(containing: mondayTokyo, timeZone: tokyo).id == "2026-W47")
    #expect(ISOWeek(containing: mondayTokyo, timeZone: M312Clock.utc).id == "2026-W46")
    #expect(w.contains(mondayTokyo))
    #expect(!w.contains(M312Clock.date(2026, 11, 15, 23, 59, tz: tokyo)))
    #expect(!w.contains(w.to))
    #expect(w.contains(w.from))
    #expect(w.dayLabels == ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22"])
  }

  @Test("WEEK: only real week ids parse; ids print as YYYY-Www")
  func weekParsing() {
    let utc = M312Clock.utc
    #expect(ISOWeek("2026-W47", timeZone: utc)?.id == "2026-W47")
    #expect(ISOWeek("2026-W05", timeZone: utc)?.week == 5)
    #expect(ISOWeek("2026-W05", timeZone: utc)?.year == 2026)
    #expect(ISOWeek("2026-W54", timeZone: utc) == nil)
    #expect(ISOWeek("2027-W53", timeZone: utc) == nil)  // 2027 has 52 weeks
    #expect(ISOWeek("2026-W00", timeZone: utc) == nil)
    #expect(ISOWeek("2026-47", timeZone: utc) == nil)
    #expect(ISOWeek("abc", timeZone: utc) == nil)
    #expect(ISOWeek("2026-W5", timeZone: utc) == nil)
    #expect(M312Clock.week("2026-W47").description == "2026-W47")
  }

  @Test("WEEK: a week over a daylight saving change still starts on Monday midnight and its next week too")
  func weekAcrossDaylightSaving() {
    let london = TimeZone(identifier: "Europe/London")!
    // Clocks go back on Sun 25 Oct 2026: 2026-W43 is 7 days and 1 hour long.
    let w = ISOWeek("2026-W43", timeZone: london)!
    #expect(w.from == M312Clock.date(2026, 10, 19, 0, 0, tz: london))
    #expect(w.to == M312Clock.date(2026, 10, 26, 0, 0, tz: london))
    #expect(w.to.timeIntervalSince(w.from) == 7 * 86_400 + 3600)
    #expect(w.next.from == w.to)
    #expect(w.next.id == "2026-W44")
  }

  // MARK: SLOT

  @Test("SLOT: the default slot is Friday 16:00 from the rhythm; an answered rhythm gives its own; the store overrides both")
  func slotDefaultsAndOverride() {
    let utc = M312Clock.utc
    let none = ReviewSlot.resolve(store: nil, rhythm: nil, timeZone: utc)
    #expect(none.day == .fri)
    #expect(none.time == "16:00")
    #expect(none.text == "Fri 4:00 PM")
    #expect(none.long == "Friday at 4:00 PM")
    let rhythm = Rhythm(reviewDay: .wed, reviewTime: "10:30", timezone: "UTC")
    let fromRhythm = ReviewSlot.resolve(store: nil, rhythm: rhythm, timeZone: utc)
    #expect(fromRhythm.day == .wed)
    #expect(fromRhythm.time == "10:30")
    let store = MemoryReviewSettingsStore()
    #expect(ReviewSlot.resolve(store: store, rhythm: rhythm, timeZone: utc).day == .wed)
    store.saveSlot(day: .mon, time: "08:15")
    let stored = ReviewSlot.resolve(store: store, rhythm: rhythm, timeZone: utc)
    #expect(stored.day == .mon)
    #expect(stored.time == "08:15")
    #expect(stored.text == "Mon 8:15 AM")
    #expect(stored.timeZone == utc)
  }

  @Test("SLOT: the next slot after Friday 15:59 is that day at 16:00; after 16:00 it is the next Friday")
  func slotNextAfter() {
    let slot = ReviewSlot(day: .fri, time: "16:00", timeZone: M312Clock.utc)
    #expect(ReviewSchedule.next(after: M312Clock.date(2026, 11, 20, 15, 59), slot: slot) == M312Clock.date(2026, 11, 20, 16, 0))
    #expect(ReviewSchedule.next(after: M312Clock.date(2026, 11, 20, 16, 0), slot: slot) == M312Clock.date(2026, 11, 27, 16, 0))
    #expect(ReviewSchedule.next(after: M312Clock.date(2026, 11, 16, 9, 0), slot: slot) == M312Clock.date(2026, 11, 20, 16, 0))
    let monday = ReviewSlot(day: .mon, time: "09:30", timeZone: M312Clock.utc)
    #expect(ReviewSchedule.next(after: M312Clock.date(2026, 11, 20, 16, 0), slot: monday) == M312Clock.date(2026, 11, 23, 9, 30))
  }

  @Test("SLOT: across a daylight saving change the slot stays at 16:00 local time")
  func slotAcrossDaylightSaving() {
    let london = TimeZone(identifier: "Europe/London")!
    let slot = ReviewSlot(day: .fri, time: "16:00", timeZone: london)
    let before = M312Clock.date(2026, 10, 23, 16, 0, tz: london)  // BST, 15:00 UTC
    let next = ReviewSchedule.next(after: before, slot: slot)
    #expect(next == M312Clock.date(2026, 10, 30, 16, 0, tz: london))  // GMT, 16:00 UTC
    #expect(next.timeIntervalSince(before) == 7 * 86_400 + 3600)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = london
    #expect(cal.component(.hour, from: next) == 16)
    #expect(ReviewSchedule.date(of: slot, in: ISOWeek("2026-W44", timeZone: london)!) == next)
  }

  @Test("SLOT: before the slot the shown week is last week; at and after the slot it is this week")
  func slotShownWeek() {
    let slot = ReviewSlot(day: .fri, time: "16:00", timeZone: M312Clock.utc)
    #expect(ReviewSchedule.shownWeek(now: M312Clock.date(2026, 11, 20, 15, 59), slot: slot).id == "2026-W46")
    #expect(ReviewSchedule.shownWeek(now: M312Clock.date(2026, 11, 20, 16, 0), slot: slot).id == "2026-W47")
    #expect(ReviewSchedule.shownWeek(now: M312Clock.date(2026, 11, 16, 9, 0), slot: slot).id == "2026-W46")
    #expect(ReviewSchedule.shownWeek(now: M312Clock.date(2026, 11, 22, 23, 0), slot: slot).id == "2026-W47")
    #expect(ReviewSchedule.currentWeek(now: M312Clock.date(2026, 11, 16, 9, 0), slot: slot).id == "2026-W47")
    let monday = ReviewSlot(day: .mon, time: "08:00", timeZone: M312Clock.utc)
    #expect(ReviewSchedule.shownWeek(now: M312Clock.date(2026, 11, 16, 9, 0), slot: monday).id == "2026-W47")
  }

  @Test("SLOT: the brain's review_slot words map to a slot and back")
  func slotBrainWords() {
    let s = ReviewSlot(brain: BrainReviewSlot(day: "thu", time: "10:00"), timeZone: M312Clock.utc)
    #expect(s?.day == .thu)
    #expect(s?.time == "10:00")
    #expect(s?.brain == BrainReviewSlot(day: "thu", time: "10:00"))
    #expect(ReviewSlot(brain: BrainReviewSlot(day: "someday", time: "10:00"), timeZone: M312Clock.utc) == nil)
    #expect(ReviewSlot(brain: BrainReviewSlot(day: "fri", time: "25:00"), timeZone: M312Clock.utc) == nil)
  }
}
