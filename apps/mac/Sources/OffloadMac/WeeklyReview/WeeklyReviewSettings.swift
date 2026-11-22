import SwiftUI

// Placeholder from m3-10 (Settings places it). m3-12 owns this file and fills in the review slot and the notification
// toggle; the initialiser stays `WeeklyReviewSettings(app:)`.

public struct WeeklyReviewSettings: View {
  @ObservedObject var app: AppModel

  public init(app: AppModel) { self.app = app }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      Text(NavigationCopy.reviewSettingsTitle).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      Text(NavigationCopy.weeklyReviewPlaceholder).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
    }
  }
}
