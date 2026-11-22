import AppKit
import Foundation
import OffloadImport
import SwiftUI

// m3-05's recordings import made real on this Mac: Vision OCR, the interim masker, the local sink and a file ledger,
// all under `Application Support/Offload/OnDevice`. Built through RecordingsImportModel's public init; nothing in
// OffloadImport or Recordings is changed.

/// "Choose folder…" with a folder picked ahead (a default folder's "Use this folder" button), else the open panel.
@MainActor
public final class OnDeviceFolderPicker: FolderPicker {
  /// Returned by the next pick instead of asking.
  public var next: URL?
  private let fallback: FolderPicker?

  public init(fallback: FolderPicker?) { self.fallback = fallback }

  public func pickFolder(startingAt: URL?) -> URL? {
    if let n = next {
      next = nil
      return n
    }
    return fallback?.pickFolder(startingAt: startingAt)
  }
}

@MainActor
public struct OnDeviceRecordings {
  /// What `make` needs to know about this Mac's folders. Tests inject a temporary home and support folder.
  public struct Folders: Sendable {
    public var home: URL
    /// `com.apple.screencapture` `location`, if set.
    public var screencaptureLocation: String?
    public var paths: OnDevicePaths
    public var exists: @Sendable (String) -> Bool

    public init(home: URL, screencaptureLocation: String?, paths: OnDevicePaths,
                exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
      self.home = home
      self.screencaptureLocation = screencaptureLocation
      self.paths = paths
      self.exists = exists
    }

    public static func live() -> Folders {
      Folders(home: FileManager.default.homeDirectoryForCurrentUser,
              screencaptureLocation: UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
              paths: .live())
    }
  }

  public let model: RecordingsImportModel
  public let sink: LocalImportSink
  public let ledger: FileRecordingLedger
  public let observations: LocalObservationStore
  public let picker: OnDeviceFolderPicker
  public let paths: OnDevicePaths
  /// The default folders, found when the Recordings screen asks (existence only), never at launch.
  public let folderCandidates: RecordingFolderCandidates
  /// Imports a quit or a crash left unfinished, discarded when this was built (review 2, finding 2).
  public let discardedUnfinished: [String]

  /// The recordings model with a real importer. `pseudonymKey` nil reads or creates the local pseudonym key.
  public static func make(neverWatch: NeverWatchStore, store: RecordingsFolderStore, folders: Folders,
                          panel: ImportPanelPresenter? = nil, picker: FolderPicker? = nil,
                          recognizer: (any TextRecognizer)? = nil, pseudonymKey: Data? = nil,
                          readers: RecordingImporter.Readers = .live, clock: any ImportClock = SystemImportClock(),
                          timeZone: TimeZone = .current,
                          durations: (@Sendable (URL) -> TimeInterval?)? = nil,
                          appNames: (@MainActor ([String]) -> @Sendable (String) -> [String])? = { LiveAppNames.resolver(for: $0) })
    throws -> OnDeviceRecordings {
    let paths = folders.paths
    let key = try pseudonymKey ?? LocalPseudonymKey.loadOrCreate(at: paths.pseudonymKey)
    try OnDeviceFiles.ensureFolder(paths.root)
    let sink = LocalImportSink(folder: paths.imports)
    let ledger = FileRecordingLedger(file: paths.ledger)
    let discarded = discardUnfinished(store: store, sink: sink, ledger: ledger)
    let protected = [paths.offloadSupport]
    let importer = RecordingImporter(
      recognizer: recognizer ?? VisionTextRecognizer(), masker: InterimTextMasker(key: key), hasher: nil, keyframes: nil,
      exclusions: NeverWatchImportExclusions(source: neverWatch), sink: sink, ledger: ledger, readers: readers,
      clock: clock, timeZone: timeZone, protected: protected
    )
    // At launch only `~/screenwatch` (outside the folders macOS guards) is checked; otherwise the suggestion is where
    // macOS saves screen recordings, named without looking inside a guarded folder such as Desktop or Documents
    // (m3-05's rule: no folder is read before its screen appears; review 1, finding 5).
    let screenwatch = folders.home.appendingPathComponent("screenwatch", isDirectory: true)
    let suggested = folders.exists(screenwatch.appendingPathComponent("days", isDirectory: true).path) ? screenwatch
      : RecordingFolder.suggested(home: folders.home, screencaptureLocation: folders.screencaptureLocation)
    let chooser = OnDeviceFolderPicker(fallback: picker ?? LiveFolderPicker())
    let lengths: @Sendable (URL) -> TimeInterval? = durations ?? { AVRecordingFrameSource.duration(of: $0) }
    let model = RecordingsImportModel(
      store: store, picker: chooser, panel: panel ?? LiveImportPanel(), importer: importer, sink: sink, ledger: ledger,
      durations: lengths, suggestedFolder: suggested,
      protected: protected, timeZone: timeZone, neverWatch: neverWatch, appNames: appNames
    )
    return OnDeviceRecordings(model: model, sink: sink, ledger: ledger, observations: LocalObservationStore(folder: paths.imports),
                              picker: chooser, paths: paths,
                              folderCandidates: RecordingFolderCandidates(folders: folders, protected: protected),
                              discardedUnfinished: discarded)
  }

