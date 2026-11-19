import Foundation

// Ported from PR #44 (engine/Sources/OffloadCore/Recordings/RecordingIngestor.swift). One recording (or one run of
// screenshots) becomes ordinary masked observations, with the same privacy path as live capture: OCR in memory, the
// masker before anything is written, excluded apps get no text and no keyframe. Timestamps are the recording's own:
// v2 keeps real times in the import space instead of moving old recordings into the retention window.

public struct RecordingIngestConfig: Equatable, Sendable {
  /// Seconds between sampled frames.
  public var interval: TimeInterval = SamplePlan.interval
  /// At most this many frames per recording.
  public var maxFrames = SamplePlan.maxFrames
  /// The idle threshold: readers backdate `idle_start` by it, so a recording closes at its real end.
  public var idleThreshold: TimeInterval = 120
  /// Screenshots further apart than this start a new run (a gap is idle).
  public var runGap: TimeInterval = 120
  /// The app name when no menu bar is in the frame.
  public var unknownAppName = "Screen"

  public init() {}
}

public struct IngestResult: Equatable, Sendable {
  public var observations: [ImportObservation] = []
  public var frames = 0
  public var keyframes = 0

  public init() {}
}

/// A screenshot with its time.
public struct Screenshot: Sendable {
  public var frame: ImportFrame
  public var at: Date

  public init(frame: ImportFrame, at: Date) {
    self.frame = frame
    self.at = at
  }
}

public struct RecordingIngestor: Sendable {
  public let recognizer: any TextRecognizer
  public let masker: any ImportTextMasker
  /// Keyframes need both the hasher and the sink; without either they are off.
  public let hasher: (any FrameHasher)?
  public let keyframes: (any ImportKeyframeSink)?
  public let ids: ULIDGenerator
  public let config: RecordingIngestConfig

  public init(recognizer: any TextRecognizer, masker: any ImportTextMasker, hasher: (any FrameHasher)? = nil,
              keyframes: (any ImportKeyframeSink)? = nil, ids: ULIDGenerator = ULIDGenerator(),
              config: RecordingIngestConfig = RecordingIngestConfig()) {
    self.recognizer = recognizer
    self.masker = masker
    self.hasher = hasher
    self.keyframes = keyframes
    self.ids = ids
    self.config = config
  }

  /// Every frame of the plan through OCR, the masker, the exclusions and the keyframe throttle.
  public func ingest(_ source: any RecordingFrameSource, startedAt start: Date, importID: String,
                     exclusions: [ImportExclusionRule]) throws -> IngestResult {
    let duration = max(0, source.duration)
    var run = Run(ingestor: self, importID: importID, exclusions: exclusions)
    run.idle(.idleEnd, at: start)
    for t in SamplePlan.times(duration: duration, interval: config.interval, maxFrames: config.maxFrames) {
      guard let frame = try source.frame(at: t) else { continue }
      try run.read(frame, at: start.addingTimeInterval(t), videoTime: t)
    }
    run.idle(.idleStart, at: start.addingTimeInterval(duration + config.idleThreshold))
    return run.result
  }

  /// One run of screenshots (sorted, each within `runGap` of the one before) as one span of activity.
  public func ingestScreenshots(_ shots: [Screenshot], importID: String, exclusions: [ImportExclusionRule]) throws -> IngestResult {
    guard let first = shots.first, let last = shots.last else { return IngestResult() }
    var run = Run(ingestor: self, importID: importID, exclusions: exclusions)
    run.idle(.idleEnd, at: first.at)
    for shot in shots {
      try run.read(shot.frame, at: shot.at, videoTime: shot.at.timeIntervalSince(first.at))
    }
    run.idle(.idleStart, at: last.at.addingTimeInterval(config.idleThreshold))
    return run.result
  }

  /// The state of one span while its frames are read.
  struct Run {
    let ingestor: RecordingIngestor
    let importID: String
    let exclusions: [ImportExclusionRule]
    var result = IngestResult()
    var lastApp: String?
    var lastText: String?
    var throttle = KeyframeThrottle()

    init(ingestor: RecordingIngestor, importID: String, exclusions: [ImportExclusionRule]) {
      self.ingestor = ingestor
      self.importID = importID
      self.exclusions = exclusions
    }

    mutating func idle(_ kind: ImportObservation.Kind, at date: Date) {
      result.observations.append(.idle(kind, id: ingestor.ids.next(at: date), ts: date, importID: importID))
    }

    mutating func read(_ frame: ImportFrame, at date: Date, videoTime: TimeInterval) throws {
      result.frames += 1
      let config = ingestor.config
      let lines = try ingestor.recognizer.recognize(frame)
      let appName = MenuBarApp.name(from: lines, frameHeight: frame.height) ?? config.unknownAppName
      let app = MenuBarApp.bundleID(for: appName == config.unknownAppName ? nil : appName)
      if appName != lastApp {
        result.observations.append(.focus(id: ingestor.ids.next(at: date), ts: date, importID: importID,
                                          appBundleID: app, appName: appName))
        lastApp = appName
        lastText = nil
      }
      // An excluded app keeps its time and nothing else: no text, no keyframe.
      if ImportExclusions.isExcluded(bundleID: app, appName: appName, title: nil, host: nil, rules: exclusions) { return }

      let body = lines.filter { !MenuBarApp.isInBand($0, frameHeight: frame.height) }.map(\.text).joined(separator: "\n")
      if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // Masked before it is held anywhere: only the masker's output becomes an observation.
        let masked = ingestor.masker.mask(body)
        if masked != lastText {
          result.observations.append(.text(id: ingestor.ids.next(at: date), ts: date, importID: importID,
                                           appBundleID: app, text: masked))
          lastText = masked
        }
      }

      guard let hasher = ingestor.hasher, let sink = ingestor.keyframes, throttle.mightKeep(at: videoTime) else { return }
      guard throttle.keep(at: videoTime, hash: hasher.hash(frame)) else { return }
      try sink.keep(frame, keyframe: ImportKeyframe(importID: importID, ts: date, appBundleID: app, appName: appName, lines: lines))
      result.keyframes += 1
    }
  }
}
