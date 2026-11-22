import Foundation

/// How the app was asked to run. Test hooks from ONBOARDING section 13: `--onboarding` and
/// `--onboarding-screen <n>`.
public struct LaunchOptions: Equatable, Sendable {
  public var forceOnboarding = false
  public var startScreen: OnboardingScreen?

  public init(forceOnboarding: Bool = false, startScreen: OnboardingScreen? = nil) {
    self.forceOnboarding = forceOnboarding
    self.startScreen = startScreen
  }

  public static func parse(arguments a: [String]) -> LaunchOptions {
    var o = LaunchOptions()
    if a.contains("--onboarding") { o.forceOnboarding = true }
    if let i = a.firstIndex(of: "--onboarding-screen") {
      o.forceOnboarding = true
      if a.indices.contains(i + 1), let n = Int(a[i + 1]), let s = OnboardingScreen(rawValue: n) {
        o.startScreen = s
      }
    }
    return o
  }
}

/// Screen 0: running from the disk image or a translocated path makes updates and permissions unreliable.
public enum InstallLocation {
  public static func needsMove(bundlePath: String) -> Bool {
    guard bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".app/") else { return false }  // `swift build` runs
    return bundlePath.contains("/AppTranslocation/") || bundlePath.hasPrefix("/Volumes/")
  }
}

/// What the app opens on launch (ONBOARDING sections 4 and 11).
public enum LaunchRoute: Equatable, Sendable {
  case moveToApplications
  /// Row 11.6: the local buffer cannot be opened.
  case startFresh
  case onboarding(OnboardingScreen)
  case today

  public static func decide(options: LaunchOptions, state: OnboardingState, bundlePath: String,
                            bufferReadable: Bool, currentNoticeVersion: String?) -> LaunchRoute {
    if InstallLocation.needsMove(bundlePath: bundlePath) { return .moveToApplications }
    if !bufferReadable { return .startFresh }
    if options.forceOnboarding { return .onboarding(options.startScreen ?? .install) }
    // Row 11.11: a new "What leaves your Mac" version shows screen 5 again before uploads continue.
    if state.uploadConsent, let current = currentNoticeVersion, current != state.consentedNoticeVersion {
      return .onboarding(.whatLeaves)
    }
    // Rows 11.1 and 11.8: resume at the saved screen.
    if !state.completed { return .onboarding(state.screen) }
    return .today
  }
}