  /// At launch, before any import can run: an import is listed (and so removable) only once it finished, so a file or
  /// ledger entries of an import that is not listed come from one a quit or a crash cut short. They are deleted, so
  /// nothing is counted that cannot be removed, and the recordings they came from are read again by the next import
  /// (review 2, finding 2). Returns the discarded import ids.
  static func discardUnfinished(store: RecordingsFolderStore, sink: LocalImportSink, ledger: FileRecordingLedger) -> [String] {
    let listed = Set(store.imports.map(\.space.id))
    let files = LocalObservationStore(folder: sink.folder).importIDs().filter { !listed.contains($0) }
    for id in files { try? FileManager.default.removeItem(at: sink.file(for: id)) }
    let entries = Set(ledger.entries.map(\.importID)).filter { !listed.contains($0) }
    for id in entries { try? ledger.removeEntries(importID: id) }
    return Array(Set(files).union(entries)).sorted()
  }

  /// "Use this folder": the candidate becomes the chosen folder (kept for next time) and is read for its summary.
  public func use(_ candidate: RecordingFolderCandidate) async {
    picker.next = candidate.url
    await model.chooseFolder()
  }
}

/// The default recordings folders for the Recordings screen. `refresh()` checks existence only, and only when the
/// screen asks.
@MainActor
public final class RecordingFolderCandidates: ObservableObject {
  @Published public private(set) var candidates: [RecordingFolderCandidate] = []
  private let folders: OnDeviceRecordings.Folders
  private let protected: [URL]

  public init(folders: OnDeviceRecordings.Folders, protected: [URL]) {
    self.folders = folders
    self.protected = protected
  }

  public func refresh() {
    let exists = folders.exists
    candidates = DefaultRecordingFolders.candidates(home: folders.home, screencaptureLocation: folders.screencaptureLocation,
                                                    protected: protected, exists: { exists($0) })
  }
}

/// The done line of the panel and the Recordings screen: m3-05's line plus "9 things you repeat" once counted.
@MainActor
public enum AnalysisProgress {
  public static func items(_ model: RecordingsImportModel, insights: InsightsModel) -> [String] {
    guard case .done(let report) = model.phase else { return model.progressItems }
    return AnalysisCopy.doneItems(report, repeats: insights.isAnalysing ? nil : insights.snapshot.thingsYouRepeat.count)
  }
}

/// m3-05's floating progress panel, with the local insights done line.
@MainActor
public final class AnalysedImportPanel: ImportPanelPresenter {
  private let insights: InsightsModel
  private var panel: KeyablePanel?

  public init(insights: InsightsModel) { self.insights = insights }

  public func show(_ model: RecordingsImportModel) {
    if panel == nil {
      let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                           styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
      p.titleVisibility = .hidden
      p.titlebarAppearsTransparent = true
      p.isFloatingPanel = true
      p.level = .floating
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      p.hidesOnDeactivate = false
      p.isReleasedWhenClosed = false
      p.isMovableByWindowBackground = true
      p.contentView = NSHostingView(rootView: AnalysedImportPanelView(model: model, insights: insights))
      if let screen = NSScreen.main?.visibleFrame {
        p.setFrameOrigin(NSPoint(x: screen.maxX - 360, y: screen.maxY - 170))
      }
      panel = p
    }
    panel?.orderFrontRegardless()
  }

  public func hide() { panel?.orderOut(nil) }
}

/// The panel's view: "reading file 3 of 12", then "done · 1,284 moments read · 9 things you repeat", and warnings.
public struct AnalysedImportPanelView: View {
  @ObservedObject var model: RecordingsImportModel
  @ObservedObject var insights: InsightsModel

  public init(model: RecordingsImportModel, insights: InsightsModel) {
    self.model = model
    self.insights = insights
  }

  public var body: some View {
    let items = AnalysisProgress.items(model, insights: insights)
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      Text(RecordingsCopy.panelTitle).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.chromeInk)
      if items.isEmpty {
        Text(RecordingsCopy.starting).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
      } else {
        CaptionLine(items.joined(separator: " · "), onChrome: true)
      }
      ForEach(Array(model.warnings.enumerated()), id: \.offset) { pair in
        Text(pair.element).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
      }
      HStack {
        Spacer()
        Button(RecordingsCopy.close) { model.closePanel() }
          .buttonStyle(SecondaryButtonStyle())
      }
    }
    .padding(Tokens.Space.s16)
    .frame(width: 340, alignment: .leading)
    .background(Theme.chrome)
    .onChange(of: model.announcements) { _, _ in
      guard let line = model.announcement else { return }
      AccessibilityNotification.Announcement(line).post()
    }
    .onChange(of: insights.isAnalysing) { _, analysing in
      // The count arrives after the import's own done line: VoiceOver hears it too.
      guard !analysing, case .done = model.phase else { return }
      AccessibilityNotification.Announcement(AnalysisProgress.items(model, insights: insights).joined(separator: ", ")).post()
    }
  }
}
