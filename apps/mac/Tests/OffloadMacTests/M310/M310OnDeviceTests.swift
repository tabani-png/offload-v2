import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// OnDevice/: Vision OCR, the interim masker, the local import sink and the default recordings folders.
extension M310 {
  // MARK: OCR

  @Test("OCR: a Vision box becomes a top-left pixel box (corners, the full frame, a centred box)")
  func visionBoxes() {
    #expect(VisionBoxes.topLeft(CGRect(x: 0, y: 0, width: 1, height: 1), width: 1280, height: 800)
      == OCRBox(x: 0, y: 0, width: 1280, height: 800))
    // Vision's bottom-left quarter is the frame's lower left: y starts half way down.
    #expect(VisionBoxes.topLeft(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), width: 1280, height: 800)
      == OCRBox(x: 0, y: 400, width: 640, height: 400))
    #expect(VisionBoxes.topLeft(CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), width: 1280, height: 800)
      == OCRBox(x: 0, y: 0, width: 640, height: 400))
    #expect(VisionBoxes.topLeft(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), width: 1280, height: 800)
      == OCRBox(x: 320, y: 200, width: 640, height: 400))
  }

  @Test("OCR: a CoreText-rendered INVOICE 2041 READY is read by Vision with the words in order and boxes inside the frame")
  func visionReadsRenderedText() throws {
    let width = 900
    let height = 220
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "INVOICE 2041 READY", attributes: attributes))
    ctx.textPosition = CGPoint(x: 40, y: 80)
    CTLineDraw(line, ctx)
    let image = try #require(ctx.makeImage())

    let lines = try VisionTextRecognizer().recognize(ImportFrame(image: image, tag: "rendered"))
    let text = lines.map(\.text).joined(separator: " ").uppercased()
    let invoice = try #require(text.range(of: "INVOICE"))
    let number = try #require(text.range(of: "2041"))
    let ready = try #require(text.range(of: "READY"))
    #expect(invoice.upperBound <= number.lowerBound)
    #expect(number.upperBound <= ready.lowerBound)
    for l in lines {
      #expect(l.box.x >= -1 && l.box.y >= -1)
      #expect(l.box.x + l.box.width <= Double(width) + 1)
      #expect(l.box.y + l.box.height <= Double(height) + 1)
    }
  }

  @Test("OCR: a frame without an image gives no lines")
  func noImageNoLines() throws {
    #expect(try VisionTextRecognizer().recognize(ImportFrame(width: 1280, height: 800, tag: "empty")).isEmpty)
  }

  @Test("OCR: lines come top to bottom, then left to right")
  func linesInReadingOrder() {
    let lines = [
      OCRLine(text: "C", box: OCRBox(x: 5, y: 100, width: 50, height: 16)),
      OCRLine(text: "B", box: OCRBox(x: 500, y: 10, width: 50, height: 16)),
      OCRLine(text: "A", box: OCRBox(x: 10, y: 13, width: 50, height: 16)),
      OCRLine(text: "D", box: OCRBox(x: 400, y: 101, width: 50, height: 16)),
    ]
    #expect(VisionBoxes.ordered(lines).map(\.text) == ["A", "B", "C", "D"])
  }

  @Test("OCR: the request is accurate, with language correction, in the four menu bar languages")
  func requestSettings() {
    let r = VisionTextRecognizer().makeRequest()
    #expect(r.recognitionLevel == .accurate)
    #expect(r.usesLanguageCorrection)
    #expect(r.recognitionLanguages == ["en-US", "de-DE", "fr-FR", "es-ES"])
  }

  // MARK: MASK

  @Test("MASK: a URL keeps its host, the path becomes a doc pseudonym, query and fragment are dropped")
  func maskURL() {
    let m = InterimTextMasker(key: m310Key)
    let doc = m.pseudonym("doc", "mail.example.com/inbox/42")
    #expect(m.mask("see https://Mail.Example.com/inbox/42?token=abc#x now") == "see https://mail.example.com/\(doc) now")
    #expect(m.mask("at https://example.com?q=1#top.") == "at https://example.com.")
    #expect(doc.hasPrefix("<doc:h_") && doc.count == "<doc:h_>".count + 16)
  }

  @Test("MASK: a bare host and path is masked the same way")
  func maskBareHostPath() {
    let m = InterimTextMasker(key: m310Key)
    let doc = m.pseudonym("doc", "github.com/acme/app/pull/41")
    #expect(m.mask("open github.com/acme/app/pull/41 later") == "open github.com/\(doc) later")
  }

  @Test("MASK: API keys (sk- and sk-ant-) become [SECRET]")
  func maskModelKeys() {
    let m = InterimTextMasker(key: m310Key)
    #expect(m.mask("key sk-ant-api03-AbCdEf0123456789xyz end") == "key [SECRET] end")
    #expect(m.mask("old sk-proj0123456789abcdefGHIJ") == "old [SECRET]")
  }

  @Test("MASK: GitHub tokens (ghp_, gho_, github_pat_) become [SECRET]")
  func maskGitHubTokens() {
    let m = InterimTextMasker(key: m310Key)
    #expect(m.mask("t ghp_" + String(repeating: "aB3", count: 12)) == "t [SECRET]")
    #expect(m.mask("t gho_" + String(repeating: "Zz9", count: 8)) == "t [SECRET]")
    #expect(m.mask("t github_pat_" + String(repeating: "Q1_", count: 10)) == "t [SECRET]")
  }

  @Test("MASK: Slack tokens and AWS access key ids become [SECRET]")
  func maskSlackAndAWS() {
    let m = InterimTextMasker(key: m310Key)
    #expect(m.mask("bot xoxb-123456789012-abcdefABCDEF here") == "bot [SECRET] here")
    #expect(m.mask("aws AKIAABCDEFGHIJKLMNOP here") == "aws [SECRET] here")
  }

  @Test("MASK: a JWT becomes [SECRET]")
  func maskJWT() {
    let m = InterimTextMasker(key: m310Key)
    #expect(m.mask("auth eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dGVzdHNpZ25hdHVyZQ ok") == "auth [SECRET] ok")
  }

  @Test("MASK: a private key block becomes [SECRET]")
  func maskPrivateKey() {
    let m = InterimTextMasker(key: m310Key)
    let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1b2c3\nabcDEF==\n-----END RSA PRIVATE KEY-----"
    #expect(m.mask("before\n\(pem)\nafter") == "before\n[SECRET]\nafter")
  }

  @Test("MASK: a run of 32 or more key characters mixing letters and digits becomes [SECRET]; letters alone stay")
  func maskLongMixedRun() {
    let m = InterimTextMasker(key: m310Key)
    #expect(m.mask("id a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8 end") == "id [SECRET] end")
    let letters = String(repeating: "abcdefghij", count: 4)
    #expect(m.mask(letters) == letters)
  }

  @Test("MASK: a Luhn card with spaces or dashes becomes [CARD NO.]; a 16-digit run failing Luhn is [ACCT NO.]")
  func maskCards() {
    let m = InterimTextMasker(key: m310Key)
    #expect(m.mask("card 4111 1111 1111 1111 exp") == "card [CARD NO.] exp")
    #expect(m.mask("card 5500-0055-5555-5559.") == "card [CARD NO.].")
    #expect(m.mask("ref 1234567812345678 x") == "ref [ACCT NO.] x")
  }

  @Test("MASK: a 6 or 7 digit code becomes [OTP]; 8 or more digits are an account number")
  func maskCodes() {
    let m = InterimTextMasker(key: m310Key)
    #expect(m.mask("Your code is 482913.") == "Your code is [OTP].")
    #expect(m.mask("code 1234567 now") == "code [OTP] now")
    #expect(m.mask("acct 12345678") == "acct [ACCT NO.]")
    #expect(m.mask("iban 1234 5678 9012") == "iban [ACCT NO.]")
  }

  @Test("MASK: times, dates and amounts with separators stay as they are")
  func maskKeepsTimesDatesAmounts() {
    let m = InterimTextMasker(key: m310Key)
    let text = "Meeting at 4:00 on 2026-11-22, 1,284 moments, $12.50, Q4 2026"
    #expect(m.mask(text) == text)
  }

  @Test("MASK: emails and phones become stable pseudonyms (same value same, other key other, email case-insensitive)")
  func maskEmailAndPhone() {
    let m = InterimTextMasker(key: m310Key)
    let email = m.pseudonym("email", "amara.okafor@example.com")
    #expect(m.mask("Write to Amara.Okafor@Example.com today") == "Write to \(email) today")
    #expect(m.mask("amara.okafor@example.com") == email)
    let other = InterimTextMasker(key: Data(repeating: 9, count: 32))
    #expect(other.mask("amara.okafor@example.com") != email)
    #expect(m.mask("call +49 30 12345678") == "call \(m.pseudonym("phone", "493012345678"))")
    #expect(m.mask("or (415) 555-0132") == "or \(m.pseudonym("phone", "4155550132"))")
    #expect(email.hasPrefix("<email:h_") && email.count == "<email:h_>".count + 16)
  }

  @Test("MASK: the output is cut to 8000 characters after masking")
  func maskCap() {
    let m = InterimTextMasker(key: m310Key)
    #expect(m.mask(String(repeating: "x ", count: 5000)).count == 8000)
    let long = String(repeating: "a ", count: 3995) + "amara@example.com"
    let out = m.mask(long)
    #expect(out.count == 8000)
    #expect(!out.contains("@"))
  }

  @Test("MASK: menu bar app names stay unchanged, so m3-05 keeps them")
  func maskKeepsAppNames() {
    let m = InterimTextMasker(key: m310Key)
    for name in ["Xcode", "Google Chrome", "Safari", "Microsoft Excel", "1Password 7", "zoom.us", "Slack", "Mail"] {
      #expect(m.mask(name) == name, "\(name)")
    }
  }

  @Test("MASK: the local pseudonym key is 32 bytes, file 0600 in a 0700 folder, created once and reused")
  func pseudonymKeyFile() throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let paths = OnDevicePaths(offloadSupport: root)
    let first = try LocalPseudonymKey.loadOrCreate(at: paths.pseudonymKey)
    let again = try LocalPseudonymKey.loadOrCreate(at: paths.pseudonymKey)
    #expect(first.count == 32)
    #expect(first == again)
    #expect(M310Files.mode(paths.pseudonymKey) == 0o600)
    #expect(M310Files.mode(paths.root) == 0o700)
  }

  // MARK: SINK

  static func sinkObservations(_ importID: String) -> [ImportObservation] {
    [
      .idle(.idleEnd, id: "01JTEST0000000000000000001", ts: M310Clock.date(2026, 11, 18, 9), importID: importID),
      .focus(id: "01JTEST0000000000000000002", ts: M310Clock.date(2026, 11, 18, 9), importID: importID,
             appBundleID: "com.apple.Safari", appName: "Safari", title: "Pull request <num>", host: "github.com"),
      .text(id: "01JTEST0000000000000000003", ts: M310Clock.date(2026, 11, 18, 9, 0, 5), importID: importID,
            appBundleID: "com.apple.Safari", text: "masked words of the page"),
      .idle(.idleStart, id: "01JTEST0000000000000000004", ts: M310Clock.date(2026, 11, 18, 9, 12), importID: importID),
    ]
  }

  @Test("SINK: observations round-trip through the file as StoredObservation with snake case keys")
  func sinkRoundTrip() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let sink = LocalImportSink(folder: OnDevicePaths(offloadSupport: root).imports)
    let space = try await sink.openImport(sourceKind: .screenwatch)
    let obs = Self.sinkObservations(space.id)
    try sink.write(obs, to: space)
    let store = LocalObservationStore(folder: sink.folder)
    #expect(store.stored(importID: space.id) == obs.map { StoredObservation($0) })
    let raw = try String(contentsOf: sink.file(for: space.id), encoding: .utf8)
    let first = try #require(raw.split(separator: "\n").dropFirst().first)
    let dict = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
    #expect(Set(dict.keys) == ["id", "ts", "kind", "import_id", "app_bundle_id", "app_name", "title", "host"])
    #expect(dict["ts"] as? String == "2026-11-18T09:00:00.000Z")
    #expect(store.events(in: DateInterval(start: M310Clock.date(2026, 11, 18), end: M310Clock.date(2026, 11, 19))).count == 4)
  }

  @Test("SINK: the masked text is not written, only its text_hash")
  func sinkKeepsNoText() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let sink = LocalImportSink(folder: root.appendingPathComponent("imports"))
    let space = try await sink.openImport(sourceKind: .videos)
    try sink.write(Self.sinkObservations(space.id), to: space)
    let raw = try String(contentsOf: sink.file(for: space.id), encoding: .utf8)
    #expect(!raw.contains("masked words"))
    #expect(raw.contains(ImportWire.sha256Hex("masked words of the page")))
    #expect(!raw.contains("\"text\""))
  }

  @Test("SINK: no value holds a path or a file name")
  func sinkHoldsNoPaths() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let sink = LocalImportSink(folder: root.appendingPathComponent("imports"))
    let space = try await sink.openImport(sourceKind: .videos)
    try sink.write(Self.sinkObservations(space.id), to: space)
    let raw = try String(contentsOf: sink.file(for: space.id), encoding: .utf8)
    for line in raw.split(separator: "\n") {
      let dict = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      for (key, value) in dict {
        guard let s = value as? String else { continue }
        #expect(!s.contains("/"), "\(key) holds a path")
        #expect(!s.lowercased().hasSuffix(".mov") && !s.lowercased().hasSuffix(".png"), "\(key) holds a file name")
      }
    }
    #expect(!raw.contains(root.path))
  }

  @Test("SINK: files are 0600 and the folder 0700")
  func sinkModes() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let sink = LocalImportSink(folder: root.appendingPathComponent("imports"))
    let space = try await sink.openImport(sourceKind: .screenshots)
    try sink.write(Self.sinkObservations(space.id), to: space)
    #expect(M310Files.mode(sink.file(for: space.id)) == 0o600)
    #expect(M310Files.mode(sink.folder) == 0o700)
    #expect(space.id == space.id.lowercased() && UUID(uuidString: space.id) != nil)
  }

  @Test("SINK: a write to a space the sink did not open throws")
  func sinkUnknownSpace() {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let sink = LocalImportSink(folder: root.appendingPathComponent("imports"))
    let stranger = ImportSpace(id: "8f0e8c55-5f2a-4b8e-9e0c-0d6a1c3b2a10", sourceKind: .videos)
    #expect(throws: LocalImportSink.UnknownSpace(id: stranger.id)) {
      try sink.write(Self.sinkObservations(stranger.id), to: stranger)
    }
  }

  @Test("SINK: forget deletes only that import's file")
  func sinkForget() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let sink = LocalImportSink(folder: root.appendingPathComponent("imports"))
    let one = try await sink.openImport(sourceKind: .videos)
    let two = try await sink.openImport(sourceKind: .videos)
    try sink.write(Self.sinkObservations(one.id), to: one)
    try sink.write(Self.sinkObservations(two.id), to: two)
    try await sink.forget(one)
    #expect(!FileManager.default.fileExists(atPath: sink.file(for: one.id).path))
    #expect(FileManager.default.fileExists(atPath: sink.file(for: two.id).path))
    #expect(LocalObservationStore(folder: sink.folder).importIDs() == [two.id])
  }

  @Test("SINK: two imports stay in two files")
  func sinkTwoImports() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let sink = LocalImportSink(folder: root.appendingPathComponent("imports"))
    let one = try await sink.openImport(sourceKind: .videos)
    let two = try await sink.openImport(sourceKind: .screenwatch)
    try sink.write(Self.sinkObservations(one.id), to: one)
    try sink.write(Array(Self.sinkObservations(two.id).prefix(2)), to: two)
    let store = LocalObservationStore(folder: sink.folder)
    #expect(store.stored(importID: one.id).count == 4)
    #expect(store.stored(importID: two.id).count == 2)
    #expect(store.stored(importID: one.id).allSatisfy { $0.importID == one.id })
    #expect(Set(store.importIDs()) == [one.id, two.id])
  }

  @Test("SINK: a corrupt line is skipped on read")
  func sinkSkipsCorruptLines() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let sink = LocalImportSink(folder: root.appendingPathComponent("imports"))
    let space = try await sink.openImport(sourceKind: .videos)
    try sink.write(Array(Self.sinkObservations(space.id).prefix(2)), to: space)
    let handle = try FileHandle(forWritingTo: sink.file(for: space.id))
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data("not json at all\n{\"id\":1}\n".utf8))
    try handle.close()
    try sink.write(Array(Self.sinkObservations(space.id).suffix(2)), to: space)
    #expect(LocalObservationStore(folder: sink.folder).stored(importID: space.id).count == 4)
  }

  // MARK: FOLDERS

  @Test("FOLDERS: candidates in order: ~/screenwatch (screenwatch with days/), the screencapture location, Desktop, Movies")
  func folderOrder() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let present: Set<String> = ["/Users/tester/screenwatch", "/Users/tester/screenwatch/days", "/Users/tester/Documents/Captures",
                                "/Users/tester/Desktop", "/Users/tester/Movies"]
    let c = DefaultRecordingFolders.candidates(home: home, screencaptureLocation: "~/Documents/Captures",
                                               exists: { present.contains($0) })
    #expect(c.map(\.url.path) == ["/Users/tester/screenwatch", "/Users/tester/Documents/Captures", "/Users/tester/Desktop",
                                  "/Users/tester/Movies"])
    #expect(c.map(\.kind) == [.screenwatch, .screenRecordings, .desktop, .movies])
    let noDays = DefaultRecordingFolders.candidates(home: home, screencaptureLocation: nil,
                                                    exists: { $0 == "/Users/tester/screenwatch" })
    #expect(noDays.map(\.kind) == [.folder])
  }

  @Test("FOLDERS: missing folders are left out and a folder is listed once")
  func folderMissingAndDuplicates() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let present: Set<String> = ["/Users/tester/Desktop"]
    let c = DefaultRecordingFolders.candidates(home: home, screencaptureLocation: "/Users/tester/Desktop",
                                               exists: { present.contains($0) })
    #expect(c == [RecordingFolderCandidate(url: URL(fileURLWithPath: "/Users/tester/Desktop", isDirectory: true), kind: .screenRecordings)])
    #expect(DefaultRecordingFolders.preferred(home: home, screencaptureLocation: nil, exists: { _ in false }) == nil)
  }

  @Test("FOLDERS: Offload's own data folder is never a candidate")
  func folderNeverOffloadData() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let support = URL(fileURLWithPath: "/Users/tester/Library/Application Support/Offload", isDirectory: true)
    let c = DefaultRecordingFolders.candidates(home: home, screencaptureLocation: "~/Library/Application Support/Offload/OnDevice",
                                               protected: [support], exists: { _ in true })
    #expect(!c.contains { $0.url.path.hasPrefix(support.path) })
    #expect(c.map(\.kind) == [.screenwatch, .desktop, .movies])
  }

  @Test("FOLDERS: the preferred folder is used only when no folder was chosen")
  @MainActor func preferredOnlyWithoutChoice() throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("screenwatch/days"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
    let folders = OnDeviceRecordings.Folders(home: home, screencaptureLocation: nil,
                                             paths: OnDevicePaths(offloadSupport: root.appendingPathComponent("Offload")))
    let ui = M305UI()
    let fresh = try OnDeviceRecordings.make(neverWatch: NeverWatchStore(), store: ui.store, folders: folders, panel: ui.panel,
                                            picker: ui.picker, pseudonymKey: m310Key, timeZone: M310Clock.utc,
                                            durations: { _ in 60 }, appNames: nil)
    #expect(fresh.model.folder?.standardizedFileURL == home.appendingPathComponent("screenwatch").standardizedFileURL)
    let chosen = home.appendingPathComponent("Desktop", isDirectory: true)
    ui.store.folder = chosen
    let again = try OnDeviceRecordings.make(neverWatch: NeverWatchStore(), store: ui.store, folders: folders, panel: ui.panel,
                                            picker: ui.picker, pseudonymKey: m310Key, timeZone: M310Clock.utc,
                                            durations: { _ in 60 }, appNames: nil)
    #expect(again.model.folder == chosen)
  }

  @Test("FOLDERS: computing candidates only checks existence of the candidate paths (nothing is listed)")
  func foldersListNothing() throws {
    let root = M310Files.folder("home")
    defer { M310Files.remove(root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appendingPathComponent("Desktop/Screen Recording 2026-11-18 at 9.41.07.mov"))
    var asked: [String] = []
    let c = DefaultRecordingFolders.candidates(home: root, screencaptureLocation: nil, exists: { path in
      asked.append(path)
      return FileManager.default.fileExists(atPath: path)
    })
    #expect(c.map(\.kind) == [.desktop])
    let expected = ["screenwatch/days", "screenwatch", "Desktop", "Movies"].map { root.appendingPathComponent($0).standardizedFileURL.path }
    #expect(Set(asked.map { URL(fileURLWithPath: $0).standardizedFileURL.path }) == Set(expected))
  }

  // MARK: NONET

  @Test("NONET: Analysis/ and OnDevice/ sources contain no networking API")
  func noNetworkingInAnalysisOrOnDevice() {
    let banned = ["URLSession", "NWConnection", "CFStream", "import Network", "Network.", "socket(", "URLRequest"]
    let files = M304Repo.swiftSources("Sources/OffloadMac/Analysis") + M304Repo.swiftSources("Sources/OffloadMac/OnDevice")
    #expect(files.count >= 10)
    for f in files {
      for word in banned {
        #expect(!f.text.contains(word), "\(word) in \(f.path)")
      }
    }
  }
}
