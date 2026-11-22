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
          HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s12) {
            Text(OrphanGuard.glue(spec.headline))
              .textStyle(Tokens.TypeScale.largeTitle)
              .foregroundStyle(Theme.ink)
              .accessibilityAddTraits(.isHeader)
              .accessibilityLabel(spec.headline)
            if let badge = spec.badge {
              Text(badge)
                .textStyle(Tokens.TypeScale.badge)
                .foregroundStyle(Theme.chromeInk)
                .padding(.horizontal, Tokens.Space.s8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.chrome))
            }
          }
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
        Button(OnboardingCopy.back) { Task { await back() } }
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
        PermissionRowView(row: row, permissions: permissions) { kind in
          Task { await model.perform(.promptedInSettings(kind)) }
        }
      }
      if let caption = spec.caption { CaptionLine(caption) }
      if permissions.ticker.needsRelaunch {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
          Text(OnboardingCopy.quitAndReopenNote).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
          // Secondary style: Continue stays the one primary button on this screen.
          Button(OnboardingCopy.quitAndReopen) { Task { await model.perform(.quitAndReopen) } }
            .buttonStyle(SecondaryButtonStyle())
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
    .onChange(of: permissions.ticker.justGranted) { old, new in
      // Ticks are announced to VoiceOver, not only drawn.
      for kind in new.subtracting(old).sorted(by: { $0.rawValue < $1.rawValue }) {
        let name = PrivacyPane.controlName(for: kind, macOSMajor: permissions.macOSMajor)
        AccessibilityNotification.Announcement(OnboardingCopy.permissionOn(name)).post()
      }
    }
  }
}

struct PermissionRowView: View {
  let row: PermissionRow
  @ObservedObject var permissions: PermissionsModel
  let onPrompted: (PermissionKind) -> Void

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
          Text(OnboardingCopy.on).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.done)
        } else {
          Button(OnboardingCopy.openSettings) {
            if permissions.openSettings(for: row.kind) == .systemPrompt { onPrompted(row.kind) }
          }
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
    .accessibilityLabel("\(row.title), \(on ? OnboardingCopy.on : OnboardingCopy.off)")
    .accessibilityIdentifier(A11yID.permissionRow(row.kind))
  }
}

// MARK: - Screen 3

struct LastTenMinutesScreen: View {
  @ObservedObject var model: OnboardingModel
  let events: LocalEventSource
  let spec: ScreenSpec
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pointerAt = false
  /// Characters typed so far: the remark first, then the invitation. Typing stops when both are shown.
  @State private var typed = 0
  @State private var typing = false

