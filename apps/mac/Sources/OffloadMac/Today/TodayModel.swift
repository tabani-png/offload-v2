import Foundation

/// One calm line at the top of Today.
public struct TodayBanner: Equatable, Sendable, Identifiable {
  public static let finishSettingUpID = "finish-setting-up"
  public static let localID = "local"
  public static let modeID = "mode"

  public var id: String
  public var text: String
  /// The one button, if any.
  public var action: String?
}

/// Today's skeleton (m5-05 fills it): the honest empty state and the banners the product mode calls for. No number
/// here is invented: with no counted hours, the headline is the headline only.
public struct TodayModel: Equatable, Sendable {
  public var title = OnboardingCopy.todayTitle
  public var emptyTitle = OnboardingCopy.todayEmptyTitle
  public var emptyBody = OnboardingCopy.todayEmptyBody
  public var headline: TimeHeadline
  public var mode: ProductMode
  public var banners: [TodayBanner]

  public init(state: OnboardingState, now: Date, headline: TimeHeadline = TimeHeadline(totalHours: 0, findings: [])) {
    self.headline = headline
    self.mode = state.mode
    var b: [TodayBanner] = []
    if !state.completed {
      b.append(TodayBanner(id: TodayBanner.finishSettingUpID, text: OnboardingCopy.finishSettingUp, action: OnboardingCopy.continueSetup))
    }
    switch state.mode {
    case .local:
      b.append(state.signedIn
        ? TodayBanner(id: TodayBanner.localID, text: OnboardingCopy.bannerStartSending, action: OnboardingCopy.startSending)
        : TodayBanner(id: TodayBanner.localID, text: OnboardingCopy.bannerSignIn, action: OnboardingCopy.signIn))
    case .textOnly:
      b.append(TodayBanner(id: TodayBanner.modeID, text: OnboardingCopy.screenReadingOff, action: OnboardingCopy.turnOn))
    case .screenOnly:
      b.append(TodayBanner(id: TodayBanner.modeID, text: OnboardingCopy.windowDetailsOff, action: OnboardingCopy.turnOn))
    case .connectedAppsOnly:
      b.append(TodayBanner(id: TodayBanner.modeID, text: OnboardingCopy.connectedAppsOnly, action: nil))
    case .full, .watching, .dormant:
      break
    }
    self.banners = b.filter { state.reask.bannerVisible($0.id, now: now) }
  }
}
