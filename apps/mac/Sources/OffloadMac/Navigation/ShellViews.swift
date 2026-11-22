import OffloadImport
import SwiftUI

// The main window once setup is done: a sidebar (Today, Weekly review, Builds, Recordings, Settings) and the selected
// screen. Views only: decisions are in Navigation.swift, the models and the copy enums.

/// The main window's content: the shell while the route is Today, else m3-04's MainWindowView (onboarding, move,
/// Start fresh), so onboarding is unchanged.
public struct AppWindowView: View {
  @ObservedObject var app: AppModel

  public init(app: AppModel) { self.app = app }

  public var body: some View {
    switch AppWindowContent.forRoute(app.route) {
    case .shell: ShellView(app: app)
    case .setup: MainWindowView(app: app)
    }
  }
}

/// The sidebar and the selected screen. It presents the Never watch sheet itself, so the menu bar entry works on every
/// screen.
public struct ShellView: View {
  @ObservedObject var app: AppModel
  @ObservedObject var navigation: NavigationModel

  public init(app: AppModel) {
    self.app = app
    self.navigation = app.navigation
  }

  public var body: some View {
    NavigationSplitView {
      List(Screen.allCases, selection: Binding<Screen?>(
        get: { navigation.selection },
        set: { if let s = $0 { navigation.selection = s } }
      )) { screen in
        Label(screen.title, systemImage: screen.symbol)
          .tag(screen)
          .accessibilityIdentifier("sidebar.\(screen.rawValue)")
      }
      .navigationSplitViewColumnWidth(min: 170, ideal: 190)
    } detail: {
      detail(navigation.selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.paper)
    }
    .frame(minWidth: 900, minHeight: 600)
    .preferredColorScheme(.light)
    .sheet(isPresented: $app.showingNeverWatch) {
      NeverWatchSheet(model: app.onboarding, resolveApp: { InstalledApps.bundleID(forName: $0) },
                      done: {
                        app.showingNeverWatch = false
                        // An entry added here applies to the counted days at once, without a new import.
                        app.insights.exclusionsChanged()
                      })
        .preferredColorScheme(.light)
    }
  }

  @ViewBuilder
  func detail(_ screen: Screen) -> some View {
    switch screen {
    case .today: TodayLiveScreen(app: app)
    case .weeklyReview: WeeklyReviewScreen(app: app)
    case .builds: BuildProgressScreen(app: app)
    case .recordings: RecordingsShellScreen(app: app)
    case .settings: SettingsScreen(app: app)
    }
  }
}

/// "Sample data: cloud not connected" (always visible, read first by VoiceOver), or "counted on this Mac", or
/// nothing for cloud data. Screens put it at the top of their content.
public struct ProvenanceLabel: View {
  let provenance: DataProvenance

  public init(_ provenance: DataProvenance) { self.provenance = provenance }

  public var body: some View {
    if let text = provenance.label {
      if provenance.isWarning {
        SampleDataLabel(text: text)
      } else {
        CaptionLine(text).accessibilitySortPriority(1)
      }
    }
  }
}

/// The amber label on every sample screen.
public struct SampleDataLabel: View {
  let text: String

  public init(text: String = NavigationCopy.sampleData) { self.text = text }

  public var body: some View {
    HStack(spacing: Tokens.Space.s8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.needsYou).accessibilityHidden(true)
      Text(text).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.ink)
    }
    .padding(.horizontal, Tokens.Space.s12)
    .padding(.vertical, Tokens.Space.s8)
    .background(RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(Theme.needsYou.opacity(0.18)))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(text)
    .accessibilitySortPriority(10)
    .accessibilityIdentifier("provenance.sample")
  }
}

/// Recordings: m3-05's Settings view, the default folders found on this Mac and the local insights done line. Not
/// `RecordingsScreen`: that name is m3-04's onboarding screen 11 in the same module.
public struct RecordingsShellScreen: View {
  @ObservedObject var app: AppModel
  @ObservedObject var insights: InsightsModel

