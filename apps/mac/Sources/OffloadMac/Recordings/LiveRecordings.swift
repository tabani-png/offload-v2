import AppKit
import OffloadImport
import SwiftUI

// The AppKit pieces of the recordings import. Tests never build these.

/// "Choose folder…": a directories-only open panel.
@MainActor public final class LiveFolderPicker: FolderPicker {
  public init() {}

  public func pickFolder(startingAt: URL?) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = OnboardingCopy.chooseFolder
    panel.directoryURL = startingAt
    NSApp.activate()
    return panel.runModal() == .OK ? panel.url : nil
  }
}

/// A panel that can become key without activating Offload, floating above other windows on every Space. Written
/// after the KeyablePanel idea in farzaa/clicky `MenuBarPanelManager.swift` (MIT; see the SPEC's Scope changes).
final class KeyablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// The import progress panel, which keeps going after setup.
@MainActor public final class LiveImportPanel: ImportPanelPresenter {
  private var panel: KeyablePanel?

  public init() {}

  public func show(_ model: RecordingsImportModel) {
    if panel == nil {
      let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 140),
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
      p.contentView = NSHostingView(rootView: ImportPanelView(model: model))
      if let screen = NSScreen.main?.visibleFrame {
        p.setFrameOrigin(NSPoint(x: screen.maxX - 360, y: screen.maxY - 160))
      }
      panel = p
    }
    panel?.orderFrontRegardless()
  }

  public func hide() { panel?.orderOut(nil) }
}

/// Every name installed apps are shown by, for `NeverWatchImportExclusions`: the localized `CFBundleName` (what the
/// application menu shows), the localized and plain `CFBundleDisplayName` and `CFBundleName`, and the bundle's file
/// name. Looked up on the main actor when each import starts (`RecordingsImportModel.startImport`); the importer then
/// reads the frozen, Sendable table off the main actor. An app added to Never watch during an import is matched by
/// bundle id until the next import.
public enum LiveAppNames {
  @MainActor public static func resolver(for bundleIDs: [String]) -> @Sendable (String) -> [String] {
    var names: [String: [String]] = [:]
    for id in bundleIDs {
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
      let bundle = Bundle(url: url)
      let localized = bundle?.localizedInfoDictionary
      let plain = bundle?.infoDictionary
      let found = [localized?["CFBundleName"], localized?["CFBundleDisplayName"], plain?["CFBundleDisplayName"],
                   plain?["CFBundleName"]].compactMap { $0 as? String } + [url.deletingPathExtension().lastPathComponent]
      var seen = Set<String>()
      names[id] = found.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    let frozen = names
    return { frozen[$0] ?? [] }
  }
}

extension RecordingsImportModel {
  /// The app as shipped in this build: the real folder, summary and picker, and no importer yet, because the
  /// on-device OCR and masker arrive with capture (m3-02). Import says so and reads nothing.
  public static func live(neverWatch: NeverWatchStore) -> RecordingsImportModel {
    let fm = FileManager.default
    let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Offload", isDirectory: true)
    return RecordingsImportModel(
      store: UserDefaultsRecordingsFolderStore(), picker: LiveFolderPicker(), panel: LiveImportPanel(), importer: nil,
      sink: nil, ledger: nil, durations: { AVRecordingFrameSource.duration(of: $0) },
      suggestedFolder: RecordingFolder.suggested(home: fm.homeDirectoryForCurrentUser, screencaptureLocation: location),
      protected: support.map { [$0] } ?? [], neverWatch: neverWatch,
      appNames: { LiveAppNames.resolver(for: $0) }
    )
  }
}
