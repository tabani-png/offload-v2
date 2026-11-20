import Foundation

/// Where the onboarding state is saved, so quitting and the Screen Recording relaunch resume where they stopped.
public protocol OnboardingStore: AnyObject {
  func load() -> OnboardingState?
  func save(_ state: OnboardingState)
}

/// The app's store: one JSON value in UserDefaults. An unreadable value is treated as a fresh start.
public final class UserDefaultsOnboardingStore: OnboardingStore {
  public static let key = "ai.offload.onboarding.state.v1"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public func load() -> OnboardingState? {
    guard let data = defaults.data(forKey: Self.key) else { return nil }
    return try? JSONDecoder().decode(OnboardingState.self, from: data)
  }

  public func save(_ state: OnboardingState) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    defaults.set(data, forKey: Self.key)
  }
}

/// For tests and previews.
public final class InMemoryOnboardingStore: OnboardingStore {
  private var state: OnboardingState?
  public init(state: OnboardingState? = nil) { self.state = state }
  public func load() -> OnboardingState? { state }
  public func save(_ state: OnboardingState) { self.state = state }
}
