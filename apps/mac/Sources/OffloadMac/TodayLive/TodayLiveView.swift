import SwiftUI

// The live Today screen's views (the mockup's Daily screen): m3-04's paper canvas with the dark chrome card as the
// mockups' Stage. Views only: every decision is in TodayLiveModel, TodayContent, DayGrid and TodayCopy.

struct TodayLiveView: View {
  @ObservedObject var app: AppModel
  @ObservedObject var model: TodayLiveModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(app: AppModel, model: TodayLiveModel) {
    self.app = app
    self.model = model
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.s16) {
        ForEach(model.banners) { banner in
          TodayBannerRow(banner: banner, onTap: { model.tapBanner(banner) }, onDismiss: { model.dismissBanner(banner) })
        }
        if let provenance = model.content?.provenance {
          if provenance == .sample {
            // `.cloud` while the Today API is not live: always visible, read first by VoiceOver.
            SampleDataLabel(text: TodayCopy.sampleTodayAPI)
          } else {
            ProvenanceLabel(provenance)
          }
        }
        VStack(alignment: .leading, spacing: 0) {
          TodayStageBar(model: model)
          VStack(alignment: .leading, spacing: 22) {
            if let line = model.importingLine {
              CaptionLine(line, onChrome: true).accessibilityIdentifier("today.importing")
            }
            stateContent
          }
          .padding(Tokens.Space.s24)
        }
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).fill(Theme.chrome))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).strokeBorder(Theme.chromeLine))
        .shadow(color: Theme.ink.opacity(0.25), radius: 24, x: 0, y: 14)
      }
      .padding(Tokens.Space.s32)
      .frame(maxWidth: 1040, alignment: .leading)
    }
    .background(Theme.paper)
    .task {
      // When the screen appears, then every 60 s while it is visible (the task ends when it goes away).
      await model.refresh()
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(TodayLiveModel.refreshInterval * 1_000_000_000))
        if Task.isCancelled { break }
        await model.tick()
      }
    }
  }

  @ViewBuilder
  var stateContent: some View {
    switch model.state {
    case .empty:
      if model.isLocal {
        TodayEmptyView(choose: { model.chooseRecordings() })
      } else {
        CaptionLine(TodayCopy.loading, onChrome: true)
      }
    case .notRecorded:
      Text(TodayCopy.notRecorded).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.chromeMute)
        .accessibilityIdentifier("today.notRecorded")
    case .failed(let error):
      VStack(alignment: .leading, spacing: Tokens.Space.s12) {
        Text(error.sentence).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.chromeInk)
        Button(TodayCopy.tryAgain) { Task { await model.tryAgain() } }.buttonStyle(ChromeSecondaryButtonStyle())
      }
      .accessibilityIdentifier("today.failed")
    case .importing, .ready:
      if let content = model.content {
        TodayContentView(content: content, model: model, reduceMotion: reduceMotion)
      }
    }
  }
}

/// The Stage's title bar: the day, and the steps to the days before and after.
struct TodayStageBar: View {
  @ObservedObject var model: TodayLiveModel

  var body: some View {
    HStack(spacing: Tokens.Space.s12) {
      Text(model.title).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.chromeInk)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      Button { Task { await model.previousDay() } } label: { Image(systemName: "chevron.left") }
        .buttonStyle(.plain).foregroundStyle(Theme.chromeMute)
        .disabled(!model.canGoBack).opacity(model.canGoBack ? 1 : 0.35)
        .accessibilityLabel(TodayCopy.previousDay)
      Button { Task { await model.nextDay() } } label: { Image(systemName: "chevron.right") }
        .buttonStyle(.plain).foregroundStyle(Theme.chromeMute)
        .disabled(!model.canGoForward).opacity(model.canGoForward ? 1 : 0.35)
        .accessibilityLabel(TodayCopy.nextDay)
    }
    .padding(.horizontal, Tokens.Space.s20)
    .padding(.vertical, Tokens.Space.s12)
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.chromeLine).frame(height: 1) }
  }
}

