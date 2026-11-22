// The one composition root of the Offload app (slice m3-14-mac-app-integration). OffloadApp asks `live()` once; no
// other file builds AppModel, AppUpdates, CaptureRuntime or UploadRuntime (test ENTRY). The order of launch is here:
//
// 1. BackendMode: `.local` unless this Mac is enrolled (the test build is `.local`).
// 2. One NeverWatchStore for the screens, the menu bar, the observer (through its exclusions file) and the import.
// 3. CaptureRuntime (built on its first start, not before) and, only in `.cloud`, UploadRuntime.
// 4. The updater (m3-03), before any scene as before, with an UpdatePreparation over that same capture and uploader.
// 5. The recordings import with the sink the launch facts allow (the uploader when sending, else m3-10's on-device
//    sink when it exists) and the real masker; no importer until m3-10's on-device text reading exists.
// 6. AppModel: reads both permissions, checks the notice version, then starts capture and the uploader per LaunchPlan.
import AppKit
import Foundation
import OffloadImport
import OffloadStore

/// Where m3-10 (on-device OCR, local analysis store; sibling branch) plugs in. Both nil in this slice.
public struct CompositionSeams {
  /// On-device text reading for the recordings import (m3-10).
  public var textRecognizer: (any TextRecognizer)?
  /// Where an import space goes when this Mac does not send (m3-10's local store).
  public var onDeviceImportSink: (any ImportSink)?

  public init(textRecognizer: (any TextRecognizer)? = nil, onDeviceImportSink: (any ImportSink)? = nil) {
    self.textRecognizer = textRecognizer
    self.onDeviceImportSink = onDeviceImportSink
  }
}

/// Everything the root reads from the Mac. `live()` fills it with the real pieces; tests with fakes.
@MainActor public struct CompositionEnvironment {
  public var backend: BackendMode
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

  public init(backend: BackendMode, store: StoreContext, onboardingStore: OnboardingStore,
              probe: PermissionProbe, options: LaunchOptions, bundlePath: String, bufferReadable: Bool,
              currentNoticeVersion: String?, loginItem: LoginItemService, relauncher: Relauncher,
              account: AccountService, consent: ConsentService, timers: Bool = true) {
    self.backend = backend
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

  public let backend: BackendMode
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
    backend = env.backend
    let neverWatch = NeverWatchStore()
    self.neverWatch = neverWatch
    let capture = CaptureRuntime(context: env.store, neverWatch: neverWatch, ticks: env.timers)
    self.capture = capture
    var uploads: UploadRuntime?
    if case .cloud(let apiBase, let deviceID) = env.backend {
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
    var ledger: (any RecordingLedger)?
    var importer: RecordingImporter?
    if seams.textRecognizer != nil, sink != nil {
      let fileLedger = FileRecordingLedger(file: env.store.importLedgerFile)
      ledger = fileLedger
      importer = ImportComposition.importer(recognizer: seams.textRecognizer, masker: capture.importMasker(), sink: sink,
                                            ledger: fileLedger, neverWatch: neverWatch, protected: [env.store.home])
    }
    importerReady = importer != nil

    let sampleWeek = SampleWeekFlag()
    let services = OnboardingServices(
      account: env.account, consent: env.consent, uploader: uploads ?? NoUploader(), capture: capture,
      profile: LocalProfileService(), neverWatch: neverWatch, exclusions: LocalExclusionService(),
      connections: UnavailableConnectionService(), loginItem: env.loginItem, relauncher: env.relauncher,
      sampleWeek: sampleWeek, recordings: recordings(importer, sink, ledger, neverWatch)
    )
    app = AppModel(
      options: env.options, bundlePath: env.bundlePath, bufferReadable: env.bufferReadable, store: env.onboardingStore,
      services: services, probe: env.probe, events: capture.events, sampleWeek: sampleWeek,
      currentNoticeVersion: env.currentNoticeVersion, uploadsAvailable: uploads != nil
    )
    // Row 11.6 "Start fresh" deletes the unreadable buffer before setup starts over.
    let store = env.store
    app.onStartFresh = { try? store.discard() }
    // The offer rule follows where the import's data goes (ImportOffer), read live, replacing m3-04's
    // "while sending" default.
    let uploadsAvailable = uploads != nil
    let hasOnDeviceSink = seams.onDeviceImportSink != nil
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
    let sendingNow = backend.allowsUploads && s.sending && !s.reconsentPending
    return ModeLines.lines(local: !sendingNow, importerReady: importerReady,
                           importOffered: app.recordings?.isOffered ?? false)
  }

  /// The app as shipped: real permission checks, the Keychain, the store under Application Support/Offload, Sparkle.
  /// Sign-in, consent, profile and connections are still the local stand-ins (their backends land later), so the test
  /// build runs in Local mode and sends nothing.
  public static func live(arguments: [String] = ProcessInfo.processInfo.arguments,
                          seams: CompositionSeams = CompositionSeams()) -> AppComposition {
    let secrets = KeychainSecretStore()
    let store = StoreContext(home: StoreLayout.defaultHome(), secrets: secrets)
    let env = CompositionEnvironment(
      backend: BackendMode.live(info: Bundle.main.infoDictionary, secrets: secrets), store: store,
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