  public init(app: AppModel) {
    self.app = app
    self.insights = app.insights
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.s16) {
        if app.backends.mode.isLocal, app.recordings?.canImport != true {
          Text(NavigationCopy.localImportUnavailable).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
            .padding(.horizontal, Tokens.Space.s24)
        }
        if let recordings = app.recordings {
          RecordingsAnalysisLine(model: recordings, insights: insights, provenance: app.backends.provenance)
          RecordingsSettingsView(model: recordings)
          if let onDevice = app.onDeviceRecordings {
            FolderCandidatesView(onDevice: onDevice, model: recordings, folders: onDevice.folderCandidates)
          }
        } else {
          Text(RecordingsCopy.noImports).padding(Tokens.Space.s24)
        }
      }
      .padding(Tokens.Space.s16)
    }
    .background(Theme.paper)
  }
}

/// The done line with "· 9 things you repeat" and the on-device caption, under the screen's title.
struct RecordingsAnalysisLine: View {
  @ObservedObject var model: RecordingsImportModel
  @ObservedObject var insights: InsightsModel
  /// "counted on this Mac" only when it is (review 2, finding 4).
  let provenance: DataProvenance

  var body: some View {
    let items = AnalysisProgress.items(model, insights: insights)
    VStack(alignment: .leading, spacing: Tokens.Space.s4) {
      ProvenanceLabel(provenance)
      if case .done = model.phase, !items.isEmpty { MetaItemsLine(items: items) }
    }
    .padding(.horizontal, Tokens.Space.s24)
  }
}

/// "Folders found on this Mac", each with "Use this folder".
///
/// The folders are checked (existence only) when this view appears, never at launch (review 1, finding 5).
struct FolderCandidatesView: View {
  let onDevice: OnDeviceRecordings
  @ObservedObject var model: RecordingsImportModel
  @ObservedObject var folders: RecordingFolderCandidates

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      if !folders.candidates.isEmpty {
        Text(NavigationCopy.foldersTitle).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.ink)
          .accessibilityAddTraits(.isHeader)
      }
      ForEach(folders.candidates, id: \.url) { c in
        HStack(spacing: Tokens.Space.s12) {
          Label(c.url.lastPathComponent, systemImage: "folder").textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.ink)
          CaptionLine(NavigationCopy.folderKind(c.kind))
          Spacer()
          if model.folder?.standardizedFileURL != c.url.standardizedFileURL {
            Button(NavigationCopy.useFolder) { Task { await onDevice.use(c) } }
              .buttonStyle(SecondaryButtonStyle())
              .disabled(model.isImporting)
              .accessibilityLabel("\(NavigationCopy.useFolder), \(c.url.lastPathComponent)")
          }
        }
      }
    }
    .padding(.horizontal, Tokens.Space.s24)
    .onAppear { folders.refresh() }
  }
}

/// Settings: the backend mode in words, Recordings, and the weekly review section (m3-12 fills it).
public struct SettingsScreen: View {
  @ObservedObject var app: AppModel

  public init(app: AppModel) { self.app = app }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.s24) {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
          Text(NavigationCopy.backendTitle).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
          CaptionLine(NavigationCopy.backendLine(app.backends.mode))
            .accessibilityIdentifier("settings.backend")
          if app.backends.mode.isLocal {
            Text(NavigationCopy.backendLocalHelp).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
          }
        }
        .padding(.horizontal, Tokens.Space.s24)
        if let recordings = app.recordings {
          RecordingsSettingsView(model: recordings)
        }
        WeeklyReviewSettings(app: app)
          .padding(.horizontal, Tokens.Space.s24)
      }
      .padding(.vertical, Tokens.Space.s24)
    }
    .background(Theme.paper)
  }
}

/// The Settings window (m3-05's, opened from the menu bar while setting up). Restored by macOS at launch it shows only
/// a button, so no folder is read before the person asks (review 2, finding 3).
public struct SettingsWindowView: View {
  @ObservedObject var app: AppModel
  @ObservedObject var navigation: NavigationModel

  public init(app: AppModel) {
    self.app = app
    self.navigation = app.navigation
  }

  public var body: some View {
    switch SettingsWindowContent.forRequested(navigation.settingsRequested) {
    case .recordings:
      OffloadSettingsView(app: app)
    case .waiting:
      VStack(spacing: Tokens.Space.s16) {
        Text(NavigationCopy.settingsWaitingBody).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
          .multilineTextAlignment(.center)
        Button(NavigationCopy.showRecordingsSettings) { navigation.requestSettings() }
          .buttonStyle(SecondaryButtonStyle())
      }
      .padding(Tokens.Space.s24)
      .frame(minWidth: 520, minHeight: 200)
      .background(Theme.paper)
      .preferredColorScheme(.light)
    }
  }
}
