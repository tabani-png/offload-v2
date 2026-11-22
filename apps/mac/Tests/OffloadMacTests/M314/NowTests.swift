import Foundation
import Testing
@testable import OffloadMac
import OffloadContracts
import OffloadStore

// The local now line reads the observer's encrypted day store (SPEC: "Local now line"; W1-D audit gap 4).

/// An encrypted day store over a temp home and an in-memory Keychain, with UTC days.
final class M314DayStore: @unchecked Sendable {
  let home = M314Fixture.tempHome()
  let secrets = MemorySecretStore()
  let store: DayStore

  init() throws {
    let layout = StoreLayout(home: home)
    try layout.ensureDirectories()
    store = DayStore(layout: layout, keys: KeyRing(layout: layout, secrets: secrets),
                     days: DayCalendar(timeZone: M314Fixture.utc))
  }

  var source: StoreEventSource {
    let handle = StoreHandle()
    handle.set(store)
    return StoreEventSource(handle: handle)
  }

  func focus(_ at: Date, _ bundle: String, _ name: String, source: ObservationSource? = nil, importID: String? = nil) throws {
    try store.append(.focus(ObservationFocus(id: M314Fixture.id(at), ts: Timestamp.format(at), source: source,
                                             importId: importID, appBundleId: bundle, appName: name, title: "Window")))
  }
}

extension M314 {
  @Test("NOW: focus, idle, pause and content observations become local events with millisecond times")
  func mapping() {
    let at = M314Fixture.t0
    let ts = Timestamp.format(at)
    let ms = M314Fixture.ms(at)
    #expect(StoreEventSource.event(.focus(ObservationFocus(id: "f", ts: ts, appBundleId: "com.apple.Safari", appName: "Safari")))
            == LocalEvent(id: "f", ts: ms, kind: "focus", app: "com.apple.Safari", appName: "Safari"))
    #expect(StoreEventSource.event(.idleStart(ObservationIdleStart(id: "i", ts: ts)))
            == LocalEvent(id: "i", ts: ms, kind: "idle_start", app: nil, appName: nil))
    #expect(StoreEventSource.event(.idleEnd(ObservationIdleEnd(id: "e", ts: ts)))?.kind == "idle_end")
    #expect(StoreEventSource.event(.pause(ObservationPause(id: "p", ts: ts, reason: .user)))?.kind == "pause")
    #expect(StoreEventSource.event(.resume(ObservationResume(id: "r", ts: ts, reason: .user)))?.kind == "resume")
    #expect(StoreEventSource.event(.textSnapshot(ObservationTextSnapshot(
      id: "t", ts: ts, appBundleId: "com.apple.Notes", text: "x", textHash: String(repeating: "0", count: 64),
      textSource: .ax))) == LocalEvent(id: "t", ts: ms, kind: "text_snapshot", app: "com.apple.Notes", appName: nil))
    #expect(StoreEventSource.event(.inputCounts(ObservationInputCounts(id: "k", ts: ts, keys: 3, clicks: 1)))?.kind == "input")
    #expect(StoreEventSource.event(.permissionChange(ObservationPermissionChange(
      id: "c", ts: ts, perm: ObservationPerm(screenRecording: false, accessibility: true)))) == nil)
    // A time the contract cannot parse yields no event rather than a guessed one.
    #expect(StoreEventSource.event(.idleStart(ObservationIdleStart(id: "bad", ts: "yesterday"))) == nil)
  }

  @Test("NOW: the window holds events after from up to to, plus the last focus before from")
  func window() throws {
    let s = try M314DayStore()
    let t0 = M314Fixture.t0
    // The day before (UTC): the carried focus may come from there.
    try s.focus(t0.addingTimeInterval(-86_400 + 60), "com.apple.Mail", "Mail")
    try s.focus(t0.addingTimeInterval(-20 * 60), "com.apple.Safari", "Safari")
    try s.focus(t0.addingTimeInterval(-15 * 60), "com.apple.Notes", "Notes")
    try s.focus(t0.addingTimeInterval(-5 * 60), "com.tinyspeck.slackmacgap", "Slack")
    try s.store.append(.idleStart(ObservationIdleStart(id: M314Fixture.id(t0.addingTimeInterval(-2 * 60)),
                                                       ts: Timestamp.format(t0.addingTimeInterval(-2 * 60)))))
    try s.focus(t0.addingTimeInterval(60), "com.apple.Terminal", "Terminal")  // after `to`

    let from = M314Fixture.ms(t0.addingTimeInterval(-10 * 60))
    let to = M314Fixture.ms(t0)
    let events = s.source.events(from: from, to: to)
    #expect(events.map(\.kind) == ["focus", "focus", "idle_start"])
    #expect(events.map(\.appName) == ["Notes", "Slack", nil])
    #expect(events.first?.ts == M314Fixture.ms(t0.addingTimeInterval(-15 * 60)))

    // 00:01 to 00:02 UTC on t0's day: nothing in the window and no focus earlier that day, so the carried focus is
    // the previous day's last.
    let midnight = t0.addingTimeInterval(-15 * 3600)
    let early = s.source.events(from: M314Fixture.ms(midnight.addingTimeInterval(60)),
                                to: M314Fixture.ms(midnight.addingTimeInterval(120)))
    #expect(early.map(\.appName) == ["Mail"])
  }

  @Test("NOW: imported observations never reach the local now line")
  func importsAreNotLive() throws {
    let s = try M314DayStore()
    let t0 = M314Fixture.t0
    try s.focus(t0.addingTimeInterval(-3 * 60), "com.apple.Notes", "Notes")
    try s.focus(t0.addingTimeInterval(-2 * 60), "com.apple.Photos", "Photos", source: .import, importID: M314Fixture.importID)
    let events = s.source.events(from: M314Fixture.ms(t0.addingTimeInterval(-10 * 60)), to: M314Fixture.ms(t0))
    #expect(events.map(\.appName) == ["Notes"])
  }

  @Test("NOW: capture start is the earliest stored observation, and nothing is read before capture")
  func captureStart() throws {
    #expect(StoreEventSource(handle: StoreHandle()).captureStartedAt() == nil)
    #expect(StoreEventSource(handle: StoreHandle()).events(from: 0, to: Int64.max) == [])
    let s = try M314DayStore()
    #expect(s.source.captureStartedAt() == nil)
    let t0 = M314Fixture.t0
    try s.focus(t0.addingTimeInterval(-30 * 60), "com.apple.Safari", "Safari")
    try s.focus(t0.addingTimeInterval(-2 * 86_400), "com.apple.Mail", "Mail")
    #expect(s.source.captureStartedAt() == M314Fixture.ms(t0.addingTimeInterval(-2 * 86_400)))
  }

  @Test("NOW: the local now summary counts apps from the day store")
  func summaryFromTheStore() throws {
    let s = try M314DayStore()
    let t0 = M314Fixture.t0
    try s.focus(t0.addingTimeInterval(-40 * 60), "com.apple.Safari", "Safari")
    try s.focus(t0.addingTimeInterval(-6 * 60), "com.apple.Notes", "Notes")
    let source = s.source
    let to = M314Fixture.ms(t0)
    let summary = LocalNowSummary.compute(events: source.events(from: to - 10 * 60_000, to: to), now: to, minutes: 10,
                                          captureStartedAt: source.captureStartedAt())
    #expect(summary.minutes == 10)
    #expect(summary.top.map(\.appName) == ["Notes", "Safari"])
    #expect(summary.top.map(\.minutes) == [6, 4])
    #expect(summary.switches == 1)
  }
}
