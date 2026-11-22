import SwiftUI

// The Weekly review screen (mockup `Weekly`): one sentence about what changed, tiles against your usual week, your
// goals, then up to 4 one-tap questions. No charts. Every tile and goal number opens to its arithmetic. Views only:
// every decision is in WeeklyReviewModel, ReviewContent and ReviewCopy.

public struct WeeklyReviewScreen: View {
  @ObservedObject var app: AppModel

  public init(app: AppModel) { self.app = app }

  public var body: some View {
    WeeklyReviewView(model: app.weeklyReview.review, settings: app.weeklyReview.settings,
                     scheduler: app.weeklyReview.settings.scheduler)
  }
}

struct WeeklyReviewView: View {
  @ObservedObject var model: WeeklyReviewModel
  @ObservedObject var settings: ReviewSettingsModel
  @ObservedObject var scheduler: ReviewScheduler

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.s20) {
        ProvenanceLabel(model.provenance)
        header
        stateBody
        offer
      }
      .padding(Tokens.Space.s32)
      .frame(maxWidth: 900, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Theme.paper)
    .task { await model.followNow() }
  }

  var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s12) {
      HStack(spacing: Tokens.Space.s8) {
        let items = ReviewCopy.titleItems(model.week)
        ForEach(Array(items.enumerated()), id: \.offset) { pair in
          if pair.offset > 0 { Text("\u{00B7}").foregroundStyle(Theme.muted).accessibilityHidden(true) }
          Text(pair.element).foregroundStyle(pair.offset == 0 ? Theme.ink : Theme.muted)
        }
      }
      .textStyle(Tokens.TypeScale.largeTitle)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      Spacer(minLength: Tokens.Space.s16)
      Button { Task { await model.previousWeek() } } label: { Image(systemName: "chevron.left") }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(!model.canGoBack)
        .accessibilityLabel(ReviewCopy.previousWeek)
        .help(ReviewCopy.previousWeek)
      Button { Task { await model.nextWeek() } } label: { Image(systemName: "chevron.right") }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(!model.canGoForward)
        .accessibilityLabel(ReviewCopy.nextWeek)
        .help(ReviewCopy.nextWeek)
    }
  }

  /// The notification, offered on this screen first (ONBOARDING section 12), until it is answered.
  @ViewBuilder
  var offer: some View {
    switch model.state {
    case .ready, .notYet:
      if settings.showsNotificationOffer {
        HStack(spacing: Tokens.Space.s12) {
          Image(systemName: "bell").foregroundStyle(Theme.ink2).accessibilityHidden(true)
          Text(ReviewCopy.offerLine).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: Tokens.Space.s8)
          Button(ReviewCopy.notifyToggle) { Task { await settings.acceptNotificationOffer() } }
            .buttonStyle(PrimaryButtonStyle())
          Button(ReviewCopy.offerDismiss) { settings.dismissNotificationOffer() }
            .buttonStyle(SecondaryButtonStyle())
        }
        .paperCard(padding: Tokens.Space.s16)
      } else if let line = scheduler.line {
        Text(line).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
      }
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  var stateBody: some View {
    switch model.state {
    case .loading:
      HStack(spacing: Tokens.Space.s8) {
        ProgressView().controlSize(.small)
        Text(ReviewCopy.loading).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
      }
    case .empty:
      VStack(alignment: .leading, spacing: Tokens.Space.s16) {
        Text(ReviewCopy.empty).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.ink)
        HStack(spacing: Tokens.Space.s12) {
          Button(ReviewCopy.chooseRecordings) { model.chooseRecordings() }
            .buttonStyle(PrimaryButtonStyle())
          if let latest = model.latestDataWeek {
            Button(ReviewCopy.seeWeek(latest)) { Task { await model.showLatestData() } }
              .buttonStyle(SecondaryButtonStyle())
          }
        }
      }
    case .notYet, .noReview:
      Text(model.stateLine ?? "").textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.ink)
    case .failed:
      VStack(alignment: .leading, spacing: Tokens.Space.s16) {
        Text(model.stateLine ?? "").textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink)
        Button(ReviewCopy.tryAgain) { Task { await model.refresh() } }
          .buttonStyle(SecondaryButtonStyle())
      }
    case .ready:
      if let content = model.content {
        ReviewReadyView(model: model, content: content)
      }
    }
  }
}

