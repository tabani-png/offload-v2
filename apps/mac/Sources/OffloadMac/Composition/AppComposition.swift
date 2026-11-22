// The one composition root of the Offload app (slice m3-14-mac-app-integration). OffloadApp asks `live()` once; no
// other file builds AppModel, AppUpdates, CaptureRuntime or UploadRuntime (test ENTRY). The order of launch is here:
//
// 1. UploadBackend: `.local` unless this Mac is enrolled (the test build is `.local`). The screens' own flag is m3-10's
//    BackendMode; both read the API base from `ai.offload.api.baseURL`.
// 2. One NeverWatchStore for the screens, the menu bar, the observer (through its exclusions file) and the import.
// 3. CaptureRuntime (built on its first start, not before) and, only in `.cloud`, UploadRuntime.
// 4. The updater (m3-03), before any scene as before, with an UpdatePreparation over that same capture and uploader.
// 5. The recordings import with the sink the launch facts allow (the uploader when sending, else m3-10's on-device
//    sink when it exists) and the real masker; no importer until m3-10's on-device text reading exists.
// 6. m3-10's analysis hook (`CompositionSeams.analysis`) runs once, before AppModel: it gets the live events, the Never
//    watch list, the import masker and the store's ledger, and may supply the recordings model and build AppModel from
//    the composition's parts. Its `afterLaunch` runs once AppModel exists. The offer rule (ImportOffer) is applied last.
// 7. AppModel: reads both permissions, checks the notice version, then starts capture and the uploader per LaunchPlan.
import AppKit
import Foundation
import OffloadImport
import OffloadStore

/// What the composition hands the analysis (m3-10's `LocalAnalysis.live(neverWatch:events:mode:)` and
/// `OnDeviceRecordings.make`): the one Never watch list, the live events of this Mac's capture, and the import's real
/// masker and ledger, so the merged Today reads real data and the on-device import masks with the capture's key and
/// forgets on "Start fresh" (reviews 4 and 5, finding 1).
@MainActor public struct AnalysisInputs {
  public let neverWatch: NeverWatchStore
  /// The capture runtime's events (StoreEventSource over the encrypted day store).
  public let events: any LocalEventSource
  public let uploadBackend: UploadBackend
  /// PR #13's masker with the capture's pseudonym key, loaded on first use (`ready()` before an import space opens).
  public let importMasker: ImportMaskerAdapter
  /// The store's ledger: "Start fresh" resets the file and the entries an importer holds.
  public let importLedger: ResettableImportLedger
}

/// Every argument of this slice's `AppModel(...)` call. `make()` is that call; the analysis can make its own call with
/// these parts plus its parameters (m3-10's `backends:`, `insights:`, `onDeviceRecordings:`), and the composition still
/// owns the result (review 5, finding 1).
@MainActor public struct AppModelParts {
  public let options: LaunchOptions
  public let bundlePath: String
  public let bufferReadable: Bool
  public let store: OnboardingStore
  public let services: OnboardingServices
  public let probe: PermissionProbe
  public let events: any LocalEventSource
  public let sampleWeek: SampleWeekFlag
  public let currentNoticeVersion: String?
  public let uploadsAvailable: Bool

  /// This slice's call.
  public func make() -> AppModel {
    AppModel(options: options, bundlePath: bundlePath, bufferReadable: bufferReadable, store: store, services: services,
             probe: probe, events: events, sampleWeek: sampleWeek, currentNoticeVersion: currentNoticeVersion,
             uploadsAvailable: uploadsAvailable)
  }
}

/// What the analysis gives back.
@MainActor public struct AnalysisPlug {
  /// The recordings model to use instead of the composition's (m3-10's `local.onDevice?.model`). Nil keeps the
  /// composition's own.
  public var recordings: RecordingsImportModel?
  /// True when that model imports on this Mac (m3-10's on-device import): the offer rule then treats it as the
  /// on-device sink.
  public var onDeviceImport: Bool
  /// Builds the app model from the composition's parts (m3-10 adds its parameters). Nil: `parts.make()`.
  public var makeApp: (@MainActor (AppModelParts) -> AppModel)?
  /// Runs once AppModel exists (m3-10's `app.startLocalAnalysis(rules:)`, m3-12's `app.weeklyReview.start()`). Any
  /// offer rule it sets is replaced by the composition's (one rule, ImportOffer).
  public var afterLaunch: (@MainActor (AppModel) -> Void)?

  public init(recordings: RecordingsImportModel? = nil, onDeviceImport: Bool = false,
              makeApp: (@MainActor (AppModelParts) -> AppModel)? = nil,
              afterLaunch: (@MainActor (AppModel) -> Void)? = nil) {
    self.recordings = recordings
    self.onDeviceImport = onDeviceImport
    self.makeApp = makeApp
    self.afterLaunch = afterLaunch
  }
}

