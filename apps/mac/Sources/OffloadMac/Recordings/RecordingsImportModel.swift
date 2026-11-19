import Foundation
import OffloadImport

// The model behind onboarding screen 11, Settings, Recordings and the import progress panel (ONBOARDING section 8).
// It owns the chosen folder, its summary, the running import and the import spaces made so far. The import itself
// (OffloadImport `RecordingImporter`) runs off the main actor; its progress values come back here in order.

/// One import space this Mac made, for Settings: "Recordings from Desktop · Nov 5 to 11".
public struct ImportRecord: Codable, Equatable, Sendable {
  public var space: ImportSpace
  /// The folder's last path component only.
  public var folderName: String
  public var first: Date?
  public var last: Date?
  public var moments: Int
  public var createdAt: Date

  public init(space: ImportSpace, folderName: String, first: Date?, last: Date?, moments: Int, createdAt: Date) {
    self.space = space
    self.folderName = folderName
    self.first = first
    self.last = last
    self.moments = moments
    self.createdAt = createdAt
  }
}

/// "Choose folder…" (`NSOpenPanel` in the app).
@MainActor public protocol FolderPicker: AnyObject {
  func pickFolder(startingAt: URL?) -> URL?
}

/// The floating progress panel that keeps going after setup.
@MainActor public protocol ImportPanelPresenter: AnyObject {
  func show(_ model: RecordingsImportModel)
  func hide()
}

/// The folder last chosen and the import spaces made, kept across launches.
@MainActor public protocol RecordingsFolderStore: AnyObject {
  var folder: URL? { get set }
  var imports: [ImportRecord] { get set }
}

@MainActor public final class MemoryRecordingsFolderStore: RecordingsFolderStore {
  public var folder: URL?
  public var imports: [ImportRecord] = []
  public init() {}
}

@MainActor public final class UserDefaultsRecordingsFolderStore: RecordingsFolderStore {
  static let folderKey = "ai.offload.recordings.folder.v1"
  static let importsKey = "ai.offload.recordings.imports.v1"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public var folder: URL? {
    get { defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
    set { defaults.set(newValue?.path, forKey: Self.folderKey) }
  }

  public var imports: [ImportRecord] {
    get {
      guard let data = defaults.data(forKey: Self.importsKey) else { return [] }
      return (try? JSONDecoder().decode([ImportRecord].self, from: data)) ?? []
    }
    set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.importsKey) }
  }
}

@MainActor
public final class RecordingsImportModel: ObservableObject {
  public enum Phase: Equatable {
    case idle
    case reading(file: Int, of: Int)
    case done(ImportReport)
    case refused(String)
    case failed(String)
  }

  @Published public private(set) var folder: URL?
  @Published public private(set) var summary: FolderSummary?
  /// Why the folder cannot be imported, in one sentence; nil when it can.
  @Published public private(set) var refusal: String?
  @Published public private(set) var phase: Phase = .idle
  @Published public private(set) var warnings: [String] = []
  @Published public private(set) var imports: [ImportRecord]
  /// One line under the buttons (not ready, refused, remove failed).
  @Published public private(set) var notice: String?

  private let store: RecordingsFolderStore
  private let picker: FolderPicker
  private let panel: ImportPanelPresenter
  private let importer: RecordingImporter?
  private let sink: (any ImportSink)?
  private let ledger: (any RecordingLedger)?
  private let durations: (URL) -> TimeInterval?
  private let protected: [URL]
  public let timeZone: TimeZone
  private var runningFolderName: String?
  private var consumer: Task<Void, Never>?

  /// `importer` is nil until m3-02 brings on-device OCR and the masker: then Import says so and reads nothing.
  public init(store: RecordingsFolderStore, picker: FolderPicker, panel: ImportPanelPresenter, importer: RecordingImporter?,
              sink: (any ImportSink)?, ledger: (any RecordingLedger)?, durations: @escaping (URL) -> TimeInterval?,
              suggestedFolder: URL, protected: [URL], timeZone: TimeZone = .current) {
    self.store = store
    self.picker = picker
    self.panel = panel
    self.importer = importer
    self.sink = sink
    self.ledger = ledger
    self.durations = durations
    self.protected = protected
    self.timeZone = timeZone
    self.folder = store.folder ?? suggestedFolder
    self.imports = store.imports
    refresh()
  }

