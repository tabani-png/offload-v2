import SwiftUI

/// The "What leaves your Mac" notice this build shows (API `notice_id`).
public enum WhatLeavesNotice {
  public static let id = "what-leaves-your-mac"
  public static let version = "2026-11-14"
}

/// The onboarding window: paper canvas, one decision per screen, one primary button. Views only draw the models.
public struct OnboardingView: View {
  @ObservedObject var model: OnboardingModel
  @ObservedObject var permissions: PermissionsModel
  let events: LocalEventSource
  let resolveApp: (String) -> String?

  public init(model: OnboardingModel, permissions: PermissionsModel, events: LocalEventSource,
              resolveApp: @escaping (String) -> String?) {
    self.model = model
    self.permissions = permissions
    self.events = events
    self.resolveApp = resolveApp
  }

  public var body: some View {
    let screen = model.flow.screen
    let spec = OnboardingCopy.spec(for: screen, state: model.state)
    ZStack {
      Theme.paper.ignoresSafeArea()
      VStack(alignment: .leading, spacing: Tokens.Space.s24) {
        if screen != .lastTenMinutes {
          Text(OrphanGuard.glue(spec.headline))
            .textStyle(Tokens.TypeScale.largeTitle)
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(spec.headline)
        }
        content(screen, spec: spec)
        Spacer(minLength: 0)
        if let notice = model.notice {
          Text(notice).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
        }
      }
      .padding(Tokens.Space.s40)
      .frame(maxWidth: 820, alignment: .leading)
    }
    .frame(minWidth: 720, minHeight: 600)
    .accessibilityIdentifier(A11yID.screen(screen))
  }

  @ViewBuilder
  private func content(_ screen: OnboardingScreen, spec: ScreenSpec) -> some View {
    switch screen {
    case .install:
      InstallScreen(model: model, spec: spec)
    case .whatItWatches:
      WhatItWatchesScreen(model: model, spec: spec)
    case .permissions:
      PermissionsScreen(model: model, permissions: permissions, spec: spec)
    case .lastTenMinutes:
      LastTenMinutesScreen(model: model, events: events, spec: spec)
    case .signIn:
      SignInScreen(model: model, spec: spec)
    case .whatLeaves:
      WhatLeavesScreen(model: model, spec: spec)
    case .role, .goals, .drains, .rhythm, .handsOn:
      QuestionScreen(model: model, screen: screen, spec: spec, resolveApp: resolveApp)
    case .connectApps:
      ConnectScreen(model: model, spec: spec)
    case .recordings:
      RecordingsScreen(model: model, spec: spec)
    case .done:
      DoneScreen(model: model, spec: spec)
    }
  }
}

/// The button row: one primary (Return), a secondary (Escape) and Skip, the same size as the secondary.
struct ScreenButtons: View {
  let screen: OnboardingScreen
  let spec: ScreenSpec
  var primaryTitle: String?
  var primary: @MainActor () async -> Void
  var secondary: (@MainActor () async -> Void)?
  var skip: (@MainActor () async -> Void)?
  var showBack = true
  var back: (@MainActor () async -> Void)?

  var body: some View {
    HStack(spacing: Tokens.Space.s12) {
      if let back, showBack {
        Button("Back") { Task { await back() } }
          .buttonStyle(SecondaryButtonStyle())
      }
      Spacer()
      if let skip, let title = spec.skipTitle {
        Button(title) { Task { await skip() } }
          .buttonStyle(SecondaryButtonStyle())
          .accessibilityIdentifier(A11yID.skip(screen))
      }
      if let secondary, let title = spec.secondaryTitle {
        Button(title) { Task { await secondary() } }
          .buttonStyle(SecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier(A11yID.secondary(screen))
      }
      Button(primaryTitle ?? spec.primaryTitle) { Task { await primary() } }
        .buttonStyle(PrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(A11yID.primary(screen))
    }
  }
}

// MARK: - Screens 0 and 1

struct InstallScreen: View {
  @ObservedObject var model: OnboardingModel
  let spec: ScreenSpec
  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s24) {
      if let body = spec.body { Text(body).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2) }
      Spacer(minLength: 0)
      ScreenButtons(screen: .install, spec: spec, primary: { await model.perform(.next) }, showBack: false)
    }
  }
}