  var body: some View {
    let summary = model.lastTen?.summary
    let showsRemark = model.lastTen?.showsRemark ?? false
    let remark = summary?.remark ?? ""
    let invitation = OnboardingCopy.invitation
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
        if let s = summary, s.hasActiveMinute {
          TopAppsBar(top: s.top)
        }
        if showsRemark {
          HStack(spacing: Tokens.Space.s8) {
            Image(systemName: "cursorarrow")
              .foregroundStyle(Theme.cyan)
              .offset(x: pointerAt || reduceMotion ? 0 : -60, y: pointerAt || reduceMotion ? 0 : 30)
              .accessibilityHidden(true)
            Text(String(remark.prefix(typed)))
              .textStyle(Tokens.TypeScale.callout)
              .foregroundStyle(Theme.cyan)
              .accessibilityLabel(remark)
          }
          Text(String(invitation.prefix(max(0, typed - remark.count))))
            .textStyle(Tokens.TypeScale.body)
            .foregroundStyle(Theme.chromeMute)
            .accessibilityLabel(invitation)
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
            // The pointer is drawn at its start first, then flies: one frame later the offset animates to the line.
            try? await Task.sleep(nanoseconds: 60_000_000)
            withAnimation(.easeOut(duration: 0.6)) { pointerAt = true }
          }
          typing = true
        }
        try? await Task.sleep(nanoseconds: UInt64(LastTenMinutesState.refreshEvery * 1_000_000_000))
      }
    }
    .task(id: typing) {
      guard typing else { return }
      let total = remark.count + invitation.count
      if reduceMotion {
        typed = total  // Reduce Motion: the final state at once
        return
      }
      while typed < total && !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(TypedText.secondsPerCharacter * 1_000_000_000))
        typed += 1
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
            Button(OnboardingCopy.signInOpenAgain) { model.reopenSignInPage() }.buttonStyle(SecondaryButtonStyle())
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
        HStack(spacing: Tokens.Space.s16) {
          Link(OnboardingCopy.privacyDetails, destination: PrivacyLinks.details)
            .textStyle(Tokens.TypeScale.callout)
          Text(OnboardingCopy.workMac).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.muted)
        }
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

  // Drafts, seeded from the saved answers so Back and relaunch keep them.
  @State private var role = ""
  @State private var goals: [String] = []
  @State private var drains: [Drain] = []
  @State private var rhythm = Rhythm()
  @State private var autonomy: Autonomy?

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s20) {
      switch screen {
      case .role:
        ChipGrid(choices: Roles.choices, selected: role.isEmpty ? [] : [role]) { role = $0 }
        TextField(OnboardingCopy.typeOne, text: $role).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
      case .goals:
        ChipGrid(choices: Goals.choices, selected: Set(goals)) { g in
          if let i = goals.firstIndex(of: g) { goals.remove(at: i) } else if goals.count < Goals.max { goals.append(g) }
        }
      case .drains:
        ChipGrid(choices: Drain.allCases.map(\.label), selected: Set(drains.map(\.label))) { label in
          guard let d = Drain.allCases.first(where: { $0.label == label }) else { return }
          if let i = drains.firstIndex(of: d) { drains.remove(at: i) } else { drains.append(d) }
        }
      case .rhythm:
        RhythmEditor(rhythm: $rhythm)
        NeverWatchFields(model: model, resolveApp: resolveApp)
      case .handsOn:
        ForEach(Autonomy.allCases, id: \.self) { a in
          Button { autonomy = a } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(a.label).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.ink)
              Text(a.detail).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperCard(padding: Tokens.Space.s12)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(autonomy == a ? Theme.ink : Color.clear, lineWidth: 2))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(autonomy == a ? .isSelected : [])
        }
      default:
        EmptyView()
      }
      if let caption = spec.caption, screen != .rhythm {
        CaptionLine(screen == .goals ? OnboardingCopy.goalsCaption(count: goals.count) : caption)
      }
      Spacer(minLength: 0)
      ScreenButtons(screen: screen, spec: spec, primary: { await submit() },
                    skip: { await skip() }, back: { await model.perform(.back) })
    }
    .onAppear {
      let p = model.state.profile
      role = p.role ?? ""
      goals = p.goals
      drains = p.drains
      rhythm = p.rhythm ?? Rhythm()
      autonomy = p.autonomy
    }
  }

  private func skip() async {
    if screen == .rhythm {
      await model.leaveRhythm(answer: nil, resolve: resolveApp)
    } else {
      await model.perform(.skip)
    }
  }

  private func submit() async {
    switch screen {
    case .role: await model.perform(role.isEmpty ? .next : .answer(.role(role)))
    case .goals: await model.perform(goals.isEmpty ? .next : .answer(.goals(goals)))
    case .drains: await model.perform(drains.isEmpty ? .next : .answer(.drains(drains)))
    case .rhythm: await model.leaveRhythm(answer: rhythm, resolve: resolveApp)
    case .handsOn:
      if let a = autonomy { await model.perform(.answer(.autonomy(a))) } else { await model.perform(.next) }
    default: await model.perform(.next)
    }
  }
}

/// Q4: days, hours and the weekly review slot, defaults shown and editable.
struct RhythmEditor: View {
  @Binding var rhythm: Rhythm