/// One of m3-04's banners, with its action and dismiss.
struct TodayBannerRow: View {
  let banner: TodayBanner
  let onTap: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: Tokens.Space.s12) {
      Text(banner.text).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.chromeInk)
      Spacer()
      if let action = banner.action {
        Button(action, action: onTap).buttonStyle(ChromeSecondaryButtonStyle())
      }
      Button(OnboardingCopy.dismiss, action: onDismiss).buttonStyle(.plain).foregroundStyle(Theme.chromeMute)
    }
    .chromeCard(padding: Tokens.Space.s16)
    .accessibilityIdentifier(A11yID.todayBanner(banner.id))
  }
}

/// "Nothing counted yet." with Choose recordings.
struct TodayEmptyView: View {
  let choose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      Text(TodayCopy.emptyTitle).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.chromeInk)
      Text(OrphanGuard.glue(TodayCopy.emptyBody)).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.chromeMute)
        .accessibilityLabel(TodayCopy.emptyBody)
      Button(TodayCopy.chooseRecordings, action: choose).buttonStyle(ChromePrimaryButtonStyle())
        .padding(.top, Tokens.Space.s8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("today.empty.live")
  }
}

/// The header, the grid (or Time by kind), What you did, Keeps coming back and the card.
struct TodayContentView: View {
  let content: TodayContent
  @ObservedObject var model: TodayLiveModel
  let reduceMotion: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: Tokens.Space.s8) {
        HowToggle(key: "headline", model: model, reduceMotion: reduceMotion, help: content.headlineFigure.arithmetic) {
          Text(([content.headline] + (content.headlineMost.map { [$0] } ?? [])).joined(separator: " "))
            .textStyle(Tokens.TypeScale.largeTitle).foregroundStyle(Theme.chromeInk).monospacedDigit()
            .multilineTextAlignment(.leading)
        }
        HStack(spacing: Tokens.Space.s8) {
          ForEach(Array(content.subtitleItems.enumerated()), id: \.offset) { pair in
            if pair.offset > 0 { Text("·").foregroundStyle(Theme.chromeMute).accessibilityHidden(true) }
            HowToggle(key: "item-\(pair.offset)", model: model, reduceMotion: reduceMotion, help: pair.element.figure.arithmetic) {
              Text(pair.element.text).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute).monospacedDigit()
            }
          }
        }
        if model.isHowShown("headline") { HowLine(text: TodayCopy.how(content.headlineFigure.arithmetic, weekdays: nil)) }
        ForEach(Array(content.subtitleItems.enumerated()), id: \.offset) { pair in
          if model.isHowShown("item-\(pair.offset)") { HowLine(text: TodayCopy.how(pair.element.figure.arithmetic, weekdays: nil)) }
        }
      }
      if let grid = content.grid {
        DayGridView(grid: grid, reduceMotion: reduceMotion)
      } else if !content.kinds.isEmpty {
        KindsView(kinds: content.kinds, model: model, reduceMotion: reduceMotion)
      }
      HStack(alignment: .top, spacing: Tokens.Space.s16) {
        DidView(rows: content.did, model: model, reduceMotion: reduceMotion)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        RepeatsView(rows: content.repeats, model: model, reduceMotion: reduceMotion)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      if let card = content.fix {
        FixCardView(card: card, model: model)
      }
    }
  }
}

/// A number that opens to how it was counted: quiet by default, one click away (and its arithmetic as the tooltip).
struct HowToggle<Content: View>: View {
  let key: String
  @ObservedObject var model: TodayLiveModel
  let reduceMotion: Bool
  let help: String
  @ViewBuilder let label: () -> Content

  var body: some View {
    Button {
      withAnimation(reduceMotion ? nil : .easeOut(duration: Tokens.Duration.base)) { model.toggleHow(key) }
    } label: {
      label()
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityHint(help)
  }
}

/// "how: …", the arithmetic of a Figure.
struct HowLine: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 11, design: .monospaced))
      .foregroundStyle(Theme.chromeMute)
      .fixedSize(horizontal: false, vertical: true)
      .transition(.opacity)
  }
}