struct WhatItWatchesScreen: View {
  @ObservedObject var model: OnboardingModel
  let spec: ScreenSpec
  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s24) {
      HStack(alignment: .top, spacing: Tokens.Space.s16) {
        ListCard(title: OnboardingCopy.noticesTitle, symbol: "eye", items: OnboardingCopy.notices)
        ListCard(title: OnboardingCopy.neverKeepsTitle, symbol: "minus.circle", items: OnboardingCopy.neverKeeps)
      }
      if let caption = spec.caption { CaptionLine(caption) }
      Spacer(minLength: 0)
      ScreenButtons(screen: .whatItWatches, spec: spec, primary: { await model.perform(.next) },
                    secondary: { await model.perform(.showSampleWeek) }, back: { await model.perform(.back) })
    }
  }
}

/// A dark floating card with a short list.
struct ListCard: View {
  let title: String
  let symbol: String
  let items: [String]
  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s12) {
      Label(title, systemImage: symbol)
        .textStyle(Tokens.TypeScale.title)
        .foregroundStyle(Theme.chromeInk)
      ForEach(items, id: \.self) { item in
        Text(item).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.chromeMute)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .chromeCard()
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Screen 2

struct PermissionsScreen: View {
  @ObservedObject var model: OnboardingModel
  @ObservedObject var permissions: PermissionsModel
  let spec: ScreenSpec

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s16) {
      ForEach(permissions.rows) { row in
        PermissionRowView(row: row, permissions: permissions)
      }
      if let caption = spec.caption { CaptionLine(caption) }
      if permissions.ticker.needsRelaunch {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
          Text(OnboardingCopy.quitAndReopenNote).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
          Button(OnboardingCopy.quitAndReopen) { Task { await model.perform(.quitAndReopen) } }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier(A11yID.quitAndReopen)
        }
      }
      if permissions.showInFinder {
        HStack(spacing: Tokens.Space.s12) {
          Button(OnboardingCopy.showInFinder) { permissions.revealInFinder() }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier(A11yID.showInFinder)
          Text(OnboardingCopy.showInFinderNote).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.muted)
        }
      }
      if permissions.ticker.hasRead && permissions.ticker.missing.count == PermissionKind.allCases.count {
        Text(OnboardingCopy.bothMissing).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.muted)
      }
      Spacer(minLength: 0)
      ScreenButtons(screen: .permissions, spec: spec, primary: { await model.perform(.next) },
                    back: { await model.perform(.back) })
    }
    .onAppear {
      let onboarding = model
      permissions.startPolling { ticker in
        Task { @MainActor in
          await onboarding.perform(.permissionsRead(accessibility: ticker.isGranted(.accessibility),
                                                    screenRecording: ticker.isGranted(.screenRecording)))
        }
      }
    }
    .onDisappear { permissions.stopPolling() }
  }
}

struct PermissionRowView: View {
  let row: PermissionRow
  @ObservedObject var permissions: PermissionsModel

  var body: some View {
    let on = permissions.ticker.isGranted(row.kind)
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      HStack(spacing: Tokens.Space.s12) {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(on ? Theme.done : Theme.chromeMute)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: Tokens.Space.s8) {
            Text(row.title).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.chromeInk)
            Text(row.tag).textStyle(Tokens.TypeScale.caption).foregroundStyle(Theme.cyan)
          }
          Text(row.purpose).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
        }
        Spacer()
        if on {
          Text("on").textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.done)
        } else {
          Button(OnboardingCopy.openSettings) { permissions.openSettings(for: row.kind) }
            .buttonStyle(SecondaryButtonStyle())
        }
      }
      Text(row.note).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
      if !on, permissions.ticker.hasRead {
        Text(row.ifMissing).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.needsYou)
      }
      if let hint = PrivacyPane.fallbackHint(for: row.kind, macOSMajor: permissions.macOSMajor) {
        Text(hint).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
      }
    }
    .chromeCard(padding: Tokens.Space.s16)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(row.title), \(on ? "on" : "off")")
    .accessibilityIdentifier(A11yID.permissionRow(row.kind))
  }
}

// MARK: - Screen 3

struct LastTenMinutesScreen: View {
  @ObservedObject var model: OnboardingModel
  let events: LocalEventSource
  let spec: ScreenSpec
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var typedStart: Date?
  @State private var pointerAt = false