/// The review itself, on the mockup's dark stage.
struct ReviewReadyView: View {
  @ObservedObject var model: WeeklyReviewModel
  let content: ReviewContent

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: Tokens.Space.s8) {
        Text(content.sentence)
          .textStyle(Tokens.TypeScale.display)
          .foregroundStyle(Theme.chromeInk)
          .fixedSize(horizontal: false, vertical: true)
        CaptionLine(content.subtitleItems.joined(separator: " \u{00B7} "), onChrome: true)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
        ForEach(content.tiles) { tile in ReviewTileView(tile: tile) }
      }
      if !content.goals.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          Text(ReviewCopy.goalsTitle).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.chromeMute)
            .padding(.bottom, Tokens.Space.s8)
            .accessibilityAddTraits(.isHeader)
          ForEach(content.goals) { goal in ReviewGoalRowView(goal: goal) }
        }
      }
      if !content.questions.isEmpty {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(ReviewCopy.questionsTitle).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.chromeMute)
              .accessibilityAddTraits(.isHeader)
            CaptionLine(content.counterItems.joined(separator: " \u{00B7} "), onChrome: true)
          }
          ForEach(content.questions) { q in
            ReviewQuestionCard(question: q, busy: model.answering.contains(q.subjectKey)) { chip, goalID in
              Task { await model.answer(q, chip, goalID: goalID) }
            }
          }
          if let error = model.answerError {
            Text(error).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.needsYou)
          }
        }
      }
    }
    .chromeCard(padding: Tokens.Space.s24)
  }
}

extension ReviewTone {
  var color: Color {
    switch self {
    case .good: return Theme.done
    case .needsYou: return Theme.needsYou
    case .neutral: return Theme.chromeMute
    }
  }
}

/// A tile: label, value, the line against your usual. Click to see how it was counted.
struct ReviewTileView: View {
  let tile: ReviewTile
  @State private var showing = false

  var body: some View {
    if tile.figures.isEmpty {
      // Nothing to open (Saved by fixes): a plain view, so VoiceOver does not read a dimmed button (review 1).
      card.accessibilityElement(children: .combine)
    } else {
      Button { showing.toggle() } label: { card }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(ReviewCopy.howCounted)
        .popover(isPresented: $showing, arrowEdge: .bottom) { FigureDetailView(figures: tile.figures) }
    }
  }

  var card: some View {
      VStack(alignment: .leading, spacing: 2) {
        Text(tile.label).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
        Text(tile.valueText)
          .font(.system(size: 24, weight: .semibold))
          .tracking(-0.7)
          .monospacedDigit()
          .foregroundStyle(tile.value == nil ? Theme.chromeMute : Theme.chromeInk)
          .padding(.top, 4)
        if let line = tile.deltaLine {
          Text(line).textStyle(Tokens.TypeScale.callout).foregroundStyle(tile.tone.color)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, Tokens.Space.s12)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.chrome2))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.chromeLine))
      .contentShape(Rectangle())
  }
}

/// A goal: text, hours (click for the arithmetic), trend.
struct ReviewGoalRowView: View {
  let goal: GoalRow
  @State private var showing = false

