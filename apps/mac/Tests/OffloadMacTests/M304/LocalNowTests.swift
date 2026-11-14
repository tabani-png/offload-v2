import Foundation
import Testing
@testable import OffloadMac

// The local now summary (ONBOARDING section 5): ported from the old brain's GET /now (brain/src/time/now.ts and
// brain/tests/s34-recordings/now.test.ts, PR #44), rewritten in Swift to run on the Mac with no model and no upload.

enum NowFixture {
  static let m = M304Clock.minute
  static let now = M304Clock.nowMs

  /// 10 minutes ending at now: Cursor 6 min, Chrome 3 min, Slack 1 min, 4 app switches inside the window.
  static func tenMinutes() -> [LocalEvent] {
    var n = 0
    func e(_ minAgo: Int64, _ app: String, _ name: String) -> LocalEvent {
      n += 1
      return LocalEvent(id: "n" + String(format: "%03d", n), ts: now - minAgo * m, kind: "focus", app: app, appName: name)
    }
    return [
      e(30, "com.apple.mail", "Mail"),  // before the window: only carries focus in
      e(10, "com.todesktop.230313mzl4w4u92", "Cursor"),
      e(8, "com.google.Chrome", "Google Chrome"),
      e(5, "com.todesktop.230313mzl4w4u92", "Cursor"),
      e(2, "com.tinyspeck.slackmacgap", "Slack"),
      e(1, "com.todesktop.230313mzl4w4u92", "Cursor"),
    ]
  }

  /// The old s34 day-file line shape (`2026-11-13.jsonl`), scrubbed: ids, ms timestamps, kinds, apps. Extra keys
  /// (text, textHash) are ignored by the reader.
  static let dayFile = """
  {"id":"01KA0000000000000000000001","ts":1794578400000,"kind":"idle_end"}
  {"id":"01KA0000000000000000000002","ts":1794578400000,"kind":"focus","app":"com.apple.Safari","appName":"Safari"}
  {"id":"01KA0000000000000000000003","ts":1794578400000,"kind":"ocr","app":"com.apple.Safari","appName":"Safari","text":"[masked]","textHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  {"id":"01KA0000000000000000000004","ts":1794578420000,"kind":"focus","app":"com.apple.iWork.Numbers","appName":"Numbers"}
  {"id":"01KA0000000000000000000005","ts":1794578420000,"kind":"ocr","app":"com.apple.iWork.Numbers","appName":"Numbers","text":"[masked]","textHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
  {"id":"01KA0000000000000000000006","ts":1794578440000,"kind":"focus","app":"com.apple.Safari","appName":"Safari"}
  {"id":"01KA0000000000000000000007","ts":1794578440000,"kind":"ocr","app":"com.apple.Safari","appName":"Safari","text":"[masked]","textHash":"cccccccccccccccccccccccccccccccc"}
  {"id":"01KA0000000000000000000008","ts":1794578580000,"kind":"idle_start"}
  """
}

extension M304 {
  @Test("NOW: NOW-1 top 3 apps by active minutes in the window, with their event ids")
  func now1TopThree() {
    let s = LocalNowSummary.compute(events: NowFixture.tenMinutes(), now: NowFixture.now, minutes: 10)
    #expect(s.top.map(\.appName) == ["Cursor", "Google Chrome", "Slack"])
    #expect(s.top.map(\.minutes) == [6, 3, 1])
    #expect(s.top.first?.eventIds == ["n002", "n004", "n006"])
    #expect(s.activeMinutes == 10)
  }

  @Test("NOW: NOW-2 switches count app changes inside the window only")
  func now2Switches() {
    let s = LocalNowSummary.compute(events: NowFixture.tenMinutes(), now: NowFixture.now, minutes: 10)
    #expect(s.switches == 4)
    #expect(abs(s.switchesPerMinute - 0.4) < 1e-9)
  }

  @Test("NOW: NOW-3 one honest line and a short lowercase remark, both from the numbers")
  func now3LineAndRemark() {
    let s = LocalNowSummary.compute(events: NowFixture.tenMinutes(), now: NowFixture.now, minutes: 10)
    #expect(s.line == "10 min · Cursor 6m · Google Chrome 3m · Slack 1m · 4 switches")
    #expect(s.remark == "that's you, mostly in cursor.")
    #expect(s.remark == s.remark.lowercased())
    #expect(M304Repo.words(s.remark) <= 6)
    #expect(s.headline == "Here's your last 10 minutes.")
    #expect(s.computedBy == "code")
  }

  @Test("NOW: NOW-4 idle time is not active time")
  func now4Idle() {
    let m = NowFixture.m, now = NowFixture.now
    // Cursor from 5 to 4 min ago, idle 4 to 2 min ago (idle_start is written 120 s after the last input).
    var ev = NowFixture.tenMinutes()
    ev.append(LocalEvent(id: "i1", ts: now - 4 * m + 120_000, kind: "idle_start", app: nil, appName: nil))
    ev.append(LocalEvent(id: "i2", ts: now - 2 * m, kind: "idle_end", app: nil, appName: nil))
    let s = LocalNowSummary.compute(events: ev, now: now, minutes: 10)
    #expect(s.activeMinutes == 8)
    #expect(s.top.first?.appName == "Cursor")
  }