  var body: some View {
    let summary = model.lastTen?.summary
    VStack(alignment: .leading, spacing: Tokens.Space.s20) {
      if model.state.showScreenReadingOn {
        Text(OnboardingCopy.screenReadingOn).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.ink2)
      }
      Text(summary?.headline ?? spec.headline)
        .textStyle(Tokens.TypeScale.largeTitle)
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      VStack(alignment: .leading, spacing: Tokens.Space.s12) {
        Text(summary?.line ?? LocalNowSummary.compute(events: [], now: 0).line)
          .textStyle(Tokens.TypeScale.title)
          .foregroundStyle(Theme.chromeInk)
          .accessibilityIdentifier(A11yID.nowLine)
        if let s = summary, !s.isEmpty {
          TopAppsBar(top: s.top)
          HStack(spacing: Tokens.Space.s8) {
            Image(systemName: "cursorarrow")
              .foregroundStyle(Theme.cyan)
              .offset(x: pointerAt || reduceMotion ? 0 : -60, y: pointerAt || reduceMotion ? 0 : 30)
              .accessibilityHidden(true)
            Text(s.remark).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.cyan)
          }
          if let start = typedStart {
            TimelineView(.periodic(from: start, by: TypedText.secondsPerCharacter)) { ctx in
              Text(TypedText.visible(OnboardingCopy.invitation, elapsed: ctx.date.timeIntervalSince(start), reduceMotion: reduceMotion))
                .textStyle(Tokens.TypeScale.body)
                .foregroundStyle(Theme.chromeMute)
            }
            .accessibilityLabel(OnboardingCopy.invitation)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .chromeCard()
      if let lt = model.lastTen, lt.showsAccessLaterLine(now: Date()) {
        Text(OnboardingCopy.accessLater).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
      }
      CaptionLine(OnboardingCopy.lastTenCaption)
      Spacer(minLength: 0)
      ScreenButtons(screen: .lastTenMinutes, spec: spec, primary: { await model.perform(.next) },
                    back: { await model.perform(.back) })
    }
    .task {
      model.openLastTen()
      while !Task.isCancelled {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let from = nowMs - 10 * 60_000
        let summary = LocalNowSummary.compute(events: events.events(from: from, to: nowMs), now: nowMs, minutes: 10,
                                              captureStartedAt: events.captureStartedAt())
        if model.receive(summary) {
          if reduceMotion {
            pointerAt = true
          } else {
            withAnimation(.easeOut(duration: 0.6)) { pointerAt = true }
          }
          typedStart = Date()
        }
        try? await Task.sleep(nanoseconds: UInt64(LastTenMinutesState.refreshEvery * 1_000_000_000))
      }
    }
  }
}

/// The top 3 apps as one bar; shares are drawn, never printed as percentages.
struct TopAppsBar: View {
  let top: [NowApp]
  var body: some View {
    let total = max(1, top.reduce(Int64(0)) { $0 + $1.activeMs })
    let colors = [Theme.cyan, Theme.working, Theme.chromeMute]
    GeometryReader { geo in
      HStack(spacing: 2) {
        ForEach(Array(top.enumerated()), id: \.offset) { pair in
          RoundedRectangle(cornerRadius: 3)
            .fill(colors[pair.offset % colors.count])
            .frame(width: max(4, geo.size.width * Double(pair.element.activeMs) / Double(total) - 2))
        }
      }
    }
    .frame(height: 8)
    .accessibilityHidden(true)
  }
}

// MARK: - Screens 4 and 5

struct SignInScreen: View {
  @ObservedObject var model: OnboardingModel
  let spec: ScreenSpec
  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s20) {
      if let body = spec.body { Text(body).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2) }
      if let wait = model.signInWait {
        TimelineView(.periodic(from: wait.startedAt, by: 1)) { ctx in
          HStack(spacing: Tokens.Space.s12) {
            Text(wait.status(now: ctx.date) == .timedOut ? OnboardingCopy.signInTimedOut : OnboardingCopy.signInWaiting)
              .textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
            Button(OnboardingCopy.cancel) { model.cancelSignIn() }.buttonStyle(SecondaryButtonStyle())
          }
        }
      }
      Text(OnboardingCopy.signInFooter).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.muted)
      Spacer(minLength: 0)
      ScreenButtons(screen: .signIn, spec: spec, primary: { await model.signIn() },
                    secondary: { await model.perform(.notNow) }, back: { await model.perform(.back) })
    }
  }
}

