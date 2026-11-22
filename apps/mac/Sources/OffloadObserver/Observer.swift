// The Observer state machine (ARCHITECTURE section 1, ADR 0006). The app calls `tick()` about once a second; tests drive it
// with a ManualTime and scripted sources. It never touches the network: it masks, then appends to the encrypted day store.
//
//  focus        NSWorkspace activation plus a 2 s poll for title and URL
//  text         bounded Accessibility walk on focus change and at most every 30 s, written only when its hash changed;
//               OCR only when the walk yields under 200 characters, at most once per 30 s per window, never on a
//               battery below 20% and never without Screen Recording
//  idle         after 120 s without input
//  pause        screen lock, sleep, fast user switch: `pause`/`resume` with a reason, nothing written in between
//  permissions  checked every 5 s; a change is recorded as `permission_change`
import CryptoKit
import Foundation
import OffloadContracts
import OffloadMasker
import OffloadStore

public struct ObserverConfig: Equatable, Sendable {
    public var focusPoll: TimeInterval = 2
    public var idleThreshold: TimeInterval = 120
    public var textInterval: TimeInterval = 30
    public var ocrInterval: TimeInterval = 30
    public var ocrBelowCharacters = 200
    public var ocrMinBattery = 0.20
    public var permissionInterval: TimeInterval = 5
    public var purgeInterval: TimeInterval = 3600

    public init() {}
}

public struct ObserverCounters: Equatable, Sendable {
    public var written = 0
    public var writeErrors = 0
    public var ocrErrors = 0
    public var ocrRuns = 0
    public var skippedUnchanged = 0
    public var skippedExcluded = 0
    public var skippedSecureInput = 0
}

@MainActor public final class Observer {
    public let config: ObserverConfig
    public private(set) var counters = ObserverCounters()
    public private(set) var isPaused = false
    public private(set) var isIdle = false

    private let time: any TimeSource
    private let days: DayCalendar
    private let workspace: any WorkspaceSource
    private let idle: any IdleSource
    private let power: any PowerSource
    private let permissions: any PermissionSource
    private let pause: any PauseSource
    private let ax: (any AXTextSource)?
    private let ocr: (any OCRSource)?
    private let exclusions: ExclusionReloader
    private let masker: TextMasker
    private let sink: any ObservationSink
    private let reveals: RevealMap?
    private let retention: Retention?
    private let ids: ULIDGenerator

    private struct FocusKey: Equatable {
        var bundleID: String
        var title: String?
        var host: String?
        var doc: String?
        var excluded: Bool
    }

    private var lastFocus: FocusKey?
    private var lastFocusPoll: Date?
    private var lastTextCheck: Date?
    private var lastTextKey: String?
    private var lastOCR: [String: Date] = [:]
    private var lastPermissionCheck: Date?
    private var lastPermission: PermissionState?
    private var lastPurge: Date?
    private var pausedFor: PauseReason?
    private var pendingReveals: [String: String] = [:]

    public init(config: ObserverConfig = ObserverConfig(), time: any TimeSource, days: DayCalendar, workspace: any WorkspaceSource,
                idle: any IdleSource, power: any PowerSource, permissions: any PermissionSource, pause: any PauseSource,
                ax: (any AXTextSource)?, ocr: (any OCRSource)?, exclusions: ExclusionReloader, masker: TextMasker,
                sink: any ObservationSink, reveals: RevealMap?, retention: Retention?, ids: ULIDGenerator = ULIDGenerator()) {
        self.config = config
        self.time = time
        self.days = days
        self.workspace = workspace
        self.idle = idle
        self.power = power
        self.permissions = permissions
        self.pause = pause
        self.ax = ax
        self.ocr = ocr
        self.exclusions = exclusions
        self.masker = masker
        self.sink = sink
        self.reveals = reveals
        self.retention = retention
        self.ids = ids
    }

    public func tick() async {
        let now = time.now
        defer { flushReveals(at: now) }
        runRetentionIfDue(now)
        let policy = exclusions.policy(now: now)

        // Pause first: while paused nothing is read and nothing is written.
        let wanted = pause.current
        if wanted != pausedFor {
            if let reason = wanted {
                write(.pause(ObservationPause(id: newID(now), ts: Timestamp.format(now), reason: Self.reason(reason))))
                isPaused = true
            } else if let was = pausedFor {
                write(.resume(ObservationResume(id: newID(now), ts: Timestamp.format(now), reason: Self.reason(was))))
                isPaused = false
            }
            pausedFor = wanted
            resetObservation()
        }
        if isPaused { return }

        checkPermissions(now)
        checkIdle(now)

        var focusChanged = false
        var snapshot: FocusSnapshot?
        if lastFocusPoll.map({ now.timeIntervalSince($0) >= config.focusPoll }) ?? true {
            lastFocusPoll = now
            snapshot = workspace.frontmost()
            if let snap = snapshot { focusChanged = pollFocus(snap, policy: policy, now: now) }
        } else {
            snapshot = workspace.frontmost()
        }
        guard let snap = snapshot else { return }
        await captureText(snap, policy: policy, now: now, focusChanged: focusChanged)
    }

    // MARK: pause, idle, permissions

    private static func reason(_ r: PauseReason) -> ObservationReason {
        switch r {
        case .user: return .user
        case .lock: return .lock
        case .sleep: return .sleep
        }
    }

