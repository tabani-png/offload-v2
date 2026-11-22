import Foundation

// The navigation shell's logic: the sidebar's screens, the hand-off from Today and Weekly review to Build progress,
// where the data on a screen comes from, and the rule for the Sample data label. Views are in ShellViews.swift.

/// The sidebar, in order.
public enum Screen: String, CaseIterable, Identifiable, Sendable {
  case today
  case weeklyReview
  case builds
  case recordings
  case settings

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .today: return NavigationCopy.today
    case .weeklyReview: return NavigationCopy.weeklyReview
    case .builds: return NavigationCopy.builds
    case .recordings: return NavigationCopy.recordings
    case .settings: return NavigationCopy.settings
    }
  }

  /// SF Symbols for the sidebar.
  public var symbol: String {
    switch self {
    case .today: return "sun.max"
    case .weeklyReview: return "calendar"
    case .builds: return "hammer"
    case .recordings: return "film.stack"
    case .settings: return "gearshape"
    }
  }
}

/// What Build progress is asked to build: a repeat counted on this Mac, or a cloud opportunity's option.
public enum BuildRequest: Equatable, Sendable {
  case localRepeat(key: String, name: String, minutesPerWeek: Int)
  case opportunity(id: String, optionID: String?)
}

@MainActor
public final class NavigationModel: ObservableObject {
  @Published public var selection: Screen
  /// The hand-off to Build progress; m3-13 reads it once when Builds appears and clears it.
  @Published public var pendingBuild: BuildRequest?
  /// The person asked for the Settings window this launch (the menu bar's Recordings… while setting up). A window macOS
  /// restores at launch shows nothing that reads a folder until then (review 2, finding 3).
  @Published public private(set) var settingsRequested = false

  public func requestSettings() { settingsRequested = true }

  public init(selection: Screen = .today) { self.selection = selection }

  /// Today's and Weekly review's **OK, build**: keeps the request and opens Builds.
  public func startBuild(_ request: BuildRequest) {
    pendingBuild = request
    selection = .builds
  }

  /// Returns the hand-off once and clears it.
  public func takePendingBuild() -> BuildRequest? {
    defer { pendingBuild = nil }
    return pendingBuild
  }
}

/// What the main window shows for a launch route: the shell once setup is done (route Today), else m3-04's
/// MainWindowView (move, Start fresh, onboarding), unchanged.
public enum AppWindowContent: Equatable, Sendable {
  case shell
  case setup

  public static func forRoute(_ route: LaunchRoute) -> AppWindowContent {
    route == .today ? .shell : .setup
  }

}

/// What the Settings window shows: m3-05's Recordings settings once asked for, else a button that asks.
public enum SettingsWindowContent: Equatable, Sendable {
  case waiting
  case recordings

  public static func forRequested(_ requested: Bool) -> SettingsWindowContent { requested ? .recordings : .waiting }
}

/// Where a screen's numbers come from.
public enum DataProvenance: Equatable, Sendable {
  /// A labelled sample: only in `.local` backend mode, never mixed with counted numbers.
  case sample
  /// Counted on this Mac (local insights).
  case onDevice
  /// The brain and builds APIs.
  case cloud

  /// Sample data exists only behind `.local`; in `.cloud` there is none to show.
  public static func sample(in mode: BackendMode) -> DataProvenance? {
    mode.isLocal ? .sample : nil
  }

  /// The label at the top of a screen's content: always visible, first for VoiceOver. Nil for cloud data.
  public var label: String? {
    switch self {
    case .sample: return NavigationCopy.sampleData
    case .onDevice: return NavigationCopy.countedOnThisMac
    case .cloud: return nil
    }
  }

  /// The sample label is a warning, the on-device line a caption.
  public var isWarning: Bool { self == .sample }
}

/// The recordings import is offered in `.local` backend mode (the import stays on this Mac, so the consent it
/// waited for does not apply), and in `.cloud` only while the person is signed in and sending (ONBOARDING section 8).
///
/// In `.local` it also needs the on-device import itself: when its folder could not be set up there is no importer,
/// so Import is not offered and the Recordings screen says why (review 1, finding 10).
public enum RecordingsOffer {
  public static func isOffered(mode: BackendMode, sending: Bool, canImportLocally: Bool = true) -> Bool {
    mode.isLocal ? (canImportLocally || sending) : sending
  }
}

public enum NavigationCopy {
  public static let today = "Today"
  public static let weeklyReview = "Weekly review"
  public static let builds = "Builds"
  public static let recordings = "Recordings"
  public static let settings = "Settings"
  public static let sampleData = "Sample data: cloud not connected"
  public static let countedOnThisMac = "counted on this Mac"
  public static let backendTitle = "Where your data is"
  public static let backendLocal = "on this Mac only"
  public static let backendLocalHelp = "Recordings are read and counted on this Mac. Nothing is sent."
  public static let foldersTitle = "Folders found on this Mac"
  public static let useFolder = "Use this folder"
  public static let weeklyReviewPlaceholder = "Your weekly review shows here."
  public static let buildsPlaceholder = "Builds you start show here."
  public static let reviewSettingsTitle = "Weekly review"
  public static let showRecordingsSettings = "Show recordings settings"
  public static let localImportUnavailable = "Offload couldn't set up its folder on this Mac, so recordings can't be read here yet. Quit and open Offload again to retry."

  /// "connected to api.example.com".
  public static func backendCloud(host: String) -> String { "connected to \(host)" }

  /// The backend mode in words, for Settings.
  public static func backendLine(_ mode: BackendMode) -> String {
    switch mode {
    case .local: return backendLocal
    case .cloud(let config): return backendCloud(host: config.baseURL.host ?? config.baseURL.absoluteString)
    }
  }

  /// A default folder's name for the Recordings screen.
  public static func folderKind(_ kind: RecordingFolderCandidate.Kind) -> String {
    switch kind {
    case .screenwatch: return "screenwatch archive"
    case .folder: return "screenwatch folder"
    case .screenRecordings: return "where screen recordings are saved"
    case .desktop: return "Desktop"
    case .movies: return "Movies"
    }
  }

  /// Every string, for the copy tests.
  public static var all: [String] {
    Screen.allCases.map(\.title) + [
      sampleData, countedOnThisMac, backendTitle, backendLocal, backendLocalHelp, foldersTitle, useFolder,
      weeklyReviewPlaceholder, buildsPlaceholder, reviewSettingsTitle, showRecordingsSettings, localImportUnavailable,
      backendCloud(host: "api.example.com"),
    ] + [RecordingFolderCandidate.Kind.screenwatch, .folder, .screenRecordings, .desktop, .movies].map(folderKind)
  }

  /// Captions: lowercase (the proper noun "Mac" aside), facts as separate `·` items.
  public static var captions: [String] { [countedOnThisMac, backendLocal, backendCloud(host: "api.example.com")] }
}