  public var canImport: Bool { importer != nil }

  public var isImporting: Bool { consumer != nil }

  /// The folder summary as separate items: "12 files", ".mov", "6 h 10 m", "Nov 5 to 11".
  public var summaryItems: [String] {
    summary.map { RecordingsCopy.summaryItems($0, timeZone: timeZone) } ?? []
  }

  /// The progress panel's line as separate items.
  public var progressItems: [String] {
    switch phase {
    case .idle: return []
    case .reading(let file, let total): return file == 0 ? [RecordingsCopy.starting] : [RecordingsCopy.reading(file: file, of: total)]
    case .done(let report): return RecordingsCopy.doneItems(report)
    case .refused(let message), .failed(let message): return [message]
    }
  }

  /// Scans the folder again for the summary (no file is opened except to read recording lengths).
  public func refresh() {
    guard let folder else {
      summary = nil
      refusal = nil
      return
    }
    switch RecordingFolder.scan(folder, protected: protected, timeZone: timeZone) {
    case .success(let scan):
      summary = FolderSummary.make(scan: scan, timeZone: timeZone, duration: durations)
      refusal = nil
    case .failure(let r):
      summary = nil
      refusal = r.message
    }
  }

  /// "Choose folder…": keeps the folder for next time and reads its summary. A cancel changes nothing.
  public func chooseFolder() {
    guard let url = picker.pickFolder(startingAt: folder) else { return }
    folder = url
    store.folder = url
    notice = nil
    refresh()
  }

  /// Starts the import in the background and shows the panel. False when it cannot start: no importer in this build,
  /// or the folder is refused (the notice says why).
  @discardableResult
  public func startImport() -> Bool {
    guard let importer, let folder else {
      notice = RecordingsCopy.notReady
      return false
    }
    if isImporting { return true }
    refresh()
    if let refusal {
      notice = refusal
      return false
    }
    notice = nil
    warnings = []
    runningFolderName = folder.lastPathComponent
    phase = .reading(file: 0, of: summary?.files ?? 0)
    panel.show(self)
    let (stream, continuation) = AsyncStream<ImportProgress>.makeStream()
    Task.detached {
      await importer.run(folder: folder) { _ = continuation.yield($0) }
      continuation.finish()
    }
    consumer = Task { [weak self] in
      for await p in stream { self?.apply(p) }
      self?.consumer = nil
    }
    return true
  }

  /// Waits until the running import has finished and its progress was applied.
  public func waitForImport() async {
    await consumer?.value
  }

  /// Applies one progress value (in order).
  public func apply(_ p: ImportProgress) {
    switch p {
    case .started(_, let files):
      phase = .reading(file: 0, of: files)
      warnings = []
    case .reading(let file, let total):
      phase = .reading(file: file, of: total)
    case .warning(let w):
      warnings.append(RecordingsCopy.warning(w))
    case .finished(let report):
      phase = .done(report)
      if let space = report.space {
        let record = ImportRecord(space: space, folderName: runningFolderName ?? folder?.lastPathComponent ?? "",
                                  first: report.firstDay, last: report.lastDay, moments: report.moments, createdAt: Date())
        imports.append(record)
        store.imports = imports
      }
    case .refused(let r):
      phase = .refused(r.message)
      notice = r.message
    case .failed(let message):
      phase = .failed(message)
      notice = message
    }
  }

  /// "Remove imported data": the import space is forgotten (`POST /v1/me/forget` scope `import`), its ledger entries
  /// go so the files can be read again, and it leaves the list. If the forget call fails, nothing changes here.
  public func remove(_ record: ImportRecord) async {
    if let sink {
      do {
        try await sink.forget(record.space)
      } catch {
        notice = RecordingsCopy.removeFailed
        return
      }
    }
    try? ledger?.removeEntries(importID: record.space.id)
    imports.removeAll { $0 == record }
    store.imports = imports
    notice = nil
  }

  public func closePanel() { panel.hide() }
}
