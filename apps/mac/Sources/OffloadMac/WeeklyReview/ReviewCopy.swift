import Foundation

// Every string of the weekly review screen, its Settings section and its notification, so the copy tests see them.
// Facts are separate items, never one middle-dot string; views draw the dots. Captions are lowercase.

public enum ReviewCopy {
  static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

  // MARK: Title and subtitle

  /// "Nov 9" (the week's Monday).
  static func monday(_ week: ISOWeek) -> String {
    let c = LocalDays.calendar(week.timeZone).dateComponents([.month, .day], from: week.from)
    let month = months[max(0, min(11, (c.month ?? 1) - 1))]
    return "\(month) \(c.day ?? 1)"
  }

  /// "Week of Nov 9".
  public static func weekOf(_ week: ISOWeek) -> String { "Week of \(monday(week))" }
  /// The empty state's way to the latest week with data: "See the week of Oct 5".
  public static func seeWeek(_ week: ISOWeek) -> String { "See the week of \(monday(week))" }

  public static let reviewItem = "review"
  public static func titleItems(_ week: ISOWeek) -> [String] { [weekOf(week), reviewItem] }
  /// "Week of Nov 9 · review".
  public static func title(_ week: ISOWeek) -> String { titleItems(week).joined(separator: " \u{00B7} ") }

  public static func weeksKnownItem(_ n: Int) -> String { "week \(n) of what Offload knows about you" }
  public static let everyNumberOpens = "every number opens to how it was counted"

  // MARK: Sentences (a closed set; numbers come from Figures)

  public static func grew(_ name: String, weeks: String) -> String { "\(name) grew \(weeks) weeks in a row." }
  public static func firstWeekSentence(hours: String) -> String { "Your first week: \(hours) h of work." }
  public static func aboutUsual(hours: String) -> String { "You worked \(hours) h, about your usual." }
  public static func moreThanUsual(hours: String, percent: String) -> String {
    "You worked \(hours) h, \(percent)% more than your usual."
  }
  public static func lessThanUsual(hours: String, percent: String) -> String {
    "You worked \(hours) h, \(percent)% less than your usual."
  }
  /// When no template can be filled from the figures.
  public static let sentenceFallback = "Here is your week."

  // MARK: Tiles

  public static let activeLabel = "Active"
  public static let deepWorkLabel = "Deep work"
  public static let switchesLabel = "Switches / hour"
  public static let savedLabel = "Saved by fixes"
  public static let focusLabel = "Focus"
  public static let meetingsLabel = "Meetings"
  public static let noFixesYet = "no fixes yet"
  public static let firstWeek = "first week"
  public static let sameAsUsual = "same as your usual"
  public static let newThisWeek = "new this week"

  /// The brain's tiles by position: hours, focus minutes, meeting hours, switches per active hour.
  public static let cloudTileLabels = [activeLabel, focusLabel, meetingsLabel, switchesLabel]

  /// A label for a tile past the brain's four, from its unit.
  public static func unitLabel(_ unit: String) -> String {
    switch unit {
    case "hours": return "Hours"
    case "minutes": return "Minutes"
    case "per_hour": return "Per hour"
    default: return "Count"
    }
  }

  /// "−2", "+6", "0" (true minus sign).
  public static func signedPercent(_ p: Int) -> String {
    p < 0 ? "\u{2212}\(-p)" : (p > 0 ? "+\(p)" : "0")
  }

  /// "−2% vs your usual"; 0 reads "same as your usual".
  public static func vsUsual(percent p: Int) -> String { p == 0 ? sameAsUsual : "\(signedPercent(p))% vs your usual" }

  /// "down 3 weeks running".
  public static func running(up: Bool, weeks: Int) -> String { "\(up ? "up" : "down") \(weeks) weeks running" }

  // MARK: Goals

  public static let goalsTitle = "Your goals"
  public static let notLinkedYet = "not linked yet"
  public static let drifting = "drifting"

  /// ["↑ 4 weeks"], or ["↓ 3 weeks", "drifting"].
  public static func goalTrendItems(up: Bool, weeks: Int) -> [String] {
    let word = weeks == 1 ? "week" : "weeks"
    return up ? ["\u{2191} \(weeks) \(word)"] : ["\u{2193} \(weeks) \(word)", drifting]
  }

  // MARK: Questions

  public static let questionsTitle = "A few questions"
  public static let tunesNextWeek = "each answer tunes next week"

  /// ["2 of 4 answered", "each answer tunes next week"].
  public static func counterItems(answered: Int, total: Int) -> [String] { ["\(answered) of \(total) answered", tunesNextWeek] }

  /// "Is Xcode, then Slack part of ship a product?" (the goal's first letter lowercased unless it starts a word in
  /// capitals, so "API v2" stays).
  public static func goalQuestion(repeat name: String, goal: String) -> String { "Is \(name) part of \(lowerFirst(goal))?" }
  public static func buildQuestion(repeat name: String) -> String { "Build something for \(name) next?" }
  public static func cloudQuestion(name: String) -> String { "What next for \(name)?" }

  /// "Top repeat: 145 min/week, 3 of 4 weeks." (the first question), "60 min/week, 1 of 1 week." (the others).
  public static func whyLine(top: Bool, minutesPerWeek: Int, present: Int, observed: Int) -> String {
    (top ? "Top repeat: " : "") + "\(minutesPerWeek) min/week, \(present) of \(observed) \(observed == 1 ? "week" : "weeks")."
  }

