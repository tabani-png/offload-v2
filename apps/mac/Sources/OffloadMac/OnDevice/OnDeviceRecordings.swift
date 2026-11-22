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
  /// The default folders found when the model was built (existence only).
  public let candidates: [RecordingFolderCandidate]

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
    let protected = [paths.offloadSupport]
    let importer = RecordingImporter(
      recognizer: recognizer ?? VisionTextRecognizer(), masker: InterimTextMasker(key: key), hasher: nil, keyframes: nil,
      exclusions: NeverWatchImportExclusions(source: neverWatch), sink: sink, ledger: ledger, readers: readers,
      clock: clock, timeZone: timeZone, protected: protected
    )
    let exists = folders.exists
    let candidates = DefaultRecordingFolders.candidates(home: folders.home, screencaptureLocation: folders.screencaptureLocation,
                                                        protected: protected, exists: { exists($0) })
    let suggested = candidates.first?.url
      ?? RecordingFolder.suggested(home: folders.home, screencaptureLocation: folders.screencaptureLocation)
    let chooser = OnDeviceFolderPicker(fallback: picker ?? LiveFolderPicker())
    let lengths: @Sendable (URL) -> TimeInterval? = durations ?? { AVRecordingFrameSource.duration(of: $0) }
    let model = RecordingsImportModel(
      store: store, picker: chooser, panel: panel ?? LiveImportPanel(), importer: importer, sink: sink, ledger: ledger,
      durations: lengths, suggestedFolder: suggested,
      protected: protected, timeZone: timeZone, neverWatch: neverWatch, appNames: appNames
    )
    return OnDeviceRecordings(model: model, sink: sink, ledger: ledger, observations: LocalObservationStore(folder: paths.imports),
                              picker: chooser, paths: paths, candidates: candidates)
  }

  /// "Use this folder": the candidate becomes the chosen folder (kept for next time) and is read for its summary.
  public func use(_ candidate: RecordingFolderCandidate) async {
    picker.next = candidate.url
    await model.chooseFolder()
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