    private func resetObservation() {
        lastFocus = nil
        lastFocusPoll = nil
        lastTextCheck = nil
        lastTextKey = nil
        lastOCR = [:]
    }

    private func checkIdle(_ now: Date) {
        let seconds = idle.secondsSinceLastInput()
        if !isIdle && seconds >= config.idleThreshold {
            isIdle = true
            write(.idleStart(ObservationIdleStart(id: newID(now), ts: Timestamp.format(now))))
        } else if isIdle && seconds < config.idleThreshold {
            isIdle = false
            write(.idleEnd(ObservationIdleEnd(id: newID(now), ts: Timestamp.format(now))))
        }
    }

    private func checkPermissions(_ now: Date) {
        guard lastPermissionCheck.map({ now.timeIntervalSince($0) >= config.permissionInterval }) ?? true else { return }
        lastPermissionCheck = now
        let state = permissions.current()
        defer { lastPermission = state }
        // The first reading is the baseline, not a change.
        guard let before = lastPermission, before != state else { return }
        write(.permissionChange(ObservationPermissionChange(
            id: newID(now), ts: Timestamp.format(now),
            perm: ObservationPerm(screenRecording: state.screenRecording, accessibility: state.accessibility))))
    }

    // MARK: focus

    /// Writes a focus observation when the window, its masked title, host or document changed. Returns true when it did.
    private func pollFocus(_ snap: FocusSnapshot, policy: ExclusionPolicy, now: Date) -> Bool {
        var key = FocusKey(bundleID: snap.bundleID, title: nil, host: nil, doc: nil, excluded: true)
        if policy.evaluate(snap) == nil {
            let title = masker.maskTitle(snap.windowTitle)
            note(title.reveals)
            let parts = snap.url.flatMap { masker.maskURL($0) }
            if let parts { note(parts.reveals) }
            key = FocusKey(bundleID: snap.bundleID, title: title.text.isEmpty ? nil : title.text, host: parts?.host, doc: parts?.doc, excluded: false)
        }
        guard key != lastFocus else { return false }
        lastFocus = key
        write(.focus(ObservationFocus(
            id: newID(now), ts: Timestamp.format(now), appBundleId: String(snap.bundleID.prefix(255)),
            appName: String(snap.appName.prefix(256)), title: key.title, host: key.host, doc: key.doc)))
        return true
    }

    // MARK: text

    private func captureText(_ snap: FocusSnapshot, policy: ExclusionPolicy, now: Date, focusChanged: Bool) async {
        guard !isIdle else { return }
        if policy.evaluate(snap) != nil { counters.skippedExcluded += 1; return }
        // A password field has focus: nothing is read, and the next check after it clears is due at once.
        if snap.secureInputActive { counters.skippedSecureInput += 1; return }
        let due = focusChanged || lastTextCheck.map { now.timeIntervalSince($0) >= config.textInterval } ?? true
        guard due else { return }
        lastTextCheck = now

        var raw = ax?.axText(of: snap)?.text ?? ""
        var source = ObservationTextSource.ax
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).count < config.ocrBelowCharacters, let ocr, ocrAllowed(snap, now: now) {
            lastOCR[Self.windowKey(snap)] = now
            counters.ocrRuns += 1
            do {
                if let text = try await ocr.ocrText(of: snap), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    raw = text
                    source = .ocr
                }
            } catch {
                counters.ocrErrors += 1
            }
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let masked = masker.mask(raw)
        let text = masked.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let hash = sha256Hex(text)
        let key = snap.bundleID + "|" + hash
        guard key != lastTextKey else { counters.skippedUnchanged += 1; return }
        lastTextKey = key
        note(masked.reveals)
        write(.textSnapshot(ObservationTextSnapshot(
            id: newID(now), ts: Timestamp.format(now), appBundleId: String(snap.bundleID.prefix(255)), text: text, textHash: hash,
            textSource: source)))
    }

    private static func windowKey(_ snap: FocusSnapshot) -> String { snap.bundleID + "|" + snap.windowTitle }

    private func ocrAllowed(_ snap: FocusSnapshot, now: Date) -> Bool {
        let granted = lastPermission?.screenRecording ?? permissions.current().screenRecording
        guard granted else { return false }
        if let battery = power.batteryFraction, battery < config.ocrMinBattery { return false }
        if let last = lastOCR[Self.windowKey(snap)], now.timeIntervalSince(last) < config.ocrInterval { return false }
        return true
    }

    // MARK: retention, writes

    private func runRetentionIfDue(_ now: Date) {
        guard lastPurge.map({ now.timeIntervalSince($0) >= config.purgeInterval }) ?? true else { return }
        lastPurge = now
        _ = try? retention?.purge(now: now)
        _ = try? reveals?.purge(now: now)
    }

    private func note(_ values: [String: String]) {
        for (k, v) in values { pendingReveals[k] = v }
    }

    private func flushReveals(at now: Date) {
        guard !pendingReveals.isEmpty else { return }
        defer { pendingReveals = [:] }
        try? reveals?.record(pendingReveals, at: now)
    }

    private func newID(_ now: Date) -> String { ids.next(millis: Timestamp.millis(now)) }

    private func write(_ observation: Observation) {
        do {
            try sink.append(observation)
            counters.written += 1
        } catch {
            counters.writeErrors += 1
        }
    }

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
