import SwiftUI

/// Today's skeleton: banners for the product mode, then the honest empty state. Content lands in m5-05.
public struct TodayView: View {
  let model: TodayModel
  let onBanner: (TodayBanner) -> Void
  let onDismiss: (TodayBanner) -> Void

  public init(model: TodayModel, onBanner: @escaping (TodayBanner) -> Void, onDismiss: @escaping (TodayBanner) -> Void) {
    self.model = model
    self.onBanner = onBanner
    self.onDismiss = onDismiss
  }

  public var body: some View {
    ZStack {
      Theme.paper.ignoresSafeArea()
      VStack(alignment: .leading, spacing: Tokens.Space.s24) {
        Text(model.title)
          .textStyle(Tokens.TypeScale.largeTitle)
          .foregroundStyle(Theme.ink)
          .accessibilityAddTraits(.isHeader)
        ForEach(model.banners) { banner in
          HStack(spacing: Tokens.Space.s12) {
            Text(banner.text).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.chromeInk)
            Spacer()
            if let action = banner.action {
              Button(action) { onBanner(banner) }.buttonStyle(SecondaryButtonStyle())
            }
            Button(OnboardingCopy.dismiss) { onDismiss(banner) }
              .buttonStyle(.plain)
              .foregroundStyle(Theme.chromeMute)
          }
          .chromeCard(padding: Tokens.Space.s16)
          .accessibilityIdentifier(A11yID.todayBanner(banner.id))
        }
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
          Text(model.emptyTitle).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.ink)
          Text(OrphanGuard.glue(model.emptyBody))
            .textStyle(Tokens.TypeScale.body)
            .foregroundStyle(Theme.ink2)
            .accessibilityLabel(model.emptyBody)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.todayEmpty)
        Spacer(minLength: 0)
      }
      .padding(Tokens.Space.s40)
    }
    .frame(minWidth: 720, minHeight: 520)
  }
}

/// "Look at a sample week": labelled sample data, numbers from a fixed synthetic week (no account, no network).
public struct SampleWeekView: View {
  public init() {}
  static let headline = TimeHeadline(totalHours: 31.5, findings: [
    TimeHeadline.Finding(id: "sample-1", hoursFreed: 1.5, arithmetic: "6 times · 15 min each"),
    TimeHeadline.Finding(id: "sample-2", hoursFreed: 1.2, arithmetic: "4 times · 18 min each"),
  ])

  public var body: some View {
    let h = Self.headline
    VStack(alignment: .leading, spacing: Tokens.Space.s16) {
      Text(OnboardingCopy.sampleDataLabel).textStyle(Tokens.TypeScale.caption).foregroundStyle(Theme.needsYou)
      Text(h.headlineWorked).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.chromeInk)
      if let freed = h.headlineFreed {
        Text(freed).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.chromeMute)
      }
      Text(TimeHeadline.mathsTitle).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.cyan)
      ForEach(h.findings) { f in
        HStack(spacing: Tokens.Space.s8) {
          ForEach(TimeHeadline.mathsItems(f.arithmetic), id: \.self) { item in
            Text(item).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .chromeCard()
    .padding(Tokens.Space.s32)
    .background(Theme.paper)
    .frame(minWidth: 520, minHeight: 320)
  }
}