/// Where the sibling UI slices plug in (m3-10 on-device OCR, local store and analysis; m3-11 to m3-13 screens on top of
/// it). All nil in this slice. `slices/m3-14-mac-app-integration/MERGE.md` has the merge steps, file by file.
public struct CompositionSeams {
  /// On-device text reading for the composition's own recordings import.
  public var textRecognizer: (any TextRecognizer)?
  /// Where an import space goes when this Mac does not send.
  public var onDeviceImportSink: (any ImportSink)?
  /// m3-10's analysis: called before AppModel is built, with the live events and the one Never watch list.
  public var analysis: (@MainActor (AnalysisInputs) -> AnalysisPlug)?

  public init(textRecognizer: (any TextRecognizer)? = nil, onDeviceImportSink: (any ImportSink)? = nil,
              analysis: (@MainActor (AnalysisInputs) -> AnalysisPlug)? = nil) {
    self.textRecognizer = textRecognizer
    self.onDeviceImportSink = onDeviceImportSink
    self.analysis = analysis
  }
}

/// Everything the root reads from the Mac. `live()` fills it with the real pieces; tests with fakes.
@MainActor public struct CompositionEnvironment {
  public var uploadBackend: UploadBackend
  /// The one encrypted buffer (under `StoreLayout.defaultHome()`, Application Support/Offload), shared by capture,
  /// the uploader and the import outbox.
  public var store: StoreContext
  public var onboardingStore: OnboardingStore
  public var probe: PermissionProbe
  public var options: LaunchOptions
  public var bundlePath: String
  public var bufferReadable: Bool
  /// The server's "What leaves your Mac" version from `GET /v1/me`; nil until sign-in exists.
  public var currentNoticeVersion: String?
  public var loginItem: LoginItemService
  public var relauncher: Relauncher
  public var account: AccountService
  public var consent: ConsentService
  /// False in tests: capture never ticks and the uploader never takes a turn.
  public var timers: Bool

  public init(uploadBackend: UploadBackend, store: StoreContext, onboardingStore: OnboardingStore,
              probe: PermissionProbe, options: LaunchOptions, bundlePath: String, bufferReadable: Bool,
              currentNoticeVersion: String?, loginItem: LoginItemService, relauncher: Relauncher,
              account: AccountService, consent: ConsentService, timers: Bool = true) {
    self.uploadBackend = uploadBackend
    self.store = store
    self.onboardingStore = onboardingStore
    self.probe = probe
    self.options = options
    self.bundlePath = bundlePath
    self.bufferReadable = bufferReadable
    self.currentNoticeVersion = currentNoticeVersion
    self.loginItem = loginItem
    self.relauncher = relauncher
    self.account = account
    self.consent = consent
    self.timers = timers
  }
}

@MainActor public final class AppComposition {
  /// Builds the recordings model from the importer (nil until on-device OCR), its sink, its ledger and the one
  /// Never watch list.
  public typealias RecordingsBuilder =
    @MainActor (RecordingImporter?, (any ImportSink)?, (any RecordingLedger)?, NeverWatchStore) -> RecordingsImportModel?
  typealias UpdatesBuilder = @MainActor (UpdatePreparation) -> AppUpdates?

  /// Whether this Mac may upload (not the screens' BackendMode).
  public let uploadBackend: UploadBackend
  public let neverWatch: NeverWatchStore
  public let capture: CaptureRuntime
  /// Nil in Local mode: nothing exists that could send.
  public let uploads: UploadRuntime?
  public let importChoice: ImportSinkChoice
  /// An importer exists (m3-10's on-device text reading is plugged in).
  public let importerReady: Bool
  public let app: AppModel
  /// Sparkle (m3-03). Nil in tests.
  let updates: AppUpdates?

