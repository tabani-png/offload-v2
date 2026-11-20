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
  private let durations: @Sendable (URL) -> TimeInterval?
  private let protected: [URL]
  public let timeZone: TimeZone
  /// The Never watch list, read when each import starts (and again before each file by the importer).
  private let neverWatch: (any ExclusionSource)?
  /// Looks up, on the main actor, every name the given apps are shown by; the result is a frozen Sendable table.
  private let appNames: (@MainActor ([String]) -> @Sendable (String) -> [String])?
  /// Whether the last refresh read the folder (it reads nothing while the import is not offered).
  private var readWhileOffered = false
  private var runningFolderName: String?
  private var consumer: Task<Void, Never>?
  /// The last thing VoiceOver was told, and how many times it was told something (the panel posts on each change).
  @Published public private(set) var announcement: String?
  @Published public private(set) var announcements = 0
  private var announcedTenth = 0
  /// Whether the import may be offered: only while the person is signed in and sending (ONBOARDING section 8, "Only
  /// offered after screen 5 was accepted. In Local mode it is hidden"). OnboardingModel sets it; until then it fails
  /// closed.
  public var offerCheck: @MainActor () -> Bool = { false }

  /// `importer` is nil until m3-02 brings on-device OCR and the masker: then Import says so and reads nothing.
  public init(store: RecordingsFolderStore, picker: FolderPicker, panel: ImportPanelPresenter, importer: RecordingImporter?,
              sink: (any ImportSink)?, ledger: (any RecordingLedger)?, durations: @escaping @Sendable (URL) -> TimeInterval?,
              suggestedFolder: URL, protected: [URL], timeZone: TimeZone = .current,
              neverWatch: (any ExclusionSource)? = nil,
              appNames: (@MainActor ([String]) -> @Sendable (String) -> [String])? = nil) {
    self.store = store
    self.picker = picker
    self.panel = panel
    self.importer = importer
    self.sink = sink
    self.ledger = ledger
    self.durations = durations
    self.protected = protected
    self.timeZone = timeZone
    self.neverWatch = neverWatch
    self.appNames = appNames
    self.folder = store.folder ?? suggestedFolder
    self.imports = store.imports
    // No scan here: the folder (often the Desktop, which macOS guards) is read only when screen 11 or Settings,
    // Recordings appears (review 1).
  }

  public var canImport: Bool { importer != nil }

  /// False in Local mode and before "Start sending": the menu item, Settings' Import and screen 11 hide it.
  public var isOffered: Bool { offerCheck() }

  /// Derived from the phase, so the Import button is free again the moment the import has finished.
  public var isImporting: Bool {
    if case .reading = phase { return true }
    return false
  }

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

  /// Scans the folder again for the summary, off the main actor (no file is opened except to read recording
  /// lengths). Views call it when they appear.
  public func refresh() async {
    // Not offered (Local mode, before Start sending): no folder is read, not even by a restored Settings window.
    guard isOffered, let folder else {
      summary = nil
      refusal = nil
      readWhileOffered = false
      return
    }
    readWhileOffered = true
    let protected = self.protected
    let timeZone = self.timeZone
    let durations = self.durations
    let result = await Task.detached { () -> (summary: FolderSummary?, refusal: String?) in
      switch RecordingFolder.scan(folder, protected: protected, timeZone: timeZone) {
      case .success(let scan):
        return (FolderSummary.make(scan: scan, timeZone: timeZone, duration: durations), nil)
      case .failure(let r):
        return (nil, r.message)
      }
    }.value
    // The folder may have changed while the scan ran; only the latest folder's result counts.
    guard folder == self.folder else { return }
    summary = result.summary
    refusal = result.refusal
  }

  /// The import became offered (or not): read the folder once if it was not read while offered. Screen 11 and
  /// Settings call it when `isOffered` changes (review 3: the rule lives here, not in the view).
  public func offerChanged() async {
    // Withdrawn: `refresh()` reads nothing and clears the summary, so the folder is read again when offered again.
    guard isOffered else {
      await refresh()
      return
    }
    guard !readWhileOffered else { return }
    await refresh()
  }

  /// "Choose folder…": keeps the folder for next time and reads its summary. A cancel changes nothing.
  public func chooseFolder() async {
    guard let url = picker.pickFolder(startingAt: folder) else { return }
    folder = url
    store.folder = url
    notice = nil
    await refresh()
  }

  /// Starts the import in the background and shows the panel. False when it cannot start: not offered (Local mode,
  /// or before "Start sending"), no importer in this build, or a refused folder (the notice says why).
  @discardableResult
  public func startImport() async -> Bool {
    guard isOffered else {
      notice = RecordingsCopy.needsSending
      return false
    }
    guard let importer, let folder else {
      notice = RecordingsCopy.notReady
      return false
    }
    if isImporting { return true }
    await refresh()
    // A second tap while the folder was being read must not start a second import.
    if isImporting { return true }
    if let refusal {
      notice = refusal
      return false
    }
    notice = nil
    warnings = []
    runningFolderName = folder.lastPathComponent
    phase = .reading(file: 0, of: summary?.files ?? 0)
    panel.show(self)
    // The Never watch list as it is now, with its apps' names looked up now, on the main actor: an app the person
    // added after launch (screen 9 in first-run setup) is matched by the name its menu bar shows (review 3).
    let exclusions: (any ImportExclusionSource)?
    if let neverWatch {
      let ids = neverWatch.currentExclusions().filter { $0.kind == .bundleID }.map(\.value) + ImportExclusions.builtInBundleIDs
      if let lookup = appNames?(ids) {
        exclusions = NeverWatchImportExclusions(source: neverWatch, appNames: lookup)
      } else {
        exclusions = NeverWatchImportExclusions(source: neverWatch)
      }
    } else {
      exclusions = nil
    }
    let (stream, continuation) = AsyncStream<ImportProgress>.makeStream()
    Task.detached {
      await importer.run(folder: folder, exclusions: exclusions) { _ = continuation.yield($0) }
      continuation.finish()
    }
    // The latest import's task. It is never cleared, so an older task finishing late cannot drop a newer one
    // (review 2: simpler than tracking which task is current); `isImporting` follows the phase.
    consumer = Task { [weak self] in
      for await p in stream { self?.apply(p) }
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
      announcedTenth = 0
      announce(RecordingsCopy.panelTitle)
    case .reading(let file, let total):
      phase = .reading(file: file, of: total)
      // VoiceOver hears about every tenth of the files, not each one.
      let tenth = total > 0 ? min(10, file * 10 / total) : 0
      if tenth > announcedTenth {
        announcedTenth = tenth
        announce(RecordingsCopy.reading(file: file, of: total))
      }
    case .warning(let w):
      let line = RecordingsCopy.warning(w)
      warnings.append(line)
      announce(line)
    case .finished(let report):
      phase = .done(report)
      announce(RecordingsCopy.doneItems(report).joined(separator: ", "))
      if let space = report.space {
        let record = ImportRecord(space: space, folderName: runningFolderName ?? folder?.lastPathComponent ?? "",
                                  first: report.firstDay, last: report.lastDay, moments: report.moments, createdAt: Date())
        imports.append(record)
        store.imports = imports
      }
    case .refused(let r):
      phase = .refused(r.message)
      notice = r.message
      announce(r.message)
    case .failed(let message):
      phase = .failed(message)
      notice = message
      announce(message)
    }
  }

  private func announce(_ line: String) {
    announcement = line
    announcements += 1
  }

  /// Clears the one-line notice (after Choose folder…, the old line no longer applies).
  public func clearNotice() { notice = nil }

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
