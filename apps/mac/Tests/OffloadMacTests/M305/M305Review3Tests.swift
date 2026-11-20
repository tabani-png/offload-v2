import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Review 3 (logs/m3-05-recordings-import.review3.md): app names are looked up when each import starts, from the Never
// watch list as it is then; a rule carries every name an app is shown by (localized ones too); the refresh when the
// import becomes offered is the model's rule.
extension M305 {
  // MARK: EXCLUDE (finding 1)

  @Test("EXCLUDE: an app added to Never watch after the model was built (screen 9 in first-run setup) is excluded by its name")
  @MainActor func appAddedAfterTheModelWasBuilt() async throws {
    let folder = M305Files.folder("Desktop")
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "ledger.mov")
    var fakes = M305Importer()
    fakes.scripts["ledger.mov"] = M305Script(id: "ledger.mov", duration: 20, scenes: [
      M305Scene(at: 0, lines: m305Screen(app: "Acme Ledger", menus: "File Edit View", body: "Balance owed"), hash: 0),
    ])
    let store = NeverWatchStore()
    let lookups = M305EventLog()
    let ui = M305UI()
    let model = ui.model(importer: fakes, suggested: folder, neverWatch: store, appNames: { ids in
      lookups.add(ids.sorted().joined(separator: ","))
      let table: [String: [String]] = ["org.example.ledger": ["Acme Ledger"]]
      return { table[$0] ?? [] }
    })
    #expect(lookups.all.isEmpty)
    // Screen 9, after launch: the person names an app that is in no built-in table.
    store.add([Exclusion(kind: .bundleID, value: "org.example.ledger")])
    let started = await model.startImport()
    #expect(started)
    await model.waitForImport()
    #expect(lookups.all.count == 1)
    #expect(lookups.all.first?.contains("org.example.ledger") == true)
    let space = try #require(model.imports.first?.space)
    let obs = fakes.sink.observations(in: space.id)
    #expect(obs.filter { $0.kind == .textSnapshot }.isEmpty)
    #expect(obs.contains { $0.kind == .focus && $0.appName == "Acme Ledger" })
    #expect(fakes.keyframes.all.isEmpty)
  }

  // MARK: EXCLUDE (finding 2)

  @Test("EXCLUDE: a rule carries every name an app shows; a German menu bar (Fotos Ablage Bearbeiten) is matched")
  func localizedNames() throws {
    let rule = ImportExclusionRule(kind: .bundleID, value: "com.apple.Photos", appNames: ["Photos", "Fotos"])
    let german = m305Screen(app: "Fotos", menus: "Ablage Bearbeiten Bild Darstellung Fenster Hilfe", body: "Urlaub am Meer")
    #expect(MenuBarApp.name(from: german, frameHeight: 800) == "Fotos")
    let r = try M305.ingest(M305.oneScene("fotos", german), rules: [rule])
    #expect(M305.of(.textSnapshot, r).isEmpty)
    #expect(M305.of(.focus, r).map(\.appName) == ["Fotos"])
    // The adapter keeps every name the lookup gives.
    let store = NeverWatchStore()
    store.add([Exclusion(kind: .bundleID, value: "com.apple.Photos")])
    let rules = NeverWatchImportExclusions(source: store, appNames: { $0 == "com.apple.Photos" ? ["Fotos", "Photos"] : [] }).currentRules()
    #expect(rules.contains(ImportExclusionRule(kind: .bundleID, value: "com.apple.Photos", appNames: ["Fotos", "Photos"])))
  }

  @Test("EXCLUDE: with a name lookup, the built-in password and banking apps are matched by their localized names too")
  func builtInsByLocalizedName() throws {
    let rules = NeverWatchImportExclusions(source: NeverWatchStore(), appNames: {
      $0 == "com.apple.keychainaccess" ? ["Schlüsselbundverwaltung"] : []
    }).currentRules()
    #expect(rules.contains { $0.value == "com.apple.keychainaccess" && $0.appNames == ["Schlüsselbundverwaltung"] })
    let screen = m305Screen(app: "Schlüsselbundverwaltung", menus: "Ablage Bearbeiten Darstellung Fenster Hilfe", body: "Kennwort")
    let r = try M305.ingest(M305.oneScene("keychain", screen), rules: rules)
    #expect(M305.of(.textSnapshot, r).isEmpty)
    // Without a lookup no rule is added for the built-ins (they are matched by bundle id and English name).
    #expect(NeverWatchImportExclusions(source: NeverWatchStore(builtIn: [])).currentRules().isEmpty)
  }

  // MARK: SCREEN (finding 3)

  @Test("SCREEN: when the import becomes offered the folder is read once; while not offered, never")
  @MainActor func offerChangedReadsOnce() async {
    let suggested = M305Files.folder("Desktop")
    defer { M305Files.remove(suggested) }
    M305Files.put(suggested, "Screen Recording 2026-11-05 at 9.00.00 AM.mov")
    let reads = M305Counter()
    let ui = M305UI()
    let model = ui.model(importer: nil, suggested: suggested, offered: false, durations: { _ in
      reads.bump()
      return 600
    })
    await model.offerChanged()
    #expect(reads.count == 0)
    model.offerCheck = { true }
    await model.offerChanged()
    #expect(reads.count == 1)
    #expect(model.summary?.files == 1)
    await model.offerChanged()
    #expect(reads.count == 1)
  }
}