  public static let yes = "Yes"
  public static let no = "No"
  public static let anotherGoal = "It's for another goal"
  public static let okBuild = "OK, build"
  public static let notNow = "Not now"
  public static let never = "Never"
  public static let keep = "Keep"
  public static let leaveAlone = "Leave it alone"
  public static let whichGoal = "Which goal?"

  /// The brain's opportunity answers by name; nil for answers the review does not offer.
  public static func chipLabel(_ answer: ReviewAnswerKind) -> String? {
    switch answer {
    case .keep: return keep
    case .notNow: return notNow
    case .build: return okBuild
    case .never: return never
    case .leaveAlone: return leaveAlone
    case .otherGoal: return anotherGoal
    default: return nil
    }
  }

  public static let queued = "queued"
  public static let sameBuildScreen = "same build screen as today"
  public static let buildNoteItems = [queued, sameBuildScreen]
  public static let neverNote = "it won't come back unless the hours rise by half"

  public static let pickGoal = "Pick the goal it's for."
  public static let answerFailed = "Your answer wasn't saved. Try again."

  // MARK: States

  public static let loading = "Loading your review."
  public static let empty = "Nothing counted this week yet."
  public static let chooseRecordings = "Choose recordings"
  /// "Your review for this week lands Friday at 4:00 PM."
  public static func notYet(_ slot: ReviewSlot) -> String { "Your review for this week lands \(slot.long)." }
  public static let tryAgain = "Try again"
  public static let failedOffline = "Offload can't reach the internet right now. Your review loads when this Mac is back online."
  public static let failedSignedOut = "This Mac is signed out of Offload. Sign in again to see your review."
  public static let failedBusy = "Offload is busy right now. Try again in a minute."
  public static let failedServer = "Offload had a problem loading your review. Try again in a minute."
  public static let failedOther = "Your review couldn't be loaded."
  public static let previousWeek = "Previous week"
  public static let nextWeek = "Next week"
  public static let howCounted = "How it was counted"

  // MARK: Settings and the notification

  public static let slotTitle = "Review slot"
  public static let dayLabel = "Day"
  public static let timeLabel = "Time"
  public static let notifyToggle = "Tell me when my review is ready"
  public static let notifyHelp = "One notification a week, at your review slot. It says only that your review is ready."
  public static let notificationsOff = "Notifications are off for Offload in System Settings."
  public static let slotSaveFailed = "The review slot wasn't saved. Try again."
  public static let notificationTitle = "Offload"
  public static let notificationBody = "Your weekly review is ready."

  static func lowerFirst(_ s: String) -> String {
    guard let first = s.first, first.isUppercase else { return s }
    let second = s.dropFirst().first
    if let second, second.isUppercase { return s }
    return first.lowercased() + s.dropFirst()
  }

  /// Every fixed string and samples of the built ones, for the copy tests.
  public static var all: [String] {
    let slot = ReviewSlot(day: .fri, time: "16:00", timeZone: TimeZone(identifier: "UTC") ?? .current)
    let week = ISOWeek(containing: Date(timeIntervalSince1970: 1_795_348_800), timeZone: slot.timeZone)
    return [
      title(week), reviewItem, weeksKnownItem(8), everyNumberOpens,
      grew("Xcode, then Slack", weeks: "3"), firstWeekSentence(hours: "41.2"), aboutUsual(hours: "41.2"),
      moreThanUsual(hours: "41.2", percent: "12"), lessThanUsual(hours: "41.2", percent: "12"), sentenceFallback,
      activeLabel, deepWorkLabel, switchesLabel, savedLabel, focusLabel, meetingsLabel, noFixesYet, firstWeek, sameAsUsual,
      newThisWeek, unitLabel("hours"), unitLabel("count"), vsUsual(percent: -2), vsUsual(percent: 6), running(up: false, weeks: 3),
      running(up: true, weeks: 4), goalsTitle, notLinkedYet, questionsTitle,
      goalQuestion(repeat: "Xcode, then Slack", goal: "Ship a product"), buildQuestion(repeat: "Xcode, then Slack"),
      cloudQuestion(name: "Reconcile invoices"), whyLine(top: true, minutesPerWeek: 145, present: 3, observed: 4),
      whyLine(top: false, minutesPerWeek: 60, present: 1, observed: 1), yes, no, anotherGoal, okBuild, notNow, never, keep,
      leaveAlone, whichGoal, neverNote, pickGoal, answerFailed, loading, empty, chooseRecordings, seeWeek(week), notYet(slot), tryAgain,
      failedOffline, failedSignedOut, failedBusy, failedServer, failedOther, previousWeek, nextWeek, howCounted, slotTitle,
      dayLabel, timeLabel, notifyToggle, notifyHelp, notificationsOff, slotSaveFailed, notificationTitle, notificationBody,
    ] + goalTrendItems(up: true, weeks: 4) + goalTrendItems(up: false, weeks: 3) + counterItems(answered: 2, total: 4)
      + buildNoteItems
  }

  /// Captions: lowercase (the proper nouns Mac and Offload aside), facts as separate items.
  public static var captions: [String] {
    [reviewItem, weeksKnownItem(8), everyNumberOpens, noFixesYet, firstWeek, sameAsUsual, newThisWeek,
     vsUsual(percent: -2), vsUsual(percent: 6), running(up: false, weeks: 3), notLinkedYet, drifting, tunesNextWeek,
     neverNote]
      + goalTrendItems(up: true, weeks: 4) + counterItems(answered: 2, total: 4) + buildNoteItems
  }
}
