import Foundation
import Testing
@testable import OffloadMac
import OffloadImport

// How the sibling UI slices (m3-10 analysis, m3-11 Today, m3-12 Weekly review, m3-13 Build progress) plug into this
// composition root (review 4, finding 1; SPEC Scope changes, "Integration with m3-10 to m3-13").

extension M314 {
  /// Type names m3-10 declares in OffloadMac (its `Backend/` and `Analysis/` folders). In a file that imports
  /// OffloadUploader or OffloadContracts, a bare use would resolve to m3-10's type once the branches merge.
  static let namesM310Declares = ["HTTPTransport", "URLSessionTransport", "JCS", "JSONValue", "Figure"]

  @Test("ENTRY: the composition root leaves BackendMode to the screens and names other modules' types with their module")
  func mergeSafeNames() throws {
    let files = M314Fixture.swiftSources("Sources/OffloadMac/Composition")
    #expect(files.count >= 9)
    let bare = try NSRegularExpression(pattern: #"(?<![\w.])(HTTPTransport|URLSessionTransport|JCS|JSONValue|Figure)\b"#)
    let declares = try NSRegularExpression(pattern: #"\b(enum|struct|class|protocol|typealias)\s+BackendMode\b"#)
    for f in files {
      // Comments may name them; code may not, unqualified.
      let code = f.text.split(separator: "\n").map { line -> String in
        let s = String(line)
        guard let r = s.range(of: "//") else { return s }
        return String(s[..<r.lowerBound])
      }.joined(separator: "\n")
      let range = NSRange(code.startIndex..., in: code)
      #expect(bare.firstMatch(in: code, range: range) == nil, "bare type name from another module in \(f.path)")
      #expect(declares.firstMatch(in: code, range: range) == nil, "BackendMode declared in \(f.path)")
    }
    #expect(Self.namesM310Declares.count == 5)
  }

  @Test("LAUNCH: the analysis hook gets the live events and the one Never watch list, its recordings model is the app's, it runs after launch, and the offer rule stays the composition's")
  @MainActor func analysisHook() throws {
    var inputs: AnalysisInputs?
    var launched: [ObjectIdentifier] = []
    let model = RecordingsImportModel(
      store: MemoryRecordingsFolderStore(), picker: FakeFolderPicker(), panel: FakeImportPanel(), importer: nil,
      sink: nil, ledger: MemoryRecordingLedger(), durations: { _ in nil }, suggestedFolder: M314Fixture.tempHome(),
      protected: [])
    let seams = CompositionSeams(analysis: { given in
      inputs = given
      return AnalysisPlug(recordings: model, onDeviceImport: true, afterLaunch: { app in
        launched.append(ObjectIdentifier(app))
        // m3-10's own rule (RecordingsOffer) would say yes in Local mode; the composition's rule must win.
        app.recordings?.offerCheck = { true }
      })
    })
    let c = M314App.composition(state: M314State.fresh, seams: seams)
    defer { c.capture.stop() }
    let got = try #require(inputs)
    #expect(got.neverWatch === c.neverWatch)
    #expect((got.events as? StoreEventSource)?.handle === c.capture.store)
    #expect(got.uploadBackend == .local)
    #expect(c.app.recordings === model)
    #expect(launched == [ObjectIdentifier(c.app)])
    // Fresh state: before screen 2, so not offered, whatever the hook set.
    #expect(c.app.recordings?.isOffered == false)
    // Past screen 2 with an on-device import: offered.
    let later = M314App.composition(state: M314State.watchingLocally, seams: seams)
    defer { later.capture.stop() }
    #expect(later.app.recordings?.isOffered == true)
  }
}