struct WhatLeavesScreen: View {
  @ObservedObject var model: OnboardingModel
  let spec: ScreenSpec
  var config = RetentionConfig()
  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s16) {
    ScrollView {
      VStack(alignment: .leading, spacing: Tokens.Space.s20) {
        HStack(alignment: .top, spacing: Tokens.Space.s16) {
          ListCard(title: OnboardingCopy.sentTitle, symbol: "arrow.up.circle", items: OnboardingCopy.sent)
          ListCard(title: OnboardingCopy.staysTitle, symbol: "lock.circle", items: OnboardingCopy.stays)
        }
        ForEach(OnboardingCopy.whatLeavesFacts(config), id: \.self) { fact in
          Text(fact).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
        }
        Text(OnboardingCopy.workMac).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.muted)
      }
    }
    ScreenButtons(screen: .whatLeaves, spec: spec,
                  primary: { await model.perform(.startSending(noticeVersion: WhatLeavesNotice.version)) },
                  secondary: { await model.perform(.keepOnThisMac) }, back: { await model.perform(.back) })
    }
  }
}

// MARK: - Screens 6 to 9 and 12

struct QuestionScreen: View {
  @ObservedObject var model: OnboardingModel
  let screen: OnboardingScreen
  let spec: ScreenSpec
  let resolveApp: (String) -> String?

  @State private var role = ""
  @State private var goals: [String] = []
  @State private var drains: [Drain] = []
  @State private var rhythm = Rhythm()
  @State private var autonomy: Autonomy?

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s20) {
      switch screen {
      case .role: ChipGrid(choices: Roles.choices, selected: role.isEmpty ? [] : [role]) { role = $0 }
        TextField(OnboardingCopy.typeOne, text: $role).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
      case .goals: ChipGrid(choices: Goals.choices, selected: Set(goals)) { g in
          if let i = goals.firstIndex(of: g) { goals.remove(at: i) } else if goals.count < Goals.max { goals.append(g) }
        }
      case .drains: ChipGrid(choices: Drain.allCases.map(\.label), selected: Set(drains.map(\.label))) { label in
          guard let d = Drain.allCases.first(where: { $0.label == label }) else { return }
          if let i = drains.firstIndex(of: d) { drains.remove(at: i) } else { drains.append(d) }
        }
      case .rhythm: RhythmFields(model: model, rhythm: rhythm)
      case .handsOn: ForEach(Autonomy.allCases, id: \.self) { a in
          Button { autonomy = a } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(a.label).textStyle(Tokens.TypeScale.title)
              Text(a.detail).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperCard(padding: Tokens.Space.s12)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(autonomy == a ? Theme.ink : Color.clear, lineWidth: 2))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(autonomy == a ? .isSelected : [])
        }
      default: EmptyView()
      }
      if let caption = OnboardingCopy.spec(for: screen, state: model.state).caption, screen != .rhythm {
        CaptionLine(screen == .goals ? OnboardingCopy.goalsCaption(count: goals.count) : caption)
      }
      Spacer(minLength: 0)
      ScreenButtons(screen: screen, spec: spec, primary: { await submit() },
                    skip: { await model.perform(.skip) }, back: { await model.perform(.back) })
    }
  }

  private func submit() async {
    switch screen {
    case .role: await model.perform(role.isEmpty ? .next : .answer(.role(role)))
    case .goals: await model.perform(goals.isEmpty ? .next : .answer(.goals(goals)))
    case .drains: await model.perform(drains.isEmpty ? .next : .answer(.drains(drains)))
    case .rhythm:
      await model.applyNeverWatchText(resolve: resolveApp)
      await model.perform(.answer(.rhythm(rhythm)))
    case .handsOn:
      if let a = autonomy { await model.perform(.answer(.autonomy(a))) } else { await model.perform(.next) }
    default: await model.perform(.next)
    }
  }
}

/// One-tap chips.
struct ChipGrid: View {
  let choices: [String]
  let selected: Set<String>
  let tap: (String) -> Void
  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Tokens.Space.s8)], alignment: .leading, spacing: Tokens.Space.s8) {
      ForEach(choices, id: \.self) { c in
        let on = selected.contains(c)
        Button { tap(c) } label: {
          Text(c)
            .textStyle(Tokens.TypeScale.label)
            .foregroundStyle(on ? Theme.chromeInk : Theme.ink)
            .padding(.horizontal, Tokens.Space.s12)
            .padding(.vertical, Tokens.Space.s8)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(on ? Theme.chrome : Color.white))
            .overlay(Capsule().strokeBorder(Theme.rule))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
  }
}

