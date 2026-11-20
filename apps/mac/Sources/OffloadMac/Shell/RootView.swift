import SwiftUI

/// The main window's content: the move sheet, Start fresh, onboarding or Today.
public struct MainWindowView: View {
  @ObservedObject var app: AppModel
  @ObservedObject var sampleWeek: SampleWeekFlag

  public init(app: AppModel) {
    self.app = app
    self.sampleWeek = app.sampleWeek
  }

  public var body: some View {
    Group {
      switch app.route {
      case .moveToApplications:
        Notice(title: OnboardingCopy.moveTitle, bodyText: app.moveError ?? OnboardingCopy.moveBody,
               primary: OnboardingCopy.movePrimary, secondary: OnboardingCopy.moveSecondary,
               onPrimary: { app.moveToApplications() }, onSecondary: { app.quit() })
      case .startFresh:
        Notice(title: OnboardingCopy.startFreshBody, bodyText: OnboardingCopy.startFreshNote,
               primary: OnboardingCopy.startFreshPrimary, secondary: OnboardingCopy.menuQuit,
               onPrimary: { app.startFresh() }, onSecondary: { app.quit() })
      case .onboarding:
        OnboardingView(model: app.onboarding, permissions: app.permissions, events: app.events,
                       resolveApp: { InstalledApps.bundleID(forName: $0) })
      case .today:
        TodayView(model: app.today, onBanner: { app.tapBanner($0) }, onDismiss: { app.dismissBanner($0) })
      }
    }
    // The paper canvas has no dark palette yet, so the window stays light (system controls included) rather than
    // mixing dark-mode text into light surfaces. See the SPEC's Scope changes.
    .preferredColorScheme(.light)
    .sheet(isPresented: $sampleWeek.showing) {
      VStack(spacing: 0) {
        SampleWeekView()
        Button(OnboardingCopy.continueTitle) { sampleWeek.showing = false }
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
          .padding(Tokens.Space.s16)
      }
      .background(Theme.paper)
      .preferredColorScheme(.light)
    }
    .sheet(isPresented: $app.showingNeverWatch) {
      NeverWatchSheet(model: app.onboarding, resolveApp: { InstalledApps.bundleID(forName: $0) },
                      done: { app.showingNeverWatch = false })
        .preferredColorScheme(.light)
    }
  }
}

/// A one-decision sheet on the paper canvas (move to Applications, Start fresh).
struct Notice: View {
  let title: String
  let bodyText: String
  let primary: String
  let secondary: String
  let onPrimary: () -> Void
  let onSecondary: () -> Void

  var body: some View {
    ZStack {
      Theme.paper.ignoresSafeArea()
      VStack(alignment: .leading, spacing: Tokens.Space.s20) {
        Text(title).textStyle(Tokens.TypeScale.largeTitle).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
        Text(bodyText).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
        HStack(spacing: Tokens.Space.s12) {
          Spacer()
          Button(secondary, action: onSecondary).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
          Button(primary, action: onPrimary).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
      }
      .padding(Tokens.Space.s40)
      .frame(maxWidth: 640)
    }
    .frame(minWidth: 560, minHeight: 320)
  }
}

/// The menu bar item: an honest status line, open, continue setup, never watch, quit. Pause arrives with the
/// observer (m3-02).
public struct MenuBarContent: View {
  @ObservedObject var app: AppModel
  /// Observed too, so the menu follows setup and Never watch changes made anywhere.
  @ObservedObject private var onboarding: OnboardingModel
  let openWindow: () -> Void

  public init(app: AppModel, openWindow: @escaping () -> Void) {
    self.app = app
    self.onboarding = app.onboarding
    self.openWindow = openWindow
  }

  public var body: some View {
    Text(app.menuLine)
    Divider()
    Button(OnboardingCopy.menuOpen) { openWindow() }
    if !app.onboarding.state.completed {
      Button(OnboardingCopy.menuSetup) {
        app.continueSetup()
        openWindow()
      }
    }
    Divider()
    if let item = app.menuNeverWatchItem {
      Button(item.title) { Task { await app.dontWatch(item.exclusion) } }
    }
    Button(OnboardingCopy.menuNeverWatchMore) {
      app.showNeverWatch()
      openWindow()
    }
    Divider()
    Button(OnboardingCopy.menuQuit) { app.quit() }
      .keyboardShortcut("q")
  }
}

/// The menu bar mark: the buddy's block, lifted only while capture really runs.
public struct MenuBarLabel: View {
  @ObservedObject var app: AppModel
  public init(app: AppModel) { self.app = app }
  public var body: some View {
    let mood = MenuBarStatus.mood(isCapturing: app.isCapturing, waiting: 0)
    Image(systemName: mood == .quiet ? "square.bottomhalf.filled" : "square.tophalf.filled")
      .accessibilityLabel("Offload, \(app.menuLine)")
  }
}
