import SwiftUI

// The weekly review's Settings section (m3-10's Settings screen places it): the review slot with a day picker and an
// hour-and-minute picker, and the toggle "Tell me when my review is ready". Views only: ReviewSettingsModel and
// ReviewScheduler decide.

public struct WeeklyReviewSettings: View {
  @ObservedObject var app: AppModel

  public init(app: AppModel) { self.app = app }

  public var body: some View {
    ReviewSettingsSection(settings: app.weeklyReview.settings, scheduler: app.weeklyReview.settings.scheduler)
  }
}

struct ReviewSettingsSection: View {
  @ObservedObject var settings: ReviewSettingsModel
  @ObservedObject var scheduler: ReviewScheduler

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s12) {
      Text(NavigationCopy.reviewSettingsTitle).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s12) {
        Text(ReviewCopy.slotTitle).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.ink)
        Text(settings.slotText).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
          .accessibilityIdentifier("settings.reviewSlot")
      }
      HStack(spacing: Tokens.Space.s16) {
        Picker(ReviewCopy.dayLabel, selection: Binding<Weekday>(
          get: { settings.slot.day },
          set: { day in
            let time = settings.slot.time
            Task { await settings.setSlot(day: day, time: time) }
          }
        )) {
          ForEach(Weekday.allCases, id: \.self) { Text($0.full).tag($0) }
        }
        .frame(maxWidth: 220)
        DatePicker(ReviewCopy.timeLabel, selection: Binding<Date>(
          get: { SlotClock.date(hour: settings.slot.hour, minute: settings.slot.minute) },
          set: { date in
            let day = settings.slot.day
            let time = SlotClock.time(of: date)
            Task { await settings.setSlot(day: day, time: time) }
          }
        ), displayedComponents: .hourAndMinute)
        .frame(maxWidth: 200)
      }
      Toggle(ReviewCopy.notifyToggle, isOn: Binding<Bool>(
        get: { scheduler.isOn },
        set: { on in Task { await settings.setNotify(on) } }
      ))
      .toggleStyle(.switch)
      Text(ReviewCopy.notifyHelp).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
      if let line = scheduler.line {
        Text(line).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink)
      }
      if let error = settings.error {
        Text(error).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink)
      }
    }
    .foregroundStyle(Theme.ink)
    .task { await settings.load() }
  }
}

/// The time picker's value: today at the slot's hour and minute on this Mac's clock, and back.
enum SlotClock {
  static func date(hour: Int, minute: Int) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
  }

  static func time(of date: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return ReviewSlot.time(hour: c.hour ?? 16, minute: c.minute ?? 0)
  }
}
