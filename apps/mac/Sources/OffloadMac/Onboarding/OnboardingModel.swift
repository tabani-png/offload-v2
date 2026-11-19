import Foundation

/// The onboarding window's model: runs the pure flow, saves after every action, then runs its effects against the
/// injected services in order (local exclusions before the server call, consent before the uploader).
@MainActor
public final class OnboardingModel: ObservableObject {
  @Published public private(set) var flow: OnboardingFlow
  /// One line under the screen's buttons (sign-in waiting or failed, connect result, import not ready).
  @Published public private(set) var notice: String?
  @Published public private(set) var connectMessage: String?
  @Published public private(set) var signInWait: SignInWait?
  /// Set while screen 3 is open.
  @Published public private(set) var lastTen: LastTenMinutesState?

  public let services: OnboardingServices
  private let store: OnboardingStore
  /// Called by "Open today" on screen 13.
  public var onOpenToday: (@MainActor () -> Void)?

  public init(store: OnboardingStore, services: OnboardingServices) {
    self.store = store
    self.services = services
    let saved = store.load() ?? OnboardingState()
    self.flow = OnboardingFlow(state: saved)
    services.neverWatch.add(saved.neverWatch)
  }

  public var state: OnboardingState { flow.state }

  /// `--onboarding-screen <n>`.
  public func jump(to screen: OnboardingScreen) {
    flow.jump(to: screen)
    store.save(flow.state)
  }

  public func perform(_ action: OnboardingAction) async {
    let before = flow.screen
    let effects = flow.perform(action, now: Date())
    store.save(flow.state)
    if flow.screen != before { notice = nil; connectMessage = nil }
    await run(effects)
  }

  private func run(_ effects: [OnboardingEffect]) async {
    var consentFailed = false
    for effect in effects {
      switch effect {
      case .startCapture:
        services.capture.start()
      case .startUploader:
        // Never start sending without a recorded consent.
        if !consentFailed { services.uploader.start() }
      case .pauseUploader:
        services.uploader.pause()
      case .recordConsent(let version):
        do {
          try await services.consent.recordUploadConsent(noticeVersion: version)
        } catch {
          // Never start sending without a recorded consent: back to screen 5, and say so.
          consentFailed = true
          await perform(.consentFailed)
          notice = OnboardingCopy.consentFailed
        }
      case .patchProfile(let update):
        // Nothing reaches the account without a recorded consent.
        if !consentFailed { try? await services.profile.patch(update) }
      case .applyExclusionsLocally(let entries):
        services.neverWatch.add(entries)
      case .removeExclusionLocally(let entry):
        services.neverWatch.remove(entry)
      case .uploadExclusions(let entries):
        if !consentFailed { try? await services.exclusions.upload(entries) }
      case .setLoginItem(let on):
        services.loginItem.setEnabled(on)
      case .relaunch:
        services.relauncher.relaunch()
      case .showSampleWeek:
        services.sampleWeek.show()
      case .startRecordingsImport:
        // m3-05: the import runs in the background with its own panel, so setup goes on to screen 12. When it cannot
        // start (no on-device text reading in this build, or a refused folder) the screen stays and says why.
        if let recordings = services.recordings {
          if recordings.startImport() {
            await perform(.next)
          } else {
            notice = recordings.notice ?? OnboardingCopy.recordingsNotReady
          }
        } else {
          notice = OnboardingCopy.recordingsNotReady
        }
      case .openToday:
        onOpenToday?()
      }
    }
  }

  // MARK: Screen 3

  public func openLastTen(now: Date = Date()) {
    if lastTen == nil { lastTen = LastTenMinutesState(openedAt: now) }
  }

  /// Takes a fresh local now summary; true when the pointer should fly now.
  @discardableResult
  public func receive(_ summary: LocalNowSummary) -> Bool {
    var s = lastTen ?? LastTenMinutesState(openedAt: Date())
    let flies = s.received(summary)
    lastTen = s
    return flies
  }

  // MARK: Screen 4

  public func signIn() async {
    signInWait = SignInWait(startedAt: Date())
    notice = nil
    let result = await services.account.signIn()
    signInWait = nil
    switch result {
    case .signedIn: notice = nil
    case .cancelled: notice = OnboardingCopy.signInCancelled
    case .offline: notice = OnboardingCopy.signInOffline
    case .unavailable: notice = OnboardingCopy.signInUnavailable
    }
    await perform(.signInResult(result))
  }

  public func cancelSignIn() { signInWait = nil }

  /// "Open the page again" while waiting.
  public func reopenSignInPage() { services.account.reopenPage() }

  // MARK: Screen 9 and the Never watch sheet

  /// Applies the typed Never watch entries. Names that are not installed apps are not guessed: they stay in the field
  /// and the notice names them. Returns true when everything typed was applied.
  @discardableResult
  public func addTypedNeverWatch(resolve: (String) -> String?) async -> Bool {
    let r = NeverWatch.exclusions(from: flow.state.neverWatchText, resolve: resolve)
    if !r.exclusions.isEmpty { await perform(.neverWatch(add: r.exclusions)) }
    await perform(.neverWatchText(r.unresolved.joined(separator: ", ")))
    notice = r.unresolved.isEmpty ? nil : OnboardingCopy.neverWatchNotFound(r.unresolved)
    return r.unresolved.isEmpty
  }

  /// Continue (`answer`) or Skip (`nil`) on screen 9. Typed entries are applied either way, before anything else; if a
  /// name cannot be found the screen stays open so nothing the person asked to hide is left watched.
  public func leaveRhythm(answer: Rhythm?, resolve: (String) -> String?) async {
    guard await addTypedNeverWatch(resolve: resolve) else { return }
    if let answer {
      await perform(.answer(.rhythm(answer)))
    } else {
      await perform(.skip)
    }
  }

  /// Row 11.11 at launch: screen 5 again, and the uploader pauses at once.
  public func reconsentNeeded() {
    if performSync(.reconsentNeeded).contains(.pauseUploader) { services.uploader.pause() }
  }

  /// Runs an action and saves, without running its effects; for launch-time and menu-time steps that the caller
  /// finishes itself (no effect here may need a network call).
  @discardableResult
  public func performSync(_ action: OnboardingAction) -> [OnboardingEffect] {
    let effects = flow.perform(action, now: Date())
    store.save(flow.state)
    return effects
  }

  // MARK: Screen 10

  public func connect(appID: String) async {
    let result = await services.connections.connect(appID: appID)
    switch result {
    case .connected(let account):
      connectMessage = nil
      await perform(.connected(ConnectedApp(id: appID, account: account)))
    case .cancelled: connectMessage = OnboardingCopy.connectCancelled
    case .scopeDenied: connectMessage = OnboardingCopy.connectScopeDenied
    case .timedOut: connectMessage = OnboardingCopy.connectTimedOut
    case .offline: connectMessage = OnboardingCopy.connectOffline
    case .unavailable: connectMessage = OnboardingCopy.connectUnavailable
    }
  }
}

extension OnboardingModel {
  /// Today's dismissed banners (10.3), saved with the onboarding state.
  public func saveReask(_ reask: ReaskState) {
    flow.setReask(reask)
    store.save(flow.state)
  }

  /// "Start fresh": onboarding begins again; the person's Never watch entries stay applied.
  public func reset() {
    var fresh = OnboardingState()
    fresh.neverWatch = flow.state.neverWatch
    flow = OnboardingFlow(state: fresh)
    store.save(flow.state)
  }
}
