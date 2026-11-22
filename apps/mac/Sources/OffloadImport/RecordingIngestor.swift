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
      // AVFoundation and ImageIO leave autoreleased buffers behind; drain them after every frame (review 2).
      try autoreleasepool {
        guard let frame = try source.frame(at: t) else { return }
        try run.read(frame, at: start.addingTimeInterval(t), videoTime: t)
      }
    }
    run.idle(.idleStart, at: start.addingTimeInterval(duration + config.idleThreshold))
    return run.result
  }

  // Screenshots are read through `Run` one at a time by the importer (RecordingImporter), so a long run is never
  // held in memory at once.

  /// The state of one span while its frames are read.
  struct Run {
    let ingestor: RecordingIngestor
    let importID: String
    /// Replaced before each screenshot of a streamed run, so Never watch changes apply from the next file.
    var exclusions: [ImportExclusionRule]
    var result = IngestResult()
    /// The app name and host of the last focus written (m3-05c: a host change is a new focus too).
    var lastFocus: String?
    var lastText: String?
    var throttle = KeyframeThrottle()

    init(ingestor: RecordingIngestor, importID: String, exclusions: [ImportExclusionRule]) {
      self.ingestor = ingestor
      self.importID = importID
      self.exclusions = exclusions
    }

    /// The observations made since the last drain, for writing as the run goes (screenshots are streamed).
    mutating func drain() -> [ImportObservation] {
      let out = result.observations
      result.observations = []
      return out
    }

    mutating func idle(_ kind: ImportObservation.Kind, at date: Date) {
      result.observations.append(.idle(kind, id: ingestor.ids.next(at: date), ts: date, importID: importID))
    }

    mutating func read(_ frame: ImportFrame, at date: Date, videoTime: TimeInterval) throws {
      result.frames += 1
      let config = ingestor.config
      let lines = try ingestor.recognizer.recognize(frame)
      // The app name is OCR text too: it is used only when the masker leaves it as it is (a name the masker would
      // change is a person, a number or a document, not an app).
      let seen = MenuBarApp.name(from: lines, frameHeight: frame.height)
      let named = seen.flatMap { ingestor.masker.mask($0) == $0 ? $0 : nil }
      var appName = named ?? config.unknownAppName
      var app = MenuBarApp.bundleID(for: named)
      var host: String?
      // No menu bar app: the window chrome may still name it (m3-05c app cues). A cue's name and bundle id are table
      // constants; its host is one the masker left unchanged.
      if named == nil, let cue = AppCues.classify(lines, frameHeight: frame.height, masker: ingestor.masker) {
        appName = cue.appName
        app = cue.appBundleID
        host = cue.host
      }
      // An excluded app keeps its time and nothing else: no host, no text, no keyframe.
      // Hosts, title rules and private-window markers are read off the frame's own text (review 1).
      let excluded = ImportExclusions.isExcluded(bundleID: app, appName: appName, lines: lines.map(\.text), rules: exclusions)
      if excluded { host = nil }
      let focusKey = host.map { appName + "\u{0}" + $0 } ?? appName
      if focusKey != lastFocus {
        result.observations.append(.focus(id: ingestor.ids.next(at: date), ts: date, importID: importID,
                                          appBundleID: app, appName: appName, host: host))
        lastFocus = focusKey
        lastText = nil
      }
      if excluded { return }

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
