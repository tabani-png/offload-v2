// The encrypted local buffer, built once by the composition root and shared by capture, the uploader and the import
// outbox (slice m3-14-mac-app-integration, review 1). One KeyRing means one master key and one key cache: two rings
// over the same Keychain could each create a master key on a fresh Mac and lose whatever was sealed under the other.
// Building this writes nothing and never touches the Keychain: the one read is the import ledger's file (if it
// exists), which m3-05's ledger loads when it is made. The Keychain and every write wait for the first use, after
// consent.
import Foundation
import OffloadContracts
import OffloadImport
import OffloadStore
import OffloadUploader

public final class StoreContext: Sendable {
  public let layout: StoreLayout
  public let secrets: any SecretStore
  public let keys: KeyRing
  public let days: DayCalendar
  public let dayStore: DayStore
  public let importOutbox: ImportOutbox
  /// Which recordings were read: the one instance the importer holds, so "Start fresh" resets it too.
  public let importLedger: ResettableImportLedger

  public init(home: URL = StoreLayout.defaultHome(), secrets: any SecretStore, days: DayCalendar = DayCalendar()) {
    let layout = StoreLayout(home: home)
    let keys = KeyRing(layout: layout, secrets: secrets)
    self.layout = layout
    self.secrets = secrets
    self.keys = keys
    self.days = days
    dayStore = DayStore(layout: layout, keys: keys, days: days)
    importOutbox = ImportOutbox(layout: layout, keys: keys)
    importLedger = ResettableImportLedger(file: layout.home.appendingPathComponent("import-ledger.json"))
  }

  public var home: URL { layout.home }

  /// Which recordings were read (m3-05's fingerprint ledger), next to the buffer.
  public var importLedgerFile: URL { importLedger.file }

  /// Row 11.6: false when day files exist but the master key is gone or the newest day key no longer opens (a restore
  /// or a new Mac without the Keychain). With no day files there is nothing to open, so it is readable. Never writes:
  /// the master key is read, not created. A Keychain that cannot be read right now (locked, access denied) is not
  /// "unreadable", so "Start fresh" is never offered over a buffer that is fine. Reads the Keychain only when day
  /// files exist, that is after capture was consented.
  public func bufferReadable() -> Bool {
    guard let newest = dayStore.storedDays().last else { return true }
    let master: Data?
    do { master = try secrets.read(account: KeyRing.masterAccount) } catch { return true }
    guard let master, master.count == StoreCrypto.keySize else { return false }
    return (try? keys.dayKey(domain: .days, day: newest, create: false)) != nil
  }

  /// "Start fresh" (row 11.6): deletes the unreadable buffer (day files, their keys, the egress ledger, the reveal
  /// map, the upload queue, the import outbox and the import ledger, so recordings whose objects went with the outbox
  /// can be imported again). The master key stays; new day keys are wrapped under it.
  public func discard() throws {
    let fm = FileManager.default
    for url in [layout.daysDir, layout.keysDir, layout.egressDir, layout.revealFile, layout.uploadStateFile,
                importOutbox.file] where fm.fileExists(atPath: url.path) {
      try fm.removeItem(at: url)
    }
    // The file and the entries the running importer holds (m3-05's ledger loads its file once).
    try importLedger.reset()
    keys.forget()
  }
}

/// m3-05's file ledger behind a lock, replaceable in place: `reset()` deletes the file and starts an empty ledger in the
/// same object, so the importer that holds it forgets every entry (review 4, finding 3).
public final class ResettableImportLedger: RecordingLedger, @unchecked Sendable {
  public let file: URL
  private let lock = NSLock()
  private var inner: FileRecordingLedger

  public init(file: URL) {
    self.file = file
    inner = FileRecordingLedger(file: file)
  }

  public func contains(_ fingerprint: String) -> Bool { lock.withLock { inner.contains(fingerprint) } }

  public func record(_ entry: RecordingLedgerEntry) throws { try lock.withLock { try inner.record(entry) } }

  public func removeEntries(importID: String) throws { try lock.withLock { try inner.removeEntries(importID: importID) } }

  public var entries: [RecordingLedgerEntry] { lock.withLock { inner.entries } }

  public func reset() throws {
    try lock.withLock {
      if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
      inner = FileRecordingLedger(file: file)
    }
  }
}
