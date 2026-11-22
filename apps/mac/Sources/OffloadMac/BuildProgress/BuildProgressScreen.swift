import SwiftUI

// Build progress (SPEC m3-13; mockups "4. Build progress"), m3-10's entry point with the same initialiser. The list of
// builds started on this Mac on the left and the selected build on the right. In `.local` the only row is the
// labelled sample, with "Sample data: cloud not connected" first above it; in `.cloud` the builds API. The hand-off
// from Today and Weekly review (`navigation.pendingBuild`) is read once when the screen appears and cleared.

public struct BuildProgressScreen: View {
  @ObservedObject var app: AppModel
  @ObservedObject var navigation: NavigationModel
  @StateObject private var model: BuildProgressModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(app: AppModel) {
    self.app = app
    self.navigation = app.navigation
    _model = StateObject(wrappedValue: BuildProgressModel(backends: app.backends, store: UserDefaultsBuildRecordStore()))
  }

  public var body: some View {
    HStack(spacing: 0) {
      BuildsListView(model: model)
      Rectangle().fill(Theme.rule).frame(width: 1).accessibilityHidden(true)
      ScrollView {
        VStack(alignment: .leading, spacing: Tokens.Space.s16) {
          // The label is first, above everything the sample shows, and stays there.
          ProvenanceLabel(model.provenance)
          if let notice = model.notice {
            Text(notice).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("builds.notice")
          }
          if let line = model.connectionLine {
            Text(line).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
              .accessibilityIdentifier("builds.connection")
          }
          if let plan = model.plan {
            PlanPanelView(model: model, plan: plan)
          }
          if let detail = model.detail {
            BuildDetailView(model: model, detail: detail, reduceMotion: reduceMotion)
            if model.isLocal {
              Button(BuildCopy.replay) { model.replaySample() }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("builds.replay")
            }
          } else if let row = model.builds.first(where: { $0.id == model.selected }), row.canRemove {
            Text(BuildCopy.gone).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
          }
        }
        .padding(Tokens.Space.s32)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .background(Theme.paper)
    .onAppear {
      model.reduceMotion = reduceMotion
      model.appear(navigation: navigation)
    }
    .onDisappear { model.disappear() }
    .onChange(of: navigation.pendingBuild) { _, pending in
      // A hand-off while Builds is already showing.
      if pending != nil { model.appear(navigation: navigation) }
    }
    .onChange(of: reduceMotion) { _, reduce in
      model.reduceMotion = reduce
      if reduce { model.replaySample() }
    }
  }
}
