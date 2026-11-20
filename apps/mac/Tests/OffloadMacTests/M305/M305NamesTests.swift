import Foundation
import Testing
@testable import OffloadImport

// Recording and screenshot names (PR #44 S34RecordingNameTests, s34 timestamps.test.ts NAMES), the sample plan and
// the stable file gate (PR #44 S34RecordingFileTests).
extension M305 {
  static let utc = M305Clock.utc

  // MARK: NAMES (S34RecordingNameTests)

  @Test("NAMES: macOSDefaultNameWithNarrowNoBreakSpace, macOS 13 and later write U+202F before AM/PM")
  func macOSDefaultNameWithNarrowNoBreakSpace() {
    #expect(RecordingName.date(fromName: "Screen Recording 2026-11-13 at 9.41.07\u{202F}AM.mov", timeZone: M305.utc)
            == M305Clock.date(2026, 11, 13, 9, 41, 7))
  }

  @Test("NAMES: macOSDefaultNamePlainSpaceAndPM, including 12 AM and 12 PM")
  func macOSDefaultNamePlainSpaceAndPM() {
    #expect(RecordingName.date(fromName: "Screen Recording 2026-11-13 at 9.41.07 PM.mov", timeZone: M305.utc)
            == M305Clock.date(2026, 11, 13, 21, 41, 7))
    #expect(RecordingName.date(fromName: "Screen Recording 2026-11-13 at 12.05.00 AM.mov", timeZone: M305.utc)
            == M305Clock.date(2026, 11, 13, 0, 5, 0))
    #expect(RecordingName.date(fromName: "Screen Recording 2026-11-13 at 12.05.00 PM.mov", timeZone: M305.utc)
            == M305Clock.date(2026, 11, 13, 12, 5, 0))
  }

  @Test("NAMES: twentyFourHourLocaleAndDuplicateSuffix, 24-hour names and (2) copies")
  func twentyFourHourLocaleAndDuplicateSuffix() {
    #expect(RecordingName.date(fromName: "Screen Recording 2026-11-13 at 21.41.07.mov", timeZone: M305.utc)
            == M305Clock.date(2026, 11, 13, 21, 41, 7))
    #expect(RecordingName.date(fromName: "Screen Recording 2026-11-13 at 9.41.07 AM (2).mov", timeZone: M305.utc)
            == M305Clock.date(2026, 11, 13, 9, 41, 7))
  }

  @Test("NAMES: cleanShotAndQuickTimeExports, CleanShot with and without @2x and QuickTime's ISO-style names")
  func cleanShotAndQuickTimeExports() {
    #expect(RecordingName.date(fromName: "CleanShot 2026-11-13 at 09.41.07.mp4", timeZone: M305.utc) == M305Clock.date(2026, 11, 13, 9, 41, 7))
    #expect(RecordingName.date(fromName: "CleanShot 2026-11-13 at 09.41.07@2x.mp4", timeZone: M305.utc) == M305Clock.date(2026, 11, 13, 9, 41, 7))
    #expect(RecordingName.date(fromName: "Recording 2026-11-13 09.41.07.mov", timeZone: M305.utc) == M305Clock.date(2026, 11, 13, 9, 41, 7))
  }

  @Test("NAMES: otherNamesHaveNoDate, and an impossible date is nil, never rolled over")
  func otherNamesHaveNoDate() {
    #expect(RecordingName.date(fromName: "demo.mov", timeZone: M305.utc) == nil)
    #expect(RecordingName.date(fromName: "Screen Recording 2026-13-40 at 9.41.07 AM.mov", timeZone: M305.utc) == nil)
    #expect(RecordingName.date(fromName: "Screen Recording 2026-02-31 at 9.41.07 AM.mov", timeZone: M305.utc) == nil)
    #expect(RecordingName.date(fromName: "Screenshot 2026-10-20 at 25.15.32.png", timeZone: M305.utc) == nil)
  }

  @Test("NAMES: candidatesAreVideosOnly (videosOnly): mov, mp4 and m4v; hidden, partial and other files are not")
  func candidatesAreVideosOnly() {
    #expect(RecordingName.isVideo("Screen Recording 2026-11-13 at 9.41.07\u{202F}AM.mov"))
    #expect(RecordingName.isVideo("clip.MP4"))
    #expect(RecordingName.isVideo("clip.m4v"))
    #expect(!RecordingName.isVideo(".Screen Recording 2026-11-13 at 9.41.07 AM.mov"))
    #expect(!RecordingName.isVideo("clip.mov.download"))
    #expect(!RecordingName.isVideo("notes.txt"))
    #expect(!RecordingName.isVideo("Screenshot 2026-11-13 at 9.41.07 AM.png"))
    #expect(RecordingName.isImage("Screenshot 2026-11-13 at 9.41.07 AM.png"))
    #expect(RecordingName.isImage("shot.HEIC"))
    #expect(!RecordingName.isImage(".hidden.png"))
  }

  @Test("NAMES: macOS Screenshot DATE at H.MM.SS with AM/PM (plain and narrow no-break space), 24 h and Screen Shot")
  func screenshotNames() {
    #expect(RecordingName.date(fromName: "Screenshot 2026-10-20 at 10.15.32 AM.png", timeZone: M305.utc) == M305Clock.date(2026, 10, 20, 10, 15, 32))
    #expect(RecordingName.date(fromName: "Screenshot 2026-10-20 at 10.15.32\u{202F}PM.png", timeZone: M305.utc) == M305Clock.date(2026, 10, 20, 22, 15, 32))
    #expect(RecordingName.date(fromName: "Screenshot 2026-10-20 at 12.01.02 AM.png", timeZone: M305.utc) == M305Clock.date(2026, 10, 20, 0, 1, 2))
    #expect(RecordingName.date(fromName: "Screenshot 2026-10-20 at 16.05.09.png", timeZone: M305.utc) == M305Clock.date(2026, 10, 20, 16, 5, 9))
    #expect(RecordingName.date(fromName: "Screen Shot 2026-10-20 at 9.05.09 AM (2).png", timeZone: M305.utc) == M305Clock.date(2026, 10, 20, 9, 5, 9))
  }

  @Test("NAMES: ISO-ish, compact and unix seconds or milliseconds in a name give the time")
  func isoCompactUnixNames() {
    #expect(RecordingName.date(fromName: "2026-10-20T10-15-32.webp", timeZone: M305.utc) == M305Clock.date(2026, 10, 20, 10, 15, 32))
    #expect(RecordingName.date(fromName: "capture_2026-10-20 10:15:32.png", timeZone: M305.utc) == M305Clock.date(2026, 10, 20, 10, 15, 32))
    #expect(RecordingName.date(fromName: "IMG_20261020_101532.jpg", timeZone: M305.utc) == M305Clock.date(2026, 10, 20, 10, 15, 32))
    let sec = Int(M305Clock.date(2026, 10, 20, 10, 15, 32).timeIntervalSince1970)
    #expect(RecordingName.date(fromName: "\(sec).png", timeZone: M305.utc) == Date(timeIntervalSince1970: TimeInterval(sec)))
    #expect(RecordingName.date(fromName: "shot-\(sec * 1000 + 250).png", timeZone: M305.utc)
            == Date(timeIntervalSince1970: TimeInterval(sec) + 0.25))
  }

  @Test("NAMES: no timestamp, or an impossible one, is nil (the modified time is used instead)")
  func impossibleNamesAreNil() {
    #expect(RecordingName.date(fromName: "holiday.png", timeZone: M305.utc) == nil)
    #expect(RecordingName.date(fromName: "Screenshot 2026-13-40 at 10.15.32.png", timeZone: M305.utc) == nil)
    #expect(RecordingName.date(fromName: "123.png", timeZone: M305.utc) == nil)
    #expect(RecordingName.date(fromName: "9999999999999.png", timeZone: M305.utc) == nil)
  }

  @Test("NAMES: a name's time is on the Mac's local clock")
  func localClock() {
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    #expect(RecordingName.date(fromName: "Screen Recording 2026-11-13 at 9.41.07 AM.mov", timeZone: berlin)
            == M305Clock.date(2026, 11, 13, 8, 41, 7))
  }

  // MARK: Sample plan (S34SamplePlanTests)

  @Test("NAMES: the sample plan takes a frame every 5 s up to the end")
  func everyIntervalUpToTheEnd() {
    #expect(SamplePlan.times(duration: 20, interval: 5, maxFrames: 100) == [0, 5, 10, 15])
    #expect(SamplePlan.interval == 5)
    #expect(SamplePlan.maxFrames == 720)
  }

  @Test("NAMES: a short clip still gives its first frame; an empty one gives none")
  func shortClipStillGivesOneFrame() {
    #expect(SamplePlan.times(duration: 0.4, interval: 5, maxFrames: 100) == [0])
    #expect(SamplePlan.times(duration: 0, interval: 5, maxFrames: 100).isEmpty)
  }

  @Test("NAMES: a long clip is capped at 720 frames, spread evenly")
  func longClipIsCappedAndEvenlySpread() {
    let threeHours: TimeInterval = 3 * 3600
    let t = SamplePlan.times(duration: threeHours, interval: 5, maxFrames: 720)
    #expect(t.count == 720)
    #expect(t.first == 0)
    #expect((t.last ?? threeHours) < threeHours)
    #expect(abs((t[1] - t[0]) - 15) < 0.001)
  }

  // MARK: GATE

  @Test("GATE: aFileIsReadyOnlyWhenItStoppedGrowing, size unchanged for 3 s; an empty file never")
  func aFileIsReadyOnlyWhenItStoppedGrowing() {
    var gate = StableFileGate(settle: 3)
    let t0 = Date(timeIntervalSince1970: 0)
    let ready1 = gate.observe(path: "/a.mov", size: 10, at: t0)
    #expect(!ready1)
    let ready2 = gate.observe(path: "/a.mov", size: 20, at: t0.addingTimeInterval(4))    // still growing
    #expect(!ready2)
    let ready3 = gate.observe(path: "/a.mov", size: 20, at: t0.addingTimeInterval(5))    // same size, too soon
    #expect(!ready3)
    let ready4 = gate.observe(path: "/a.mov", size: 20, at: t0.addingTimeInterval(7.5))
    #expect(ready4)
    let ready5 = gate.observe(path: "/a.mov", size: 0, at: t0.addingTimeInterval(20))    // empty files never
    #expect(!ready5)
  }

  @Test("GATE: a file last modified 3 s or more ago is ready at once")
  func oldModificationTimeIsReady() {
    var gate = StableFileGate()
    let now = M305Clock.now
    let ready6 = gate.observe(path: "/old.mov", size: 10, modified: now.addingTimeInterval(-3), at: now)
    #expect(ready6)
    let ready7 = gate.observe(path: "/older.mov", size: 10, modified: now.addingTimeInterval(-3600), at: now)
    #expect(ready7)
  }

  @Test("GATE: a file modified just now waits until its size held for 3 s")
  func recentModificationWaits() {
    var gate = StableFileGate()
    let now = M305Clock.now
    let ready8 = gate.observe(path: "/new.mov", size: 10, modified: now.addingTimeInterval(-1), at: now)
    #expect(!ready8)
    let ready9 = gate.observe(path: "/new.mov", size: 10, modified: now.addingTimeInterval(-1), at: now.addingTimeInterval(1))
    #expect(!ready9)
    let ready10 = gate.observe(path: "/new.mov", size: 10, modified: now.addingTimeInterval(-1), at: now.addingTimeInterval(2))
    #expect(ready10)
  }

  @Test("GATE: the settle time is 3 s and files are tracked apart")
  func settleAndPaths() {
    #expect(StableFileGate().settle == 3)
    var gate = StableFileGate()
    let t0 = Date(timeIntervalSince1970: 100)
    let ready11 = gate.observe(path: "/a.mov", size: 5, at: t0)
    #expect(!ready11)
    let ready12 = gate.observe(path: "/b.mov", size: 5, at: t0.addingTimeInterval(3))
    #expect(!ready12)
    let ready13 = gate.observe(path: "/a.mov", size: 5, at: t0.addingTimeInterval(3))
    #expect(ready13)
  }
}
