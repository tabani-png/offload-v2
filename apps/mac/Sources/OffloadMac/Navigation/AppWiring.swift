import Foundation
import OffloadImport

// How the app puts m3-10 together at launch: the on-device recordings import, local insights and the offer rule.
// AppModel.live() calls these; AppModel itself only gained stored properties (shared file, additive edits only).

/// The live local analysis: insights over the imports kept on this Mac, and the on-device recordings import whose
/// panel shows the insights done line.
@MainActor
public struct LocalAnalysis {
  public let insights: InsightsModel
  /// Nil when the on-device folder could not be set up; the app then keeps m3-05's model without an importer.
  public let onDevice: OnDeviceRecordings?
  /// The Never watch rules the insights store reads, refreshed on the main actor when the list changes.
  public let rules: ExclusionRulesBox

  public init(insights: InsightsModel, onDevice: OnDeviceRecordings?, rules: ExclusionRulesBox) {
    self.insights = insights
    self.onDevice = onDevice
    self.rules = rules
  }

  /// Only `.local` imports into the on-device sink; `.cloud` keeps m3-05's import exactly as it was built (its sink is
  /// the uploader's, m3-02), so nothing is counted here that the cloud should have (review 2, finding 4). Pure, so
  /// nonisolated: callable off the main actor.
  nonisolated public static func importsOnThisMac(mode: BackendMode) -> Bool { mode.isLocal }

  /// `folders` and `defaults` are this user's in the app; tests pass a temporary folder and a test suite.
  public static func live(neverWatch: NeverWatchStore, events: LocalEventSource, mode: BackendMode,
                          folders: OnDeviceRecordings.Folders? = nil, defaults: UserDefaults = .standard) -> LocalAnalysis {
    let folders = folders ?? OnDeviceRecordings.Folders.live()
    let box = ExclusionRulesBox()
    let store = InsightsStore(sources: InsightsStore.Sources(
      reader: LocalObservationStore(folder: folders.paths.imports), live: events, exclusions: { box.rules },
      answers: FileLocalAnswerStore(file: folders.paths.answers)
    ))
    let insights = InsightsModel(store: store)
    var onDevice: OnDeviceRecordings?
    if importsOnThisMac(mode: mode) {
      onDevice = try? OnDeviceRecordings.make(neverWatch: neverWatch, store: UserDefaultsRecordingsFolderStore(defaults: defaults),
                                              folders: folders, panel: AnalysedImportPanel(insights: insights),
                                              importsListReadable: OnDeviceRecordings.importsListReadable(defaults: defaults))
    }
    return LocalAnalysis(insights: insights, onDevice: onDevice, rules: box)
  }
}

extension AppModel {
  /// The recordings import is offered in `.local` backend mode, or in `.cloud` while signed in and sending. Set after
  /// OnboardingModel set its own (cloud) rule.
  public func wireRecordingsOffer() {
    recordings?.offerCheck = { [weak self] in
      guard let self else { return false }
      return RecordingsOffer.isOffered(mode: self.backends.mode, sending: self.onboarding.state.sending,
                                       canImportLocally: self.recordings?.canImport ?? false)
    }
    recordings?.objectWillChange.send()
  }

  /// At launch: the offer rule, the insights coordinator (a finished or removed import recomputes its days), a
  /// recount when the Never watch list changes, and one full refresh off the main actor.
  ///
  /// `ruleProvider` turns the Never watch list into rules on the main actor; nil looks up installed apps' names
  /// (`exclusionRules(_:)`). Tests pass one that looks nothing up.
  public func startLocalAnalysis(rules box: ExclusionRulesBox,
                                 ruleProvider: (@MainActor @Sendable () -> [ImportExclusionRule])? = nil) {
    wireRecordingsOffer()
    let neverWatch = self.neverWatch
    let provider: @MainActor @Sendable () -> [ImportExclusionRule] = ruleProvider ?? { AppModel.exclusionRules(neverWatch) }
    insights.follow(exclusions: neverWatch, changes: onboarding.objectWillChange, rules: provider, box: box)
    if let recordings {
      insights.observe(recordings).start()
    } else {
      Task { await insights.refreshAll() }
    }
  }

  /// The Never watch list as rules, with installed apps' names looked up now (on the main actor), so a recorded app
  /// is matched by the name its menu bar showed.
  public static func exclusionRules(_ neverWatch: NeverWatchStore) -> [ImportExclusionRule] {
    let ids = neverWatch.currentExclusions().filter { $0.kind == .bundleID }.map(\.value) + ImportExclusions.builtInBundleIDs
    return NeverWatchImportExclusions(source: neverWatch, appNames: LiveAppNames.resolver(for: ids)).currentRules()
  }
}
