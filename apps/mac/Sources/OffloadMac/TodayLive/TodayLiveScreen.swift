import SwiftUI

// m3-11: the live Today screen replaces m3-10's placeholder; the initialiser stays `TodayLiveScreen(app:)`.

/// Today in the shell: m3-04's banners, then the day, counted on this Mac (`.local`) or read from the brain (`.cloud`).
public struct TodayLiveScreen: View {
  @ObservedObject var app: AppModel

  public init(app: AppModel) { self.app = app }

  public var body: some View {
    TodayLiveView(app: app, model: TodayLiveModel.shared(for: app))
  }
}

/// The menu bar item's line ("today · 3 h 10 m · mostly Xcode"), drawn above m3-04's menu content; nothing when
/// nothing was counted today. In `.cloud` the model reads today's record for it itself (review 1, finding 5).
public struct TodayMenuLine: View {
  @ObservedObject var model: TodayLiveModel

  public init(app: AppModel) { self.model = TodayLiveModel.shared(for: app) }

  public var body: some View {
    if let line = model.menuLine {
      // Read again (at most once a minute) whenever the menu shows the line; the model also reads once at launch.
      Text(line).monospacedDigit().task { await model.refreshMenuLine() }
      Divider()
    }
  }
}