  init(environment env: CompositionEnvironment, seams: CompositionSeams = CompositionSeams(),
       recordings: RecordingsBuilder, updates makeUpdates: UpdatesBuilder) {
    uploadBackend = env.uploadBackend
    let neverWatch = NeverWatchStore()
    self.neverWatch = neverWatch
    let capture = CaptureRuntime(context: env.store, neverWatch: neverWatch, ticks: env.timers)
    self.capture = capture
    var uploads: UploadRuntime?
    if case .cloud(let apiBase, let deviceID) = env.uploadBackend {
      uploads = UploadRuntime(apiBase: apiBase, deviceID: deviceID, context: env.store, turns: env.timers)
    }
    self.uploads = uploads
    // Before an update: capture stops and the uploader pauses.
    updates = makeUpdates(UpdatePreparation(capture: capture, uploads: uploads))

    let saved = env.onboardingStore.load() ?? OnboardingState()
    let facts = LaunchFacts(state: saved, uploadsAvailable: uploads != nil, bufferReadable: env.bufferReadable,
                            currentNoticeVersion: env.currentNoticeVersion)
    let choice = LaunchPlan.decide(facts).importSink
    importChoice = choice
    var sink: (any ImportSink)? = seams.onDeviceImportSink
    if choice == .uploader, let uploads { sink = UploaderImportSink(queue: uploads) }
    // One masker for every import: the capture's pseudonym key, loaded on first use.
    let importMasker = capture.importMasker()
    var ledger: (any RecordingLedger)?
    var importer: RecordingImporter?
    if seams.textRecognizer != nil, sink != nil {
      // The store's one ledger, so "Start fresh" resets the instance the importer holds (review 4, finding 3).
      ledger = env.store.importLedger
      importer = ImportComposition.importer(recognizer: seams.textRecognizer, masker: importMasker, sink: sink,
                                            ledger: env.store.importLedger, neverWatch: neverWatch,
                                            protected: [env.store.home])
    }
    let plug = seams.analysis?(AnalysisInputs(neverWatch: neverWatch, events: capture.events,
                                              uploadBackend: env.uploadBackend, importMasker: importMasker,
                                              importLedger: env.store.importLedger))
    importerReady = importer != nil || plug?.recordings?.canImport == true

    let sampleWeek = SampleWeekFlag()
    let services = OnboardingServices(
      account: env.account, consent: env.consent, uploader: uploads ?? NoUploader(), capture: capture,
      profile: LocalProfileService(), neverWatch: neverWatch, exclusions: LocalExclusionService(),
      connections: UnavailableConnectionService(), loginItem: env.loginItem, relauncher: env.relauncher,
      sampleWeek: sampleWeek, recordings: plug?.recordings ?? recordings(importer, sink, ledger, neverWatch)
    )
    let parts = AppModelParts(
      options: env.options, bundlePath: env.bundlePath, bufferReadable: env.bufferReadable, store: env.onboardingStore,
      services: services, probe: env.probe, events: capture.events, sampleWeek: sampleWeek,
      currentNoticeVersion: env.currentNoticeVersion, uploadsAvailable: uploads != nil
    )
    app = plug?.makeApp?(parts) ?? parts.make()
    // Row 11.6 "Start fresh" deletes the unreadable buffer before setup starts over.
    let store = env.store
    app.onStartFresh = { try? store.discard() }
    // m3-10's start (insights, its follow of the Never watch list), then the one offer rule.
    plug?.afterLaunch?(app)
    // The offer rule follows where the import's data goes (ImportOffer), read live, replacing m3-04's
    // "while sending" default and any rule the analysis set.
    let uploadsAvailable = uploads != nil
    let hasOnDeviceSink = seams.onDeviceImportSink != nil || plug?.onDeviceImport == true
    let model = app
    model.recordings?.offerCheck = { [weak model] in
      guard let model else { return false }
      return ImportOffer.isOffered(choice: choice, hasOnDeviceSink: hasOnDeviceSink, uploadsAvailable: uploadsAvailable,
                                   state: model.onboarding.state)
    }
  }

  /// What the menu bar item says now about where data goes (ModeLines), from the live onboarding state.
  public var modeLines: [String] {
    let s = app.onboarding.state
    let sendingNow = uploadBackend.allowsUploads && s.sending && !s.reconsentPending
    return ModeLines.lines(local: !sendingNow, importerReady: importerReady,
                           importOffered: app.recordings?.isOffered ?? false, choice: importChoice)
  }

  /// The app as shipped: real permission checks, the Keychain, the store under Application Support/Offload, Sparkle.
  /// Sign-in, consent, profile and connections are still the local stand-ins (their backends land later), so the test
  /// build runs in Local mode and sends nothing.
  public static func live(arguments: [String] = ProcessInfo.processInfo.arguments,
                          seams: CompositionSeams = CompositionSeams()) -> AppComposition {
    let secrets = KeychainSecretStore()
    let store = StoreContext(home: StoreLayout.defaultHome(), secrets: secrets)
    let env = CompositionEnvironment(
      uploadBackend: UploadBackend.live(secrets: secrets), store: store,
      onboardingStore: UserDefaultsOnboardingStore(), probe: LivePermissionProbe(),
      options: LaunchOptions.parse(arguments: arguments), bundlePath: Bundle.main.bundlePath,
      bufferReadable: store.bufferReadable(),
      currentNoticeVersion: nil, loginItem: LiveLoginItem(), relauncher: LiveRelauncher(),
      account: UnavailableAccountService(), consent: LocalConsentService()
    )
    let root = AppComposition(
      environment: env, seams: seams,
      recordings: { liveRecordings(importer: $0, sink: $1, ledger: $2, neverWatch: $3) },
      updates: { AppUpdates(capture: $0) }
    )
    root.app.trackFrontmostApp()
    root.app.startBackgroundChecks()
    return root
  }

  /// m3-05's recordings model with the real folder, summary and picker, and this launch's importer and sink.
  static func liveRecordings(importer: RecordingImporter?, sink: (any ImportSink)?, ledger: (any RecordingLedger)?,
                             neverWatch: NeverWatchStore) -> RecordingsImportModel? {
    let fm = FileManager.default
    let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
    return RecordingsImportModel(
      store: UserDefaultsRecordingsFolderStore(), picker: LiveFolderPicker(), panel: LiveImportPanel(),
      importer: importer, sink: sink, ledger: ledger, durations: { AVRecordingFrameSource.duration(of: $0) },
      suggestedFolder: RecordingFolder.suggested(home: fm.homeDirectoryForCurrentUser, screencaptureLocation: location),
      protected: [StoreLayout.defaultHome()], neverWatch: neverWatch, appNames: { LiveAppNames.resolver(for: $0) }
    )
  }
}