  static let times: [String] = (5...22).flatMap { h -> [String] in
    let hh = h < 10 ? "0\(h)" : "\(h)"
    return ["\(hh):00", "\(hh):30"]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s12) {
      HStack(spacing: Tokens.Space.s8) {
        Text(OnboardingCopy.rhythmDays).textStyle(Tokens.TypeScale.caption).foregroundStyle(Theme.muted)
        ForEach(Weekday.allCases, id: \.self) { day in
          let on = rhythm.days.contains(day)
          Button {
            if let i = rhythm.days.firstIndex(of: day) { rhythm.days.remove(at: i) } else { rhythm.days.append(day) }
          } label: {
            Text(day.short)
              .textStyle(Tokens.TypeScale.label)
              .foregroundStyle(on ? Theme.chromeInk : Theme.ink)
              .padding(.horizontal, Tokens.Space.s8)
              .padding(.vertical, 4)
              .background(Capsule().fill(on ? Theme.chrome : Color.white))
              .overlay(Capsule().strokeBorder(Theme.rule))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }
      HStack(spacing: Tokens.Space.s16) {
        Picker(OnboardingCopy.rhythmHours, selection: $rhythm.start) {
          ForEach(Self.times, id: \.self) { Text(Rhythm.clock($0)).tag($0) }
        }
        .frame(maxWidth: 220)
        Picker(OnboardingCopy.rhythmEnd, selection: $rhythm.end) {
          ForEach(Self.times, id: \.self) { Text(Rhythm.clock($0)).tag($0) }
        }
        .frame(maxWidth: 160)
      }
      HStack(spacing: Tokens.Space.s16) {
        Picker(OnboardingCopy.rhythmReview, selection: $rhythm.reviewDay) {
          ForEach(Weekday.allCases, id: \.self) { Text($0.full).tag($0) }
        }
        .frame(maxWidth: 260)
        Picker(OnboardingCopy.rhythmReviewTime, selection: $rhythm.reviewTime) {
          ForEach(Self.times, id: \.self) { Text(Rhythm.clock($0)).tag($0) }
        }
        .frame(maxWidth: 160)
      }
    }
    .foregroundStyle(Theme.ink)
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

/// Never watch (screen 9 and the menu bar sheet): locked chips, optional chips, the person's own entries with Remove,
/// and a typed field. Entries apply on this Mac first.
struct NeverWatchFields: View {
  @ObservedObject var model: OnboardingModel
  let resolveApp: (String) -> String?
  /// The sheet has its own Add button; on screen 9 Continue and Skip apply the field too.
  var showsAdd = true
  @State private var text = ""

  var body: some View {
    let user = model.state.neverWatch
    let chipEntries = Set(NeverWatchChip.optional.flatMap(\.exclusions))
    VStack(alignment: .leading, spacing: Tokens.Space.s12) {
      Text(OnboardingCopy.neverWatchQuestion).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.ink)
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
      let own = user.filter { !chipEntries.contains($0) }
      if !own.isEmpty {
        Text(OnboardingCopy.neverWatchYours).textStyle(Tokens.TypeScale.caption).foregroundStyle(Theme.muted)
        ForEach(own, id: \.self) { entry in
          HStack(spacing: Tokens.Space.s8) {
            Text(entry.value).textStyle(Tokens.TypeScale.label).foregroundStyle(Theme.ink)
            Button(OnboardingCopy.remove) { Task { await model.perform(.neverWatchRemove(entry)) } }
              .buttonStyle(.plain)
              .foregroundStyle(Theme.ink2)
              .accessibilityLabel("\(OnboardingCopy.remove) \(entry.value)")
          }
        }
      }
      HStack(spacing: Tokens.Space.s8) {
        TextField(OnboardingCopy.neverWatchHint, text: $text)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(OnboardingCopy.neverWatchLabel)
          .accessibilityIdentifier(A11yID.neverWatchField)
          .onSubmit { Task { await model.addTypedNeverWatch(resolve: resolveApp) } }
        if showsAdd {
          Button(OnboardingCopy.neverWatchAdd) { Task { await model.addTypedNeverWatch(resolve: resolveApp) } }
            .buttonStyle(SecondaryButtonStyle())
        }
      }
      CaptionLine(OnboardingCopy.neverWatchCaption)
    }
    .onAppear { text = model.state.neverWatchText }
    .onChange(of: text) { _, new in
      if new != model.state.neverWatchText { Task { await model.perform(.neverWatchText(new)) } }
    }
    .onChange(of: model.state.neverWatchText) { _, new in
      if new != text { text = new }  // what could not be found stays in the field
    }
  }
}

/// The menu bar's "Never watch an app or site…": the same fields, without sign-in, in every mode.
public struct NeverWatchSheet: View {
  @ObservedObject var model: OnboardingModel
  let resolveApp: (String) -> String?
  let done: () -> Void

  public init(model: OnboardingModel, resolveApp: @escaping (String) -> String?, done: @escaping () -> Void) {
    self.model = model
    self.resolveApp = resolveApp
    self.done = done
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s16) {
      NeverWatchFields(model: model, resolveApp: resolveApp)
      if let notice = model.notice {
        Text(notice).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
      }
      HStack {
        Spacer()
        Button(OnboardingCopy.continueTitle) { done() }
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(Tokens.Space.s32)
    .frame(minWidth: 560)
    .background(Theme.paper)
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
              Label(OnboardingCopy.on, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.done)
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
      if let recordings = model.services.recordings { RecordingsScreenBody(model: recordings) }
      if let caption = spec.caption { CaptionLine(caption) }
      Spacer(minLength: 0)
      ScreenButtons(screen: .recordings, spec: spec, primary: { await model.perform(.importRecordings) },
                    secondary: {
                      if model.services.recordings != nil {
                        await model.chooseRecordingsFolder()
                      } else {
                        await model.perform(.importRecordings)
                      }
                    }, skip: { await model.perform(.skip) },
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
      Text(OnboardingCopy.doneBody(state: model.state, capturing: model.services.capture.isRunning))
        .textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
      Toggle(isOn: $openAtLogin) {
        Text(OnboardingCopy.openAtLoginLabel).foregroundStyle(Theme.ink)
      }
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
