import SwiftUI

// Placeholder from m3-10 (the navigation shell). m3-13 owns this folder and replaces the body with Build progress,
// which reads `app.navigation.pendingBuild`; the initialiser stays `BuildProgressScreen(app:)`.

public struct BuildProgressScreen: View {
  @ObservedObject var app: AppModel

  public init(app: AppModel) { self.app = app }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s16) {
      Text(NavigationCopy.builds).textStyle(Tokens.TypeScale.largeTitle).foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      Text(NavigationCopy.buildsPlaceholder).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
      Spacer(minLength: 0)
    }
    .padding(Tokens.Space.s40)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Theme.paper)
  }
}