  var body: some View {
    VStack(spacing: 0) {
      Rectangle().fill(Theme.chromeLine).frame(height: 1)
      HStack(spacing: Tokens.Space.s12) {
        Text(goal.text).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.chromeInk)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let hours = goal.hoursText {
          Button { showing.toggle() } label: {
            Text(hours).font(.system(size: 12, design: .monospaced)).monospacedDigit()
              .foregroundStyle(goal.linked ? Theme.chromeInk : Theme.chromeMute)
          }
          .buttonStyle(.plain)
          .disabled(goal.figures.isEmpty)
          .popover(isPresented: $showing, arrowEdge: .bottom) { FigureDetailView(figures: goal.figures) }
        }
        if !goal.trendItems.isEmpty {
          HStack(spacing: Tokens.Space.s4) {
            ForEach(Array(goal.trendItems.enumerated()), id: \.offset) { pair in
              if pair.offset > 0 { Text("\u{00B7}").accessibilityHidden(true) }
              Text(pair.element)
            }
          }
          .textStyle(Tokens.TypeScale.callout)
          .foregroundStyle(goal.tone.color)
          .frame(minWidth: 130, alignment: .leading)
        }
      }
      .padding(.vertical, 9)
    }
    .accessibilityElement(children: .contain)  // keeps the hours button and its "how it was counted" reachable
  }
}

/// One question: the tick, the question, why it is asked, one-tap chips and the note after an answer.
struct ReviewQuestionCard: View {
  let question: WeekQuestion
  let busy: Bool
  let answer: (ReviewChip, String?) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: question.isAnswered ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 16))
        .foregroundStyle(question.isAnswered ? Theme.done : Theme.chromeMute)
        .scaleEffect(question.isAnswered || reduceMotion ? 1.0 : 0.9)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4), value: question.isAnswered)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(question.text).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.chromeInk)
          .fixedSize(horizontal: false, vertical: true)
        if let why = question.whyLine {
          Text(why).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
        }
        // The note sits after the chips on the same line, as the mockup's `k0`.
        HStack(alignment: .center, spacing: Tokens.Space.s8) {
          ChipRow(question: question, busy: busy, answer: answer)
          if !question.noteItems.isEmpty {
            CaptionLine(question.noteItems.joined(separator: " \u{00B7} "), onChrome: true)
          }
        }
        .padding(.top, Tokens.Space.s8)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, Tokens.Space.s12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.chrome2))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(question.isAnswered ? Theme.done.opacity(0.4) : Theme.chromeLine)
    )
    .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Duration.base), value: question.isAnswered)
  }
}

struct ChipRow: View {
  let question: WeekQuestion
  let busy: Bool
  let answer: (ReviewChip, String?) -> Void

  var body: some View {
    HStack(spacing: 6) {
      ForEach(question.chips) { chip in
        if chip.needsGoal {
          Menu {
            ForEach(chip.goalChoices, id: \.id) { goal in
              Button(goal.text) { answer(chip, goal.id) }
            }
          } label: {
            ChipLabel(text: chip.label, on: question.isOn(chip))
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .disabled(busy)
          .help(ReviewCopy.whichGoal)
        } else {
          Button { answer(chip, nil) } label: { ChipLabel(text: chip.label, on: question.isOn(chip)) }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityAddTraits(question.isOn(chip) ? .isSelected : [])
        }
      }
    }
  }
}

struct ChipLabel: View {
  let text: String
  let on: Bool

  var body: some View {
    Text(text)
      .textStyle(Tokens.TypeScale.callout)
      .foregroundStyle(on ? Theme.chrome : Theme.chromeInk)
      .padding(.horizontal, Tokens.Space.s12)
      .padding(.vertical, 5)
      .background(Capsule().fill(on ? Theme.done : Color.clear))
      .overlay(Capsule().strokeBorder(on ? Theme.done : Color.white.opacity(0.16)))
      .contentShape(Capsule())
  }
}

/// How a number was counted: each figure's value and its arithmetic.
struct FigureDetailView: View {
  let figures: [Figure]

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      Text(ReviewCopy.howCounted).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.ink)
      ForEach(Array(figures.enumerated()), id: \.offset) { pair in
        VStack(alignment: .leading, spacing: 2) {
          Text(ReviewFormat.value(pair.element)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink)
          Text(pair.element.arithmetic).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(Tokens.Space.s16)
    .frame(width: 340, alignment: .leading)
  }
}
