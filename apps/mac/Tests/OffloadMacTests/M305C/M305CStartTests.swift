import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import OffloadImport

// A recording's start: the container creation date, else the name's time, else its modified time minus its length
// with a stable per-file order, so copied files that share a modified time do not collapse onto one minute.
extension M305C {
  // MARK: START

  @Test("START: the container creation date is the start, before the name's time")
  func creationDateFirst() {
    let created = M305Clock.date(2026, 11, 13, 9, 40, 0)
    let named = M305Clock.date(2026, 11, 13, 9, 41, 7)
    let plan = RecordingStartTime.plan([M305C.times("Screen Recording 2026-11-13 at 9.41.07 AM.mov", created: created,
                                                    nameDate: named, modified: M305Clock.date(2026, 11, 18, 8, 0, 0))],
                                       now: M305Clock.now)
    #expect(plan == [RecordingStart(start: created, source: .containerCreation)])
    #expect(RecordingStartSource.containerCreation.rawValue == "container_creation")
    #expect(RecordingStartSource.modifiedOrdered.rawValue == "modified_ordered")
  }

  @Test("START: without a creation date the name's time is the start")
  func nameNext() {
    let named = M305Clock.date(2026, 11, 13, 9, 41, 7)
    let plan = RecordingStartTime.plan([M305C.times("a.mov", nameDate: named, modified: M305Clock.date(2026, 11, 18, 8, 0, 0))],
                                       now: M305Clock.now)
    #expect(plan == [RecordingStart(start: named, source: .name)])
  }

  @Test("START: a creation date of QuickTime's zero, the Unix zero, before 2000 or in the future is not a time")
  func badCreationDatesIgnored() {
    let named = M305Clock.date(2026, 11, 13, 9, 41, 7)
    let modified = M305Clock.date(2026, 11, 18, 8, 0, 0)
    let bad = [Date(timeIntervalSince1970: -2_082_844_800), Date(timeIntervalSince1970: 0),
               M305Clock.date(1999, 12, 31, 23, 0, 0), M305Clock.now.addingTimeInterval(86_400)]
    for created in bad {
      let withName = RecordingStartTime.plan([M305C.times("n.mov", created: created, nameDate: named, modified: modified)],
                                             now: M305Clock.now)
      #expect(withName == [RecordingStart(start: named, source: .name)], "\(created)")
      let plain = RecordingStartTime.plan([M305C.times("p.mov", created: created, modified: modified)], now: M305Clock.now)
      #expect(plain == [RecordingStart(start: modified.addingTimeInterval(-60), source: .modifiedOrdered)], "\(created)")
    }
  }

