import SwiftUI

// Placeholder from m3-10 (the navigation shell). m3-12 owns this folder and replaces the body with the weekly review;
// the initialiser stays `WeeklyReviewScreen(app:)`.

public struct WeeklyReviewScreen: View {
  @ObservedObject var app: AppModel

  public init(app: AppModel) { self.app = app }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s16) {
      Text(NavigationCopy.weeklyReview).textStyle(Tokens.TypeScale.largeTitle).foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      Text(NavigationCopy.weeklyReviewPlaceholder).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
      Spacer(minLength: 0)
    }
    .padding(Tokens.Space.s40)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Theme.paper)
  }
}
