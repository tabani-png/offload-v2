import Foundation

// A whole folder into one import space, on the Mac. Ported from PR #44 (RecordingFolder.swift `ingest`) and
// wip/s34-brain (folder.ts): scan, wait for files still being written (StableFileGate), skip what the ledger already
// holds, open the import space only when there is something new, read each file through the ingestor (or the
// screenwatch reader), hand the masked observations to the sink, then record the file in the ledger. Progress is
// reported as typed values; the app's panel draws them.

/// Time for the gate's waits. Tests move it by hand.
public protocol ImportClock: Sendable {
  func now() -> Date
  func sleep(seconds: TimeInterval) async
}

public struct SystemImportClock: ImportClock {
  public init() {}
  public func now() -> Date { Date() }
  public func sleep(seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
  }
}

public enum ImportWarning: Equatable, Sendable {
  /// Files that kept growing while the import waited: left for the next import.
  case stillWriting(files: Int)
  /// A file that could not be read. The name is for the person's message only and is never stored.
  case unreadable(file: String)
  /// A file whose time would be in the future (the server rejects that): skipped.
  case futureTime(file: String)
}

public struct ImportReport: Equatable, Sendable {
  /// Nil when nothing new was read (no import space was opened).
  public var space: ImportSpace?
  public var filesRead: Int
  public var skipped: Int
  public var failed: Int
  public var stillWriting: Int
  /// Frames read plus screenwatch rows.
  public var moments: Int
  public var observations: Int
  /// The first and last observation times.
  public var firstDay: Date?
  public var lastDay: Date?

  public init(space: ImportSpace?, filesRead: Int, skipped: Int, failed: Int, stillWriting: Int, moments: Int,
              observations: Int, firstDay: Date?, lastDay: Date?) {
    self.space = space
    self.filesRead = filesRead
    self.skipped = skipped
    self.failed = failed
    self.stillWriting = stillWriting
    self.moments = moments
    self.observations = observations
    self.firstDay = firstDay
    self.lastDay = lastDay
  }
}

public enum ImportProgress: Equatable, Sendable {
  case started(ImportSourceKind, files: Int)
  case reading(file: Int, of: Int)
  case warning(ImportWarning)
  case finished(ImportReport)
  case refused(ImportRefusal)
  /// The import space could not be opened; nothing was read.
  case failed(String)
}

public struct RecordingImporter: Sendable {
  /// How files are opened. The app uses AVFoundation and ImageIO; tests use scripted frames.
  public struct Readers: Sendable {
    public var openVideo: @Sendable (URL) throws -> any RecordingFrameSource
    public var openImage: @Sendable (URL) throws -> ImportFrame

    public init(openVideo: @escaping @Sendable (URL) throws -> any RecordingFrameSource,
                openImage: @escaping @Sendable (URL) throws -> ImportFrame) {
      self.openVideo = openVideo
      self.openImage = openImage
    }

    public static let live = Readers(
      openVideo: { try AVRecordingFrameSource(url: $0) },
      openImage: { try ImageFileFrameSource.frame(url: $0) }
    )
  }

  /// The server rejects a `ts` more than 10 minutes ahead (ADR 0020).
  public static let futureSlack: TimeInterval = 600
  /// How many times the gate looks at files still being written before leaving them for next time.
  public static let gateLooks = 5

  public let ingestor: RecordingIngestor
  public let exclusions: any ImportExclusionSource
  public let sink: any ImportSink
  public let ledger: any RecordingLedger
  public let readers: Readers
  public let clock: any ImportClock
  public let timeZone: TimeZone
  public let protected: [URL]

  public init(recognizer: any TextRecognizer, masker: any ImportTextMasker, hasher: (any FrameHasher)? = nil,
              keyframes: (any ImportKeyframeSink)? = nil, exclusions: any ImportExclusionSource,
              sink: any ImportSink, ledger: any RecordingLedger, readers: Readers = .live,
              clock: any ImportClock = SystemImportClock(), timeZone: TimeZone = .current, protected: [URL] = [],
              config: RecordingIngestConfig = RecordingIngestConfig()) {
    self.ingestor = RecordingIngestor(recognizer: recognizer, masker: masker, hasher: hasher, keyframes: keyframes,
                                      config: config)
    self.exclusions = exclusions
    self.sink = sink
    self.ledger = ledger
    self.readers = readers
    self.clock = clock
    self.timeZone = timeZone
    self.protected = protected
  }