  @Test("NOW: NOW-5 nothing seen yet says so and points nowhere (anEmptyWindowShowsNothingYet)")
  func now5NothingYet() {
    let s = LocalNowSummary.compute(events: [], now: NowFixture.now, minutes: 10)
    #expect(s.top.isEmpty)
    #expect(s.line == "Nothing seen yet. Keep working for a minute.")
    #expect(s.remark == "")
    var screen = LastTenMinutesState(openedAt: M304Clock.now)
    let flies = screen.received(s)
    #expect(!flies)
    #expect(!screen.pointerFlown)
    #expect(!screen.showsAccessLaterLine(now: M304Clock.now.addingTimeInterval(119)))
    #expect(screen.showsAccessLaterLine(now: M304Clock.now.addingTimeInterval(120)))
  }

  @Test("NOW: NOW-6 zero model calls and zero uploads")
  @MainActor func now6NoModelNoUpload() async {
    // The summary's sources hold no networking or model API.
    let banned = try! Regex("URLSession|import Network|NSURLConnection|CFNetwork|NWConnection|URLRequest|socket\\(|anthropic|Anthropic")
    let sources = M304Repo.swiftSources("Sources/OffloadMac/LocalNow")
    #expect(!sources.isEmpty)
    for f in sources {
      #expect(f.text.firstMatch(of: banned) == nil, "networking or model API in \(f.path)")
    }
    // Reaching and leaving screen 3 starts no uploader.
    let fakes = M304Services()
    let model = fakes.model()
    for a in M304Path.toWhatLeaves.prefix(5) { await model.perform(a) }
    #expect(model.flow.screen == .signIn)
    #expect(fakes.uploader.starts == 0)
    #expect(LocalNowSummary.compute(events: NowFixture.tenMinutes(), now: NowFixture.now, minutes: 10).computedBy == "code")
  }

  @Test("NOW: the headline names the real span when capture ran under 10 minutes")
  func nowShortSpan() {
    let m = NowFixture.m, now = NowFixture.now
    let ev = [LocalEvent(id: "a", ts: now - 3 * m, kind: "focus", app: "com.apple.Notes", appName: "Notes")]
    let s = LocalNowSummary.compute(events: ev, now: now, minutes: 10, captureStartedAt: now - 3 * m)
    #expect(s.minutes == 3)
    #expect(s.headline == "Here's your last 3 minutes.")
    #expect(s.line == "3 min · Notes 3m · 0 switches")
    let one = LocalNowSummary.compute(events: ev, now: now, minutes: 10, captureStartedAt: now - 90_000)
    #expect(one.headline == "Here's your last minute.")
  }

  @Test("NOW: the pointer flies once, on the first line with a full minute, and refreshes every 5 s")
  func nowPointerOnce() {
    let m = NowFixture.m, now = NowFixture.now
    var screen = LastTenMinutesState(openedAt: M304Clock.now)
    let short = LocalNowSummary.compute(
      events: [LocalEvent(id: "a", ts: now - 30_000, kind: "focus", app: "com.apple.Notes", appName: "Notes")],
      now: now, minutes: 10)
    let flewShort = screen.received(short)
    #expect(!flewShort)  // under a full minute: the line shows, the pointer waits
    let full = LocalNowSummary.compute(events: NowFixture.tenMinutes(), now: now, minutes: 10)
    let flew = screen.received(full)
    #expect(flew)
    let again = screen.received(full)
    #expect(!again)
    #expect(screen.summary == full)
    #expect(LastTenMinutesState.refreshEvery == 5)
    #expect(screen.shouldRefresh(lastRefresh: nil, now: M304Clock.now))
    #expect(!screen.shouldRefresh(lastRefresh: M304Clock.now, now: M304Clock.now.addingTimeInterval(4.9)))
    #expect(screen.shouldRefresh(lastRefresh: M304Clock.now, now: M304Clock.now.addingTimeInterval(5)))
    _ = m
  }

  @Test("NOW: the old s34 day file decodes and gives an honest summary")
  func nowDayFile() throws {
    let events = try LocalEvent.decodeLines(NowFixture.dayFile)
    #expect(events.count == 8)
    // 1794578400000 is 14:00 UTC; Safari 20 s, Numbers 20 s, Safari until idle (detected at 14:03, input stopped 14:01).
    let s = LocalNowSummary.compute(events: events, now: 1_794_578_400_000 + 10 * NowFixture.m, minutes: 10)
    #expect(s.top.map(\.appName) == ["Safari", "Numbers"])
    #expect(s.switches == 2)
    #expect(s.activeMinutes == 1)
  }
}