/// The 15-minute cells, the Switch bursts row and the hour axis.
struct DayGridView: View {
  let grid: DayGrid
  let reduceMotion: Bool
  @State private var shown = false

  static let labelWidth: CGFloat = 92

  var body: some View {
    let visible = shown || reduceMotion
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(grid.rows.enumerated()), id: \.offset) { pair in
        let row = pair.element
        HStack(spacing: Tokens.Space.s8) {
          Text(row.name).font(.system(size: 11)).foregroundStyle(Theme.chromeMute).lineLimit(1)
            .frame(width: Self.labelWidth, alignment: .trailing)
          HStack(spacing: 2) {
            ForEach(0..<row.cells.count, id: \.self) { i in
              let on = row.cells[i]
              RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(on ? Color(hex: row.colorHex) : Color.white.opacity(0.05))
                .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12)
                .opacity(visible || !on ? 1 : 0)
                .scaleEffect(visible || !on ? 1 : 0.6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.26)
                  .delay(DayGrid.appearDelay(cell: i, row: pair.offset, reduceMotion: reduceMotion)), value: shown)
            }
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(row))
      }
      HStack(spacing: Tokens.Space.s8) {
        Text(TodayCopy.switchBursts).font(.system(size: 11)).foregroundStyle(Theme.chromeMute)
          .lineLimit(1).frame(width: Self.labelWidth, alignment: .trailing)
        HStack(spacing: 2) {
          ForEach(0..<grid.bursts.count, id: \.self) { i in
            RoundedRectangle(cornerRadius: 2).fill(grid.bursts[i] ? Theme.needsYou : Color.clear)
              .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4)
          }
        }
      }
      .padding(.top, 2)
      .accessibilityHidden(true)
      HStack(spacing: Tokens.Space.s8) {
        Color.clear.frame(width: Self.labelWidth, height: 1)
        HStack(spacing: 0) {
          ForEach(grid.hourLabels, id: \.self) { h in
            Text(h).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.chromeMute)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.top, 2)
      .accessibilityHidden(true)
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.chrome2))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.chromeLine))
    .accessibilityElement(children: .contain)
    .task {
      if !reduceMotion { try? await Task.sleep(nanoseconds: 150_000_000) }
      shown = true
    }
  }

  /// "Xcode, 3 h 10 m" for VoiceOver.
  static func label(_ row: DayGridRow) -> String {
    guard let f = row.figure else { return row.name }
    return "\(row.name), \(TodayCopy.duration(minutes: TodayCopy.minutes(of: f)))"
  }
}

/// Time by kind (`.cloud`, when `GET /v1/today` sent no grid cells).
struct KindsView: View {
  let kinds: [KindRow]
  @ObservedObject var model: TodayLiveModel
  let reduceMotion: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      Text(TodayCopy.timeByKind).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.chromeMute)
      ForEach(kinds) { k in
        VStack(alignment: .leading, spacing: 4) {
          HowToggle(key: "kind-\(k.kind)", model: model, reduceMotion: reduceMotion, help: k.figure.arithmetic) {
            HStack(spacing: Tokens.Space.s8) {
              Circle().fill(Color(hex: k.colorHex)).frame(width: 8, height: 8).accessibilityHidden(true)
              Text(k.kind).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.chromeInk)
              Spacer()
              Text(k.duration).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.chromeMute).monospacedDigit()
            }
          }
          if model.isHowShown("kind-\(k.kind)") { HowLine(text: TodayCopy.how(k.figure.arithmetic, weekdays: nil)) }
        }
      }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.chrome2))
  }
}

