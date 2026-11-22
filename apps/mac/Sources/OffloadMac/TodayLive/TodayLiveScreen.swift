import SwiftUI

// Placeholder from m3-10 (the navigation shell). m3-11 owns this folder and replaces the body with the live Today
// screen; the initialiser stays `TodayLiveScreen(app:)`.

/// Today in the shell: m3-04's TodayView (banners and the honest empty state) until m3-11 lands.
public struct TodayLiveScreen: View {
  @ObservedObject var app: AppModel

  public init(app: AppModel) { self.app = app }

  public var body: some View {
    TodayView(model: app.today, onBanner: { app.tapBanner($0) }, onDismiss: { app.dismissBanner($0) })
  }
}