  /// Imports `folder`. Returns the report (also sent as `.finished`), or nil when the folder was refused or the
  /// import space could not be opened.
  @discardableResult
  /// `exclusions` replaces the importer's own source for this run (the app builds it when the import starts, with the
  /// Never watch list's app names looked up then).
  public func run(folder: URL, exclusions override: (any ImportExclusionSource)? = nil,
                  progress: (ImportProgress) -> Void) async -> ImportReport? {
    let exclusions = override ?? self.exclusions
    let scan: FolderScan
    switch RecordingFolder.scan(folder, protected: protected, timeZone: timeZone) {
    case .failure(let refusal):
      progress(.refused(refusal))
      return nil
    case .success(let s):
      scan = s
    }
    progress(.started(scan.sourceKind, files: scan.files.count))

    // 1. Wait for files still being written.
    var gate = StableFileGate()
    var waiting = scan.files
    var ready: [ScannedFile] = []
    for look in 0..<Self.gateLooks {
      let now = clock.now()
      var still: [ScannedFile] = []
      for file in waiting {
        let (size, modified) = Self.attributes(file.url)
        if gate.observe(path: file.url.path, size: size, modified: modified, at: now) { ready.append(file) } else { still.append(file) }
      }
      waiting = still
      if waiting.isEmpty || look == Self.gateLooks - 1 { break }
      await clock.sleep(seconds: gate.settle)
    }
    let order = Dictionary(uniqueKeysWithValues: scan.files.enumerated().map { ($1.url, $0) })
    ready.sort { (order[$0.url] ?? 0) < (order[$1.url] ?? 0) }
    if !waiting.isEmpty { progress(.warning(.stillWriting(files: waiting.count))) }

    // 2. Skip what was already read (a file's fingerprint changes when it changes).
    var report = ImportReport(space: nil, filesRead: 0, skipped: 0, failed: 0, stillWriting: waiting.count, moments: 0,
                              observations: 0, firstDay: nil, lastDay: nil)
    var todo: [(file: ScannedFile, fingerprint: String)] = []
    for file in ready {
      let (size, modified) = Self.attributes(file.url)
      let fp = RecordingFingerprint.of(path: file.url.standardizedFileURL.path, size: size, modified: modified ?? Date(timeIntervalSince1970: 0))
      if ledger.contains(fp) { report.skipped += 1 } else { todo.append((file, fp)) }
    }
    guard !todo.isEmpty else {
      progress(.finished(report))
      return report
    }

    // 3. One import space for everything new.
    let space: ImportSpace
    do {
      space = try await sink.openImport(sourceKind: scan.sourceKind)
    } catch {
      progress(.failed("The import could not be started. Nothing was read."))
      return nil
    }
    report.space = space

    // 4. Read, write, record. Screenshots taken within a run's gap of each other are read as one span.
    var i = 0
    while i < todo.count {
      var group = [todo[i]]
      if todo[i].file.kind == .image {
        while i + group.count < todo.count, todo[i + group.count].file.kind == .image,
              let prev = group.last.map({ Self.time(of: $0.file) }),
              Self.time(of: todo[i + group.count].file).timeIntervalSince(prev) <= ingestor.config.runGap {
          group.append(todo[i + group.count])
        }
      }
      // Screenshots report each file as they open it; other files are one per group.
      if todo[i].file.kind != .image { progress(.reading(file: i + 1, of: todo.count)) }
      // Read again before each file, so a Never watch entry added meanwhile applies from here on.
      let rules = exclusions.currentRules()
      readGroup(group, space: space, rules: rules, exclusions: exclusions, fileOffset: i, total: todo.count, report: &report,
                progress: progress)
      i += group.count
    }
    progress(.finished(report))
    return report
  }

