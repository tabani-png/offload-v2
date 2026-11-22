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
/// nothing was counted today. The model reads and recounts for it on its own clock (reviews 1 and 2).
public struct TodayMenuLine: View {
  @ObservedObject var model: TodayLiveModel

  public init(app: AppModel) { self.model = TodayLiveModel.shared(for: app) }

  public var body: some View {
    if let line = model.menuLine {
      // The model keeps the line true itself (menuTick, every minute and at the day change).
      Text(line).monospacedDigit()
      Divider()
    }
  }
}
