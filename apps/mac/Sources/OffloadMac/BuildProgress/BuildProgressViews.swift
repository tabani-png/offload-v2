import SwiftUI

// Build progress's views (mockups source.canvas.tsx "4. Build progress"): the list of builds on the left, the selected
// build on the right (header with the headline and the mono meter, the five step rows with ticks, the workers panel,
// Install and See what changed faded until ready, the saving line). Views only draw what BuildProgressModel and the
// pure types decided.

extension StatusDot {
  var color: Color {
    switch self {
    case .waiting: return Theme.muted.opacity(0.45)
    case .working: return Theme.working
    case .needsYou: return Theme.needsYou
    case .done: return Theme.done
    case .failedCheck: return BuildProgressColors.failed
    }
  }

  var accessibilityWord: String {
    switch self {
    case .waiting: return "waiting"
    case .working: return "working"
    case .needsYou: return "needs you"
    case .done: return "done"
    case .failedCheck: return "failed"
    }
  }
}

enum BuildProgressColors {
  /// A failed check (the mockup's red).
  static let failed = Color(hex: 0xE5484D)
}

struct StatusDotView: View {
  let dot: StatusDot
  var body: some View {
    Circle().fill(dot.color).frame(width: 8, height: 8).accessibilityHidden(true)
  }
}

// MARK: List

public struct BuildsListView: View {
  @ObservedObject var model: BuildProgressModel

  public init(model: BuildProgressModel) { self.model = model }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      Text(NavigationCopy.builds).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
        .padding(.bottom, Tokens.Space.s8)
      if let empty = model.emptyLine {
        Text(empty).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
          ForEach(model.builds) { row in
            BuildRowView(row: row, selected: row.id == model.selected) {
              Task { await model.select(row.id) }
            } remove: {
              model.remove(buildID: row.id)
            }
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(Tokens.Space.s20)
    .frame(width: 260, alignment: .topLeading)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(Theme.paper2)
  }
}

struct BuildRowView: View {
  let row: BuildRow
  let selected: Bool
  let choose: () -> Void
  let remove: () -> Void

  var body: some View {
    Button(action: choose) {
      HStack(alignment: .top, spacing: Tokens.Space.s8) {
        StatusDotView(dot: row.dot).padding(.top, 5)
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
          Text(row.name).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.ink).lineLimit(2)
          Text(row.line).textStyle(Tokens.TypeScale.caption).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
          if let started = row.started {
            Text(started).textStyle(Tokens.TypeScale.caption).foregroundStyle(Theme.muted)
          }
          if row.canRemove {
            Button(BuildCopy.removeFromList, action: remove).buttonStyle(SecondaryButtonStyle())
          }
        }
        Spacer(minLength: 0)
      }
      .padding(Tokens.Space.s8)
      .background(RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(selected ? Color.white : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(row.name), \(row.line)")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

// MARK: Detail

public struct BuildDetailView: View {
  @ObservedObject var model: BuildProgressModel
  let detail: BuildDetail
  let reduceMotion: Bool

  public init(model: BuildProgressModel, detail: BuildDetail, reduceMotion: Bool) {
    self.model = model
    self.detail = detail
    self.reduceMotion = reduceMotion
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s20) {
      header
      HStack(alignment: .top, spacing: Tokens.Space.s20) {
        steps.frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
        workers.frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
      }
      actions
      if let definition = model.installState.definition, !detail.provenance.isWarning {
        DefinitionWordsView(definition: definition)
      }
    }
  }

  var header: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      Text(detail.title).textStyle(Tokens.TypeScale.caption).foregroundStyle(Theme.muted)
      HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s12) {
        StatusDotView(dot: detail.dot)
        Text(detail.headline).textStyle(Tokens.TypeScale.largeTitle).foregroundStyle(Theme.ink)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: Tokens.Space.s12)
        HStack(spacing: Tokens.Space.s8) {
          ForEach(Array(detail.meter.items.enumerated()), id: \.offset) { pair in
            if pair.offset > 0 { Text("·").accessibilityHidden(true) }
            Text(pair.element)
          }
        }
        .font(.system(size: 12, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(detail.meter.atCap ? Theme.needsYou : Theme.muted)
        .accessibilityElement(children: .combine)
      }
      if let note = detail.headlineNote {
        Text(note).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  var steps: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(detail.steps.enumerated()), id: \.offset) { pair in
        StepRowView(step: pair.element, first: pair.offset == 0, reduceMotion: reduceMotion)
      }
    }
  }

  var workers: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      CaptionLine(BuildCopy.workersTitle)
      if detail.workers.isEmpty {
        if detail.attempts.isEmpty {
          Text(BuildCopy.workersWaiting).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
        }
        ForEach(detail.attempts, id: \.ordinal) { a in AttemptRowView(row: a) }
      } else {
        ForEach(detail.workers, id: \.name) { w in SampleWorkerRowView(worker: w, reduceMotion: reduceMotion) }
      }
    }
    .padding(Tokens.Space.s16)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.rule))
  }

  var actions: some View {
    let ready = detail.actions.offerInstall
    return VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      HStack(spacing: Tokens.Space.s8) {
        Button(BuildCopy.install) { Task { await model.install() } }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!model.canInstall)
          .help(model.canInstall ? "" : (model.isLocal ? BuildCopy.installNeedsCloud : BuildCopy.readFirst))
        Button(BuildCopy.seeWhatChanged) { Task { await model.readDefinition() } }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(!model.canReadDefinition)
        if model.canCancel {
          Button(BuildCopy.cancelBuild) { Task { await model.cancel() } }
            .buttonStyle(SecondaryButtonStyle())
        }
        if let saving = detail.saving { CaptionLine(saving.text) }
      }
      .opacity(ready || model.installState.installed != nil ? 1 : 0.4)
      .offset(y: ready || reduceMotion ? 0 : 4)
      .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Duration.slow), value: ready)
      if let line = model.installLine {
        Text(line).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
          .accessibilityIdentifier("builds.installLine")
      }
    }
  }
}

