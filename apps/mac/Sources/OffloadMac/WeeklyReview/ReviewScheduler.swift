import Foundation

/// Keeps exactly one repeating weekly notification at the review slot while the setting is on (SPEC m3-12 Contract).
/// macOS is asked only while its answer is not known; a refusal turns the setting off with a line, and is never asked
/// about again from here (the person changes it in System Settings).
@MainActor
public final class ReviewScheduler: ObservableObject {
  public nonisolated static let notificationID = "ai.offload.weekly-review"

  @Published public private(set) var isOn: Bool
  /// "Notifications are off for Offload in System Settings." after a refusal.
  @Published public private(set) var line: String?

  private let notifier: any ReviewNotifier
  private let store: any ReviewSettingsStore
  private let slot: @MainActor () -> ReviewSlot

  public init(notifier: any ReviewNotifier, store: any ReviewSettingsStore, slot: @escaping @MainActor () -> ReviewSlot) {
    self.notifier = notifier
    self.store = store
    self.slot = slot
    isOn = store.notify
  }

  /// The trigger: weekday (Sunday 1 … Saturday 7), hour and minute of the slot, repeating.
  public nonisolated static func trigger(for slot: ReviewSlot) -> DateComponents {
    DateComponents(hour: slot.hour, minute: slot.minute, weekday: slot.day.calendarWeekday)
  }

  /// At launch: a setting left on is scheduled again while macOS allows it, else turned off. Nothing is asked.
  public func start() async {
    guard store.notify else {
      isOn = false
      return
    }
    switch await notifier.authorization() {
    case .authorized:
      isOn = true
      line = nil
      await reschedule()
    case .denied:
      await refused()
    case .notDetermined:
      store.notify = false
      isOn = false
    }
  }

  /// The toggle "Tell me when my review is ready".
  public func setOn(_ on: Bool) async {
    guard on else {
      store.notify = false
      isOn = false
      line = nil
      await notifier.remove(id: Self.notificationID)
      return
    }
    var status = await notifier.authorization()
    if status == .notDetermined {
      status = await notifier.requestAuthorization() ? .authorized : .denied
    }
    guard status == .authorized else {
      await refused()
      return
    }
    store.notify = true
    isOn = true
    line = nil
    await reschedule()
  }

  /// The slot changed: the one notification moves with it.
  public func slotChanged() async {
    guard isOn else { return }
    await reschedule()
  }

  private func refused() async {
    store.notify = false
    isOn = false
    line = ReviewCopy.notificationsOff
    await notifier.remove(id: Self.notificationID)
  }

  private func reschedule() async {
    await notifier.remove(id: Self.notificationID)
    await notifier.schedule(at: Self.trigger(for: slot()), id: Self.notificationID)
  }
}