/// "What you did".
struct DidView: View {
  let rows: [DidRow]
  @ObservedObject var model: TodayLiveModel
  let reduceMotion: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(TodayCopy.whatYouDid).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.chromeMute)
        .padding(.bottom, Tokens.Space.s8)
      ForEach(rows) { r in
        VStack(alignment: .leading, spacing: 4) {
          HowToggle(key: "did-\(r.id)", model: model, reduceMotion: reduceMotion, help: r.figure.arithmetic) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s12) {
              if let start = r.start {
                Text(start).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.chromeMute)
                  .frame(width: 52, alignment: .leading)
              }
              Text(r.name).font(.system(size: 14)).foregroundStyle(Theme.chromeInk).frame(maxWidth: .infinity, alignment: .leading)
              Text(r.duration).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.chromeMute).monospacedDigit()
            }
          }
          if model.isHowShown("did-\(r.id)") { HowLine(text: TodayCopy.how(r.figure.arithmetic, weekdays: nil)) }
        }
        .padding(.vertical, Tokens.Space.s8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.chromeLine).frame(height: 1) }
      }
    }
  }
}

/// "Keeps coming back this week": name, the Mon to Sun strip, and the count that opens to how it was counted.
struct RepeatsView: View {
  let rows: [RepeatRow]
  @ObservedObject var model: TodayLiveModel
  let reduceMotion: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(TodayCopy.keepsComingBack).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.chromeMute)
        .padding(.bottom, Tokens.Space.s8)
      ForEach(rows) { r in
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 10) {
            Text(r.name).font(.system(size: 14)).foregroundStyle(Theme.chromeInk)
              .frame(maxWidth: .infinity, alignment: .leading)
            if let strip = r.strip {
              HStack(spacing: 3) {
                ForEach(0..<strip.count, id: \.self) { i in
                  RoundedRectangle(cornerRadius: 2)
                    .fill(strip[i] > 0 ? Theme.cyan : Color.white.opacity(0.08))
                    .opacity(strip[i] > 1 ? 1 : (strip[i] == 1 ? 0.65 : 1))
                    .frame(width: 6, height: 14)
                }
              }
              .accessibilityHidden(true)
            }
            HowToggle(key: r.key, model: model, reduceMotion: reduceMotion, help: r.how) {
              Text(r.count).underline(true, pattern: .dot, color: Theme.chromeMute)
                .font(.system(size: 12, design: .monospaced)).monospacedDigit().foregroundStyle(Theme.chromeInk)
            }
            .accessibilityIdentifier("today.repeat.\(r.key).count")
          }
          if model.isHowShown(r.key) { HowLine(text: r.how) }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.chromeLine).frame(height: 1) }
      }
    }
  }
}

