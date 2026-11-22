import Foundation

// The one line the menu bar item shows above m3-04's menu: "today · 3 h 10 m · mostly Xcode". Nil when nothing was
// counted today, and then the menu shows no line.

public enum TodayMenuSummary {
  /// From local insights; `day` is today's label (YYYY-MM-DD in the insights' time zone).
  public static func line(snapshot: InsightsSnapshot, day: String) -> String? {
    guard let d = snapshot.day(day), d.activeSeconds.value > 0 else { return nil }
    let top = d.topApps.first.flatMap { $0.appBundleID == LocalInsights.excludedAppID ? nil : $0.appName }
    return TodayCopy.menuLine(minutes: TodayCopy.minutes(seconds: d.activeSeconds.value), app: top)
  }

  /// From the brain's record of today (`by_app` names bundle ids, not names, so the line has no app).
  public static func line(record: DayRecord) -> String? {
    let v = record.totals.activeMinutes.value
    guard v > 0 else { return nil }
    return TodayCopy.menuLine(minutes: max(1, Int(v.rounded())), app: nil)
  }
}
