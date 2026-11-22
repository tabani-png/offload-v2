import Foundation
@preconcurrency import UserNotifications

// The weekly review notification (SPEC m3-12 Design note "Notifications"): off by default, one repeating weekly
// request at the review slot, text with no number and no name (it can show on a locked screen). The protocol keeps
// UNUserNotificationCenter out of tests; `LiveReviewNotifier` is never built in tests.

public enum ReviewNotificationStatus: String, Equatable, Sendable {
  case notDetermined
  case denied
  case authorized
}

public protocol ReviewNotifier: Sendable {
  func authorization() async -> ReviewNotificationStatus
  /// Asks macOS (it shows its prompt the first time only); true when allowed.
  func requestAuthorization() async -> Bool
  /// One repeating request on these calendar components, replacing any request with the same id.
  func schedule(at components: DateComponents, id: String) async
  func remove(id: String) async
}

/// For tests: records what was asked, scheduled and removed.
public final class FakeReviewNotifier: ReviewNotifier, @unchecked Sendable {
  private let lock = NSLock()
  private var current: ReviewNotificationStatus
  private let grants: Bool
  private var asked = 0
  private var scheduled = 0
  private var requests: [String: DateComponents] = [:]
  private var removedIDs: [String] = []

  public init(status: ReviewNotificationStatus = .notDetermined, grants: Bool = true) {
    current = status
    self.grants = grants
  }

  /// How many times macOS was asked.
  public var askCount: Int { locked { asked } }
  /// Every `schedule` call so far.
  public var scheduleCount: Int { locked { scheduled } }
  /// The requests waiting, by id.
  public var pending: [String: DateComponents] { locked { requests } }
  public var removed: [String] { locked { removedIDs } }
  public var status: ReviewNotificationStatus { locked { current } }

  public func authorization() async -> ReviewNotificationStatus { status }

  public func requestAuthorization() async -> Bool { ask() }

  public func schedule(at components: DateComponents, id: String) async { add(components, id: id) }

  public func remove(id: String) async { drop(id) }

  private func ask() -> Bool {
    locked {
      asked += 1
      current = grants ? .authorized : .denied
      return grants
    }
  }

  private func add(_ components: DateComponents, id: String) {
    locked {
      scheduled += 1
      requests[id] = components
    }
  }

  private func drop(_ id: String) {
    locked {
      removedIDs.append(id)
      requests[id] = nil
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

/// The app's notifier over `UNUserNotificationCenter`. Outside an app bundle (a `swift run`) it does nothing and reads
/// as denied, because the center needs a bundle.
public struct LiveReviewNotifier: ReviewNotifier {
  /// Called on the main actor when the person clicks the notification.
  let onOpen: @MainActor @Sendable () -> Void

  public init(onOpen: @escaping @MainActor @Sendable () -> Void = {}) { self.onOpen = onOpen }

  static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

  public func authorization() async -> ReviewNotificationStatus {
    guard Self.available else { return .denied }
    return await withCheckedContinuation { (c: CheckedContinuation<ReviewNotificationStatus, Never>) in
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        c.resume(returning: Self.status(settings.authorizationStatus))
      }
    }
  }

  public func requestAuthorization() async -> Bool {
    guard Self.available else { return false }
    return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
        c.resume(returning: granted)
      }
    }
  }

  /// Makes Offload the center's delegate now (before any click can arrive), so the banner shows while Offload is in
  /// front and a click opens Weekly review, also when the click launched Offload.
  public func installPresenter() {
    guard Self.available else { return }
    ReviewNotificationPresenter.shared.install(onOpen)
  }

  public func schedule(at components: DateComponents, id: String) async {
    guard Self.available else { return }
    ReviewNotificationPresenter.shared.install(onOpen)
    let content = UNMutableNotificationContent()
    content.title = ReviewCopy.notificationTitle
    content.body = ReviewCopy.notificationBody
    content.sound = .default
    let request = UNNotificationRequest(identifier: id, content: content,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      UNUserNotificationCenter.current().add(request) { _ in c.resume() }
    }
  }

  public func remove(id: String) async {
    guard Self.available else { return }
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
  }

  static func status(_ s: UNAuthorizationStatus) -> ReviewNotificationStatus {
    switch s {
    case .notDetermined: return .notDetermined
    case .authorized, .provisional: return .authorized
    default: return .denied
    }
  }
}

/// Shows the review notification while Offload is in front, and opens Weekly review when it is clicked. Installed as
/// the center's delegate only when no other delegate is set.
final class ReviewNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
  static let shared = ReviewNotificationPresenter()

  private let lock = NSLock()
  private var open: (@MainActor @Sendable () -> Void)?

  func install(_ onOpen: @escaping @MainActor @Sendable () -> Void) {
    lock.lock()
    open = onOpen
    lock.unlock()
    let center = UNUserNotificationCenter.current()
    if center.delegate == nil { center.delegate = self }
  }

  private func opener() -> (@MainActor @Sendable () -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return open
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
    if response.notification.request.identifier == ReviewScheduler.notificationID, let open = opener() {
      Task { @MainActor in open() }
    }
    completionHandler()
  }
}