  private func readGroup(_ group: [(file: ScannedFile, fingerprint: String)], space: ImportSpace,
                         rules: [ImportExclusionRule], exclusions: any ImportExclusionSource, fileOffset: Int, total: Int,
                         report: inout ImportReport,
                         progress: (ImportProgress) -> Void) {
    let now = clock.now()
    let first = group[0].file
    do {
      let result: IngestResult
      let moments: Int
      switch first.kind {
      case .video:
        let source = try readers.openVideo(first.url)
        // A recorder writes until the recording ends, so without a name time the start is the last write minus the
        // length. The file may have grown while the gate waited, so its time is read again here.
        let modified = Self.attributes(first.url).modified ?? first.modified
        var start = first.nameDate ?? modified.addingTimeInterval(-source.duration)
        if start.addingTimeInterval(source.duration) > now.addingTimeInterval(Self.futureSlack) {
          start = modified.addingTimeInterval(-source.duration)
        }
        guard start.addingTimeInterval(source.duration) <= now.addingTimeInterval(Self.futureSlack) else {
          progress(.warning(.futureTime(file: first.url.lastPathComponent)))
          return
        }
        result = try ingestor.ingest(source, startedAt: start, importID: space.id, exclusions: rules)
        moments = result.frames
      case .image:
        // One span for the run, but one screenshot in memory at a time: each is opened, read, written and recorded
        // before the next is opened (review 1: a long run of screenshots must not be held all at once).
        var run = RecordingIngestor.Run(ingestor: ingestor, importID: space.id, exclusions: rules)
        var firstAt: Date?
        var lastAt: Date?
        for (n, item) in group.enumerated() {
          progress(.reading(file: fileOffset + n + 1, of: total))
          let name = item.file.url.lastPathComponent
          let at = Self.time(of: item.file)
          guard at <= now.addingTimeInterval(Self.futureSlack) else {
            progress(.warning(.futureTime(file: name)))
            continue
          }
          do {
            // One screenshot's buffers are released before the next is opened (review 2).
            try autoreleasepool {
              let frame = try readers.openImage(item.file.url)
              if firstAt == nil {
                run.idle(.idleEnd, at: at)
                firstAt = at
              }
              run.exclusions = exclusions.currentRules()
              try run.read(frame, at: at, videoTime: at.timeIntervalSince(firstAt ?? at))
            }
            try write(run.drain(), space: space, report: &report)
            try ledger.record(RecordingLedgerEntry(fingerprint: item.fingerprint, importID: space.id, ingestedAt: now,
                                                   recordedAt: at, moments: 1))
            report.filesRead += 1
            report.moments += 1
            lastAt = at
          } catch {
            report.failed += 1
            progress(.warning(.unreadable(file: name)))
          }
        }
        if let lastAt {
          run.idle(.idleStart, at: lastAt.addingTimeInterval(ingestor.config.idleThreshold))
          do {
            try write(run.drain(), space: space, report: &report)
          } catch {
            progress(.warning(.unreadable(file: first.url.lastPathComponent)))
          }
        }
        return
      case .screenwatchDay:
        let text = try String(contentsOf: first.url, encoding: .utf8)
        let rows = ScreenwatchReader.parse(text).rows.filter { $0.ts <= now.addingTimeInterval(Self.futureSlack) }
        let observations = ScreenwatchReader.observations(rows: rows, importID: space.id, masker: ingestor.masker,
                                                          exclusions: rules, ids: ingestor.ids,
                                                          idleThreshold: ingestor.config.idleThreshold,
                                                          gap: ingestor.config.runGap)
        var r = IngestResult()
        r.observations = observations
        r.frames = rows.count
        result = r
        moments = rows.count
      }
      try write(result.observations, space: space, report: &report)
      try ledger.record(RecordingLedgerEntry(fingerprint: group[0].fingerprint, importID: space.id, ingestedAt: now,
                                             recordedAt: result.observations.first?.ts ?? Self.time(of: first),
                                             moments: moments))
      report.filesRead += 1
      report.moments += moments
    } catch {
      report.failed += group.count
      progress(.warning(.unreadable(file: first.url.lastPathComponent)))
    }
  }

  private func write(_ observations: [ImportObservation], space: ImportSpace, report: inout ImportReport) throws {
    guard !observations.isEmpty else { return }
    try sink.write(observations, to: space)
    report.observations += observations.count
    let times = observations.map(\.ts)
    if let lo = times.min() { report.firstDay = min(report.firstDay ?? lo, lo) }
    if let hi = times.max() { report.lastDay = max(report.lastDay ?? hi, hi) }
  }

  /// A screenshot's or row file's time: its name's, else its modified time.
  static func time(of file: ScannedFile) -> Date { file.nameDate ?? file.modified }

  static func attributes(_ url: URL) -> (size: Int64, modified: Date?) {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    return (size, attrs?[.modificationDate] as? Date)
  }
}