  @Test("START: files sharing a modified time are laid end to end in name order, with a gap over the idle threshold")
  func sharedModifiedTimeIsOrdered() {
    let m = M305Clock.date(2026, 11, 14, 10, 0, 0)
    let files = [M305C.times("b.mov", modified: m, duration: 60), M305C.times("a.mov", modified: m, duration: 120),
                 M305C.times("c.mov", modified: m, duration: 30)]
    let plan = RecordingStartTime.plan(files, now: M305Clock.now)
    #expect(RecordingStartTime.sharedTimeGap == 180)
    #expect(RecordingStartTime.sharedTimeGap > RecordingIngestConfig().idleThreshold)
    // c ends at m; b ends one gap before c starts; a ends one gap before b starts.
    #expect(plan.map { $0?.start } == [m.addingTimeInterval(-30 - 180 - 60), m.addingTimeInterval(-30 - 180 - 60 - 180 - 120),
                                       m.addingTimeInterval(-30)])
    #expect(plan.allSatisfy { $0?.source == .modifiedOrdered })
    let spans = zip(files, plan).compactMap { f, p in p.map { (start: $0.start, end: $0.start.addingTimeInterval(f.duration ?? 0)) } }
      .sorted { $0.start < $1.start }
    for (x, y) in zip(spans, spans.dropFirst()) { #expect(y.start.timeIntervalSince(x.end) >= 180) }
  }

  @Test("START: the order is stable: the same files give the same starts whatever order they are listed in")
  func orderIsStable() {
    let m = M305Clock.date(2026, 11, 14, 10, 0, 0)
    let files = [M305C.times("clip 1.mov", modified: m), M305C.times("clip 2.mov", modified: m),
                 M305C.times("clip 3.mov", modified: m.addingTimeInterval(1)), M305C.times("other.mov", modified: m)]
    func starts(_ list: [RecordingTimes]) -> [String: Date] {
      var out: [String: Date] = [:]
      for (f, p) in zip(list, RecordingStartTime.plan(list, now: M305Clock.now)) { out[f.name] = p?.start }
      return out
    }
    let reference = starts(files)
    #expect(reference.count == 4)
    #expect(Set(reference.values).count == 4)
    for list in [Array(files.reversed()), [files[2], files[0], files[3], files[1]], [files[1], files[3], files[0], files[2]]] {
      #expect(starts(list) == reference)
    }
  }

  @Test("START: files whose modified times are far apart keep their modified time minus their length")
  func farApartKeepModified() {
    let m = M305Clock.date(2026, 11, 14, 10, 0, 0)
    let plan = RecordingStartTime.plan([M305C.times("x.mov", modified: m), M305C.times("y.mov", modified: m.addingTimeInterval(3600))],
                                       now: M305Clock.now)
    #expect(plan == [RecordingStart(start: m.addingTimeInterval(-60), source: .modifiedOrdered),
                     RecordingStart(start: m.addingTimeInterval(3540), source: .modifiedOrdered)])
  }

  @Test("START: a file that would end in the future has no start; a future name falls back to the modified time")
  func futureFiles() {
    let past = M305Clock.date(2026, 11, 14, 10, 0, 0)
    let plan = RecordingStartTime.plan([
      M305C.times("future.mov", modified: M305Clock.now.addingTimeInterval(3600)),
      M305C.times("Screen Recording 2026-11-21 at 9.41.07 AM.mov", nameDate: M305Clock.date(2026, 11, 21, 9, 41, 7), modified: past),
    ], now: M305Clock.now)
    #expect(plan[0] == nil)
    #expect(plan[1] == RecordingStart(start: past.addingTimeInterval(-60), source: .modifiedOrdered))
  }

  @Test("START: the importer reads the injected creation date, and the two-argument readers have none")
  func importerUsesInjectedCreationDate() async throws {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "standup.mov", modified: M305Clock.date(2026, 11, 18, 17, 0, 0))
    let created = M305Clock.date(2026, 11, 10, 8, 30, 0)
    let fakes = M305Importer()
    let log = await M305C.run(fakes, folder: folder, created: ["standup.mov": created])
    let space = try #require(log.report?.space)
    let first = try #require(fakes.sink.observations(in: space.id).first)
    #expect(first.kind == .idleEnd)
    #expect(first.ts == created)
    let plain = RecordingImporter.Readers(openVideo: { _ in FakeRecording(M305Script.twoApps()) },
                                          openImage: { _ in ImportFrame(width: 1, height: 1, tag: "x") })
    #expect(plain.creationDates.creationDate(of: folder.appendingPathComponent("standup.mov")) == nil)
    #expect(plain.duration == nil)
    #expect(RecordingImporter.Readers.live.creationDates is AVRecordingCreationDates)
    #expect(RecordingImporter.Readers.live.duration != nil)
  }

  @Test("START: three copied recordings with one modified time do not overlap after import")
  func copiedRecordingsDoNotCollapse() async throws {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    let m = M305Clock.date(2026, 11, 14, 10, 0, 0)
    for name in ["clip-c.mov", "clip-a.mov", "clip-b.mov"] { M305Files.put(folder, name, modified: m) }
    let fakes = M305Importer()
    let log = await M305C.run(fakes, folder: folder)
    let report = try #require(log.report)
    #expect(report.filesRead == 3)
    let space = try #require(report.space)
    let all = fakes.sink.observations(in: space.id)
    // Each default recording is 60 s; the last in name order ends at the shared modified time.
    let starts = all.filter { $0.kind == .idleEnd }.map(\.ts).sorted()
    #expect(starts == [m.addingTimeInterval(-60 - 240 - 240), m.addingTimeInterval(-60 - 240), m.addingTimeInterval(-60)])
    #expect(Set(starts.map { Int($0.timeIntervalSince1970 / 60) }).count == 3)
    // Every recording is its own span: idle_end and idle_start alternate in time.
    let idle = all.filter { $0.kind == .idleEnd || $0.kind == .idleStart }.sorted { $0.ts < $1.ts }.map(\.kind)
    #expect(idle == [.idleEnd, .idleStart, .idleEnd, .idleStart, .idleEnd, .idleStart])
  }

  @Test("START: the live reader takes the creation date from the container's metadata; a file without one gives nil")
  func liveCreationDate() throws {
    let dir = M305Files.folder()
    defer { M305Files.remove(dir) }
    let reader = AVRecordingCreationDates()
    #expect(reader.creationDate(of: dir.appendingPathComponent("missing.mov")) == nil)
    let text = M305Files.put(dir, "notes.mov")
    #expect(reader.creationDate(of: text) == nil)
    let url = try m305cTinyVideo(in: dir, created: "2026-11-13T09:41:07Z")
    #expect(reader.creationDate(of: url) == M305Clock.date(2026, 11, 13, 9, 41, 7))
  }
}

/// A one-second Motion-JPEG .mov whose QuickTime metadata holds `created` as its creation date.
func m305cTinyVideo(in dir: URL, created: String) throws -> URL {
  let url = dir.appendingPathComponent("created.mov")
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  let item = AVMutableMetadataItem()
  item.keySpace = .quickTimeMetadata
  item.key = AVMetadataKey.quickTimeMetadataKeyCreationDate.rawValue as NSString
  item.value = created as NSString
  writer.metadata = [item]
  let (width, height, fps): (Int, Int, Int32) = (64, 48, 5)
  let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: width, AVVideoHeightKey: height]
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
  input.expectsMediaDataInRealTime = false
  let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                                   kCVPixelBufferWidthKey as String: width,
                                   kCVPixelBufferHeightKey as String: height]
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
  writer.add(input)
  guard writer.startWriting() else { throw writer.error ?? M305VideoError() }
  writer.startSession(atSourceTime: .zero)
  for i in 0..<Int(fps) {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    var buffer: CVPixelBuffer?
    _ = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard let buffer else { throw M305VideoError() }
    _ = CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) { _ = memset(base, Int32(60 + i * 30), CVPixelBufferGetDataSize(buffer)) }
    _ = CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)) else {
      throw writer.error ?? M305VideoError()
    }
  }
  input.markAsFinished()
  writer.endSession(atSourceTime: CMTime(value: CMTimeValue(fps), timescale: fps))
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  guard writer.status == .completed else { throw writer.error ?? M305VideoError() }
  return url
}