/// The one suggested fix: status, title, the numbered options (cloud), OK, build, Not now and Leave it alone, and the
/// keys (only while the card has focus).
struct FixCardView: View {
  let card: FixCard
  @ObservedObject var model: TodayLiveModel
  @FocusState private var focused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Circle().fill(Theme.needsYou).frame(width: 8, height: 8).accessibilityHidden(true)
        CaptionLine(card.status, onChrome: true)
      }
      if let figure = card.figure, card.how != nil {
        HowToggle(key: "fix", model: model, reduceMotion: reduceMotion, help: figure.arithmetic) {
          fixTitle
        }
        .padding(.top, Tokens.Space.s8)
      } else {
        // Nothing to open: plain text, not a dimmed button (review 2, finding 2).
        fixTitle.padding(.top, Tokens.Space.s8)
      }
      if model.isHowShown("fix"), let how = card.how { HowLine(text: how).padding(.top, 4) }
      if !card.options.isEmpty {
        VStack(spacing: 6) {
          ForEach(Array(card.options.enumerated()), id: \.offset) { pair in
            optionRow(pair.element, index: pair.offset)
          }
        }
        .padding(.top, 14)
      }
      HStack(spacing: Tokens.Space.s8) {
        Button(model.primaryLabel ?? TodayCopy.okBuild) { Task { await model.pressPrimary() } }
          .buttonStyle(ChromePrimaryButtonStyle())
          .accessibilityIdentifier("today.fix.primary")
          .disabled(card.isSample).opacity(card.isSample ? 0.5 : 1)
        Button(TodayCopy.notNow) { Task { await model.notNow() } }
          .buttonStyle(ChromeSecondaryButtonStyle())
          .disabled(card.isSample).opacity(card.isSample ? 0.5 : 1)
        if card.options.isEmpty {
          // On the Mac there are no options, so Leave it alone is a button of its own.
          Button(TodayCopy.leaveAlone) { Task { await model.leaveAlone() } }
            .buttonStyle(ChromeSecondaryButtonStyle())
            .disabled(card.isSample).opacity(card.isSample ? 0.5 : 1)
        }
        Spacer()
        Text(TodayCopy.keysHint(count: card.options.count)).font(.system(size: 11, design: .monospaced))
          .foregroundStyle(Theme.chromeMute)
          .accessibilityHidden(true)
      }
      .padding(.top, Tokens.Space.s16)
      if let error = model.answerError {
        Text(error).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.needsYou).padding(.top, Tokens.Space.s8)
      }
    }
    .padding(18)
    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.chrome2))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
      .strokeBorder(focused ? Theme.working : Color.white.opacity(0.12), lineWidth: focused ? 2 : 1))
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    // A click anywhere on the card gives it the keys (review 1, finding 2).
    .onTapGesture { focused = true }
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .defaultFocus($focused, true)
    .onChange(of: focused) { _, isFocused in model.cardFocused = isFocused }
    .onKeyPress(.return) { handle(.return) }
    .onKeyPress(characters: .decimalDigits) { press in
      guard let n = Int(press.characters) else { return .ignored }
      return handle(.digit(n))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("today.fix")
  }

  var fixTitle: some View {
    Text(card.title).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.chromeInk)
      .fixedSize(horizontal: false, vertical: true)
      .multilineTextAlignment(.leading)
  }

  func handle(_ key: TodayKey) -> KeyPress.Result {
    // A key reaches this handler only while focus is on the card or inside it (an option button, by keyboard).
    model.cardFocused = true
    guard model.accepts(key) else { return .ignored }
    Task { await model.handleKey(key) }
    return .handled
  }

  @ViewBuilder
  func optionRow(_ o: FixOptionRow, index: Int) -> some View {
    let selected = model.selectedOption == index
    Button {
      focused = true
      model.selectOption(index)
    } label: {
      HStack(alignment: .center, spacing: Tokens.Space.s12) {
        Text(verbatim: String(o.number)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.chromeMute)
          .frame(width: 20, height: 20)
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: Tokens.Space.s8) {
            Text(o.title).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.chromeInk)
            if o.recommended {
              Text(TodayCopy.recommended).textStyle(Tokens.TypeScale.caption).foregroundStyle(Theme.done)
            }
          }
          if let detail = o.detail { CaptionLine(detail, onChrome: true) }
          // The picked option's saving, with how it was counted: one click away and read by VoiceOver.
          if selected, let how = o.how { HowLine(text: how) }
        }
        Spacer(minLength: Tokens.Space.s8)
        if let saves = o.saves {
          Text(saves).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.chromeMute).monospacedDigit()
            .help(o.saving?.arithmetic ?? "")
        }
      }
      .padding(.horizontal, Tokens.Space.s12)
      .padding(.vertical, 10)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.white.opacity(0.06) : Color.clear))
      .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(selected ? Color.white.opacity(0.12) : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("today.fix.option.\(o.number)")
  }
}

/// The primary button on the dark chrome: a light pill.
struct ChromePrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .textStyle(Tokens.TypeScale.label)
      .foregroundStyle(Theme.chrome)
      .padding(.horizontal, Tokens.Space.s20)
      .padding(.vertical, Tokens.Space.s8 + 2)
      .background(Capsule().fill(Theme.chromeInk))
      .opacity(configuration.isPressed ? 0.85 : 1)
      .modifier(FocusRing())
  }
}

/// Secondary buttons on the dark chrome.
struct ChromeSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .textStyle(Tokens.TypeScale.label)
      .foregroundStyle(Theme.chromeInk)
      .padding(.horizontal, Tokens.Space.s16)
      .padding(.vertical, Tokens.Space.s8 + 2)
      .background(Capsule().strokeBorder(Color.white.opacity(0.18)))
      .opacity(configuration.isPressed ? 0.7 : 1)
      .modifier(FocusRing())
  }
}