/// Screen 9: rhythm defaults shown plainly, then Never watch (locked chips, optional chips, a typed field).
struct RhythmFields: View {
  @ObservedObject var model: OnboardingModel
  let rhythm: Rhythm
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s16) {
      HStack(spacing: Tokens.Space.s24) {
        LabeledValue(label: OnboardingCopy.rhythmDays, value: rhythm.daysText)
        LabeledValue(label: OnboardingCopy.rhythmHours, value: rhythm.hoursText)
        LabeledValue(label: OnboardingCopy.rhythmReview, value: rhythm.reviewText)
      }
      Text(OnboardingCopy.neverWatchQuestion).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.ink)
      let user = Set(model.state.neverWatch)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Tokens.Space.s8)], alignment: .leading, spacing: Tokens.Space.s8) {
        ForEach(NeverWatchChip.locked) { chip in
          Label("\(chip.label) · \(OnboardingCopy.lockedNote)", systemImage: "lock.fill")
            .textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.ink2)
        }
        ForEach(NeverWatchChip.optional) { chip in
          let on = chip.exclusions.allSatisfy { user.contains($0) }
          Button {
            Task {
              if on {
                for e in chip.exclusions { await model.perform(.neverWatchRemove(e)) }
              } else {
                await model.perform(.neverWatch(add: chip.exclusions))
              }
            }
          } label: {
            Label(chip.label, systemImage: on ? "checkmark.square.fill" : "square")
              .textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.ink)
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }
      TextField(OnboardingCopy.neverWatchHint, text: $text)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(OnboardingCopy.neverWatchLabel)
        .accessibilityIdentifier(A11yID.neverWatchField)
        .onAppear { text = model.state.neverWatchText }
        .onChange(of: text) { _, new in
          Task { await model.perform(.neverWatchText(new)) }
        }
      CaptionLine(OnboardingCopy.neverWatchCaption)
    }
  }
}

struct LabeledValue: View {
  let label: String
  let value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).textStyle(Tokens.TypeScale.caption).foregroundStyle(Theme.muted)
      Text(value).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.ink)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Screens 10, 11 and 13

struct ConnectScreen: View {
  @ObservedObject var model: OnboardingModel
  let spec: ScreenSpec
  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s16) {
      if let body = spec.body { Text(body).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2) }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Tokens.Space.s12)], spacing: Tokens.Space.s12) {
        ForEach(ConnectionCatalog.launch) { app in
          let connected = model.state.connectedApps.first { $0.id == app.id }
          VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            Text(app.name).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.chromeInk)
            Text(connected?.account ?? app.pathLine).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
            if connected != nil {
              Label("on", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.done)
            } else {
              Button(OnboardingCopy.connect) { Task { await model.connect(appID: app.id) } }
                .buttonStyle(SecondaryButtonStyle())
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .chromeCard(padding: Tokens.Space.s16)
          .accessibilityIdentifier(A11yID.connectTile(app.id))
        }
      }
      if let m = model.connectMessage { Text(m).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2) }
      if let caption = spec.caption { CaptionLine(caption) }
      Spacer(minLength: 0)
      ScreenButtons(screen: .connectApps, spec: spec, primary: { await model.perform(.next) },
                    secondary: { await model.perform(.skip) }, back: { await model.perform(.back) })
    }
  }
}

struct RecordingsScreen: View {
  @ObservedObject var model: OnboardingModel
  let spec: ScreenSpec
  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s16) {
      if let caption = spec.caption { CaptionLine(caption) }
      Spacer(minLength: 0)
      ScreenButtons(screen: .recordings, spec: spec, primary: { await model.perform(.importRecordings) },
                    secondary: { await model.perform(.importRecordings) }, skip: { await model.perform(.skip) },
                    back: { await model.perform(.back) })
    }
  }
}

struct DoneScreen: View {
  @ObservedObject var model: OnboardingModel
  let spec: ScreenSpec
  @State private var openAtLogin = true
  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s20) {
      Text(OnboardingCopy.doneBody(state: model.state)).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
      Toggle(OnboardingCopy.openAtLoginLabel, isOn: $openAtLogin)
        .accessibilityIdentifier(A11yID.openAtLogin)
        .onAppear { openAtLogin = model.state.openAtLogin }
        .onChange(of: openAtLogin) { _, on in
          Task { await model.perform(.setOpenAtLogin(on)) }
        }
      Label(OnboardingCopy.menuBarPointer, systemImage: "menubar.arrow.up.rectangle")
        .textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.muted)
      Spacer(minLength: 0)
      ScreenButtons(screen: .done, spec: spec, primary: { await model.perform(.next) },
                    secondary: { await model.perform(.showSampleWeek) }, showBack: false)
    }
  }
}