struct StepRowView: View {
  let step: StepRow
  let first: Bool
  let reduceMotion: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !first { Rectangle().fill(Theme.rule).frame(height: 1) }
      HStack(alignment: .top, spacing: Tokens.Space.s12) {
        ZStack {
          RoundedRectangle(cornerRadius: 5).fill(Theme.working).frame(width: 10, height: 10)
            .opacity(step.status == .working ? 1 : 0)
          Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            .opacity(step.status == .done || step.status == .failed ? 1 : 0)
            .scaleEffect(step.status == .done || reduceMotion ? 1 : 0.6)
        }
        .frame(width: 20, height: 20)
        .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Duration.base), value: step.status)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(step.title).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.ink)
          CaptionLine(step.detail)
          ForEach(step.extras, id: \.self) { CaptionLine($0) }
        }
      }
      .padding(.vertical, 9)
      .opacity(step.status == .waiting ? 0.45 : 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(word)
  }

  var symbol: String { step.status == .failed ? "xmark" : "checkmark" }
  var tint: Color { step.status == .failed ? BuildProgressColors.failed : Theme.done }
  var word: String {
    switch step.status {
    case .waiting: return "waiting"
    case .working: return "working"
    case .done: return "done"
    case .failed: return "failed"
    }
  }
}

struct AttemptRowView: View {
  let row: AttemptRow

  var body: some View {
    HStack(spacing: Tokens.Space.s12) {
      StatusDotView(dot: row.dot)
      Text(row.name).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.ink)
      Spacer(minLength: Tokens.Space.s8)
      mark(BuildCopy.frozenLabel, row.frozen)
      mark(BuildCopy.heldOutLabel, row.heldOut)
      Text(row.spend).font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(Theme.muted)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(row.name), \(row.dot.accessibilityWord)")
  }

  func mark(_ label: String, _ m: CheckMark) -> some View {
    HStack(spacing: Tokens.Space.s4) {
      Text(label).textStyle(Tokens.TypeScale.caption).foregroundStyle(Theme.muted)
      Text(m.text).textStyle(Tokens.TypeScale.caption)
        .foregroundStyle(m == .passed ? Theme.done : (m == .failed ? BuildProgressColors.failed : Theme.muted))
    }
  }
}

struct SampleWorkerRowView: View {
  let worker: SampleWorker
  let reduceMotion: Bool

  var body: some View {
    HStack(spacing: Tokens.Space.s8) {
      StatusDotView(dot: dot)
      Text(worker.name).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.ink)
        .frame(minWidth: 120, alignment: .leading)
      Spacer(minLength: Tokens.Space.s4)
      HStack(spacing: 2) {
        ForEach(Array(worker.boxes.enumerated()), id: \.offset) { pair in
          RoundedRectangle(cornerRadius: 2).fill(color(pair.element)).frame(width: 7, height: 10)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Duration.base), value: worker.done)
      Text(worker.countText).font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(Theme.muted)
        .frame(width: 34, alignment: .trailing)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(worker.name), \(worker.countText), \(dot.accessibilityWord)")
  }

  var dot: StatusDot {
    switch worker.state {
    case .waiting: return .waiting
    case .running: return .working
    case .failed: return .failedCheck
    case .passed: return .done
    }
  }

  func color(_ box: SampleBox) -> Color {
    switch box {
    case .passed: return Theme.done
    case .failed: return BuildProgressColors.failed
    case .empty: return Theme.rule
    }
  }
}

struct DefinitionWordsView: View {
  let definition: BuildDefinition

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      Text(BuildCopy.whatItWillDo).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(definition.words.enumerated()), id: \.offset) { pair in
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s8) {
          Text("·").foregroundStyle(Theme.muted).accessibilityHidden(true)
          Text(pair.element).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .paperCard()
  }
}

// MARK: Plan (OK, build)

struct PlanPanelView: View {
  @ObservedObject var model: BuildProgressModel
  let plan: PlanState

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s12) {
      Text(plan.title.isEmpty ? BuildCopy.planTitle : plan.title).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      if let line = plan.line {
        HStack(spacing: Tokens.Space.s8) {
          if case .designing = plan.phase { ProgressView().controlSize(.small) }
          Text(line).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
        }
      }
      if case .ready(let fix) = plan.phase {
        let summary = PlanSummary.make(fix: fix, title: plan.title)
        Text(summary.summary).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
        CaptionLine([summary.estimate, summary.cap].compactMap { $0 }.joined(separator: " · "))
        HStack(spacing: Tokens.Space.s8) {
          Button(BuildCopy.okBuild) { Task { await model.okBuild() } }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canOKBuild)
            .keyboardShortcut(.defaultAction)
          Button(BuildCopy.notNow) { model.dismissPlan() }
            .buttonStyle(SecondaryButtonStyle())
        }
      }
      if let message = plan.message {
        Text(message).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("builds.planMessage")
      }
    }
    .paperCard()
  }
}
