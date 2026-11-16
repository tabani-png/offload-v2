import Foundation

/// The menu bar item's "Don't watch <app>" entry (ONBOARDING 10.2): the app in front, never Offload itself, never one
/// already excluded. Works without sign-in: it applies on this Mac.
public struct MenuNeverWatchItem: Equatable, Sendable {
  public var title: String
  public var exclusion: Exclusion
}

public enum MenuNeverWatch {
  public static func item(frontmostBundleID: String?, frontmostName: String?, ownBundleID: String?,
                          current: [Exclusion]) -> MenuNeverWatchItem? {
    guard let id = frontmostBundleID, !id.isEmpty, id != ownBundleID else { return nil }
    let exclusion = Exclusion(kind: .bundleID, value: id)
    guard !current.contains(where: { $0.kind == .bundleID && $0.value == id }) else { return nil }
    let name = (frontmostName?.isEmpty == false ? frontmostName : nil) ?? id
    return MenuNeverWatchItem(title: OnboardingCopy.menuDontWatch(name), exclusion: exclusion)
  }
}

/// The menu bar item's one line. It says "not watching yet." unless the observer really runs.
public enum MenuBarStatus {
  public static func line(isCapturing: Bool, waiting: Int) -> String {
    if waiting > 0 { return BuddyMood.foundSomething.line }
    return isCapturing ? BuddyMood.of(observer: .watching, waiting: 0).line : OnboardingCopy.menuNotWatching
  }

  public static func mood(isCapturing: Bool, waiting: Int) -> BuddyMood {
    BuddyMood.of(observer: isCapturing ? .watching : .paused, waiting: waiting)
  }
}
