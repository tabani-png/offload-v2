// The capture half of the app (slice m3-02): wires the live sources to the observer and the uploader, and runs them on
// their cadence. The observer runs inside the app process (a child of the app for TCC attribution, spike S1); the app
// is started as a login item by SMAppService (the onboarding slice). No screens here: Onboarding, Today and "What was
// sent" are the M3 follow-up slice.
import Foundation
import OffloadContracts
import OffloadMasker
import OffloadObserver
import OffloadStore
import OffloadUploader

@MainActor public final class CaptureRuntime {
    public struct Settings: Sendable {
        public var apiBase: URL
        public var deviceID: String
        public var home: URL

        public init(apiBase: URL, deviceID: String, home: URL = StoreLayout.defaultHome()) {
            self.apiBase = apiBase
            self.deviceID = deviceID
            self.home = home
        }
    }

    public let observer: Observer
    public let uploader: Uploader
    public let pause: LivePauseSource
    public let ledger: EgressLedger
    public let reveals: RevealMap

    private var observerTimer: Timer?
    private var uploadTimer: Timer?
    private var ticking = false

    /// Everything real: the Keychain, the encrypted store under `home`, the device key, the one API host.
    public init(settings: Settings, secrets: any SecretStore = KeychainSecretStore()) throws {
        let layout = StoreLayout(home: settings.home)
        try layout.ensureDirectories()
        let days = DayCalendar()
        let keys = KeyRing(layout: layout, secrets: secrets)
        let store = DayStore(layout: layout, keys: keys, days: days)
        let time = SystemTime()
        let pseudonymKey = try PseudonymKeyStore(secrets: secrets).loadOrCreate()
        let reveals = RevealMap(layout: layout, keys: keys, days: days)
        let pause = LivePauseSource()
        observer = Observer(
            time: time, days: days, workspace: LiveWorkspace(), idle: LiveIdle(), power: LivePower(), permissions: LivePermissions(),
            pause: pause, ax: LiveAXText(), ocr: LiveOCR(), exclusions: ExclusionReloader(file: layout.exclusionsFile, time: time),
            masker: TextMasker(pseudonymizer: Pseudonymizer(key: pseudonymKey)), sink: store, reveals: reveals,
            retention: Retention(layout: layout, days: days))
        let ledger = EgressLedger(layout: layout, keys: keys, days: days)
        let signer = try DeviceKey.loadOrCreate(secrets: secrets).signer
        let transport = URLSessionTransport()
        let guarded = GuardedTransport(inner: transport, guard: EgressGuard(apiBase: settings.apiBase))
        let session = DeviceSession(apiBase: settings.apiBase, deviceID: settings.deviceID, signer: signer, transport: guarded, time: time)
        uploader = Uploader(
            config: UploaderConfig(apiBase: settings.apiBase, deviceID: settings.deviceID), transport: transport, signer: signer,
            tokens: session, store: store, state: UploadStateStore(layout: layout, keys: keys), ledger: ledger, time: time)
        self.pause = pause
        self.ledger = ledger
        self.reveals = reveals
    }

    /// Ticks the observer once a second and offers the uploader a turn every 30 seconds (it sends every 300 s itself).
    public func start() {
        guard observerTimer == nil else { return }
        observerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.ticking else { return }
                self.ticking = true
                Task { @MainActor in
                    await self.observer.tick()
                    self.ticking = false
                }
            }
        }
        uploadTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let uploader = self?.uploader else { return }
                Task { _ = await uploader.tick() }
            }
        }
    }

    /// Stops the timers; with `flush`, sends what is pending first (the app calls this on quit).
    public func stop(flush: Bool) async {
        observerTimer?.invalidate()
        uploadTimer?.invalidate()
        observerTimer = nil
        uploadTimer = nil
        if flush { _ = await uploader.flush() }
    }
}
