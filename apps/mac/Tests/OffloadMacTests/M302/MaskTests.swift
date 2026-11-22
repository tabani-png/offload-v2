import Foundation
import Testing

@testable import OffloadContracts
@testable import OffloadMasker
@testable import OffloadObserver
@testable import OffloadStore

/// A scripted accessibility tree for the bounded walk.
final class FakeNode: AXNodeReading {
    let text: String?
    let isSecure: Bool
    var kids: [FakeNode] = []
    init(text: String? = nil, isSecure: Bool = false) {
        self.text = text
        self.isSecure = isSecure
    }
    var children: [any AXNodeReading] { kids }
}

extension M302 {
    @Test("MASK: card, IBAN, API key and URL query are masked before the day file is written")
    func structuredSecretsAreMaskedBeforeWrite() async throws {
        let rig = Rig()
        rig.ax.text = """
        Card 4111 1111 1111 1111 expires 12/29 cvv 123 please.
        Pay to IBAN DE89 3704 0044 0532 0130 00 today.
        Key sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx in the config.
        Open https://billing.example.com/invoices/8841?token=hunter2secret&user=42#frag now.
        """ + String(repeating: " filler words to pass the two hundred characters mark", count: 6)
        rig.workspace.snapshot = FocusSnapshot(
            bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Invoice 4111 1111 1111 1111",
            url: "https://billing.example.com/invoices/8841?token=hunter2secret")
        await rig.tick()
        // Read back through the encrypted store: this is exactly what a later upload would see.
        let items = try rig.observed()
        let text = snapshots(items).map { $0.text }.joined(separator: "\n")
        let title = focuses(items).compactMap { $0.title }.joined()
        let everything = text + "\n" + title
        for raw in ["4111", "DE89", "3704 0044", "sk-ant-api03", "AbCdEf", "hunter2secret", "token=", "#frag", "user=42", "8841"] {
            #expect(!everything.contains(raw), "\(raw) reached the day file")
        }
        #expect(text.contains("[CARD NO.]"))
        #expect(text.contains("[IBAN]"))
        #expect(text.contains("[SECRET]"))
        #expect(text.contains("billing.example.com"))
        // The day file on disk holds ciphertext only.
        let onDisk = try Data(contentsOf: rig.home.layout.dayFile(rig.home.days.day(of: rig.time.now)))
        #expect(onDisk.range(of: Data("billing.example.com".utf8)) == nil)
        #expect(onDisk.range(of: Data("4111".utf8)) == nil)
    }

    @Test("MASK: text over 8000 characters is truncated after masking")
    func longTextIsTruncated() async throws {
        let rig = Rig()
        rig.ax.text = String(repeating: "lorem ipsum dolor ", count: 700)  // 12,600 characters
        await rig.tick()
        let texts = snapshots(try rig.observed())
        #expect(texts.count == 1)
        let n = texts.first?.text.utf16.count ?? 0
        #expect(n > 7000 && n <= 8000)
        #expect(texts.first?.textHash == sha256Hex(texts.first?.text ?? ""))
    }

    @Test("MASK: unchanged text hash writes no new text_snapshot")
    func unchangedTextWritesNothing() async throws {
        let rig = Rig()
        rig.ax.text = String(repeating: "quarterly close checklist ", count: 20)
        await rig.tick()
        await rig.tick(31)
        await rig.tick(31)
        #expect(snapshots(try rig.observed()).count == 1)
        rig.ax.text += " one more line added by the user"
        await rig.tick(31)
        #expect(snapshots(try rig.observed()).count == 2)
    }

    @Test("MASK: Accessibility text is used and OCR runs only under 200 characters")
    func accessibilityFirstThenOCR() async throws {
        let rig = Rig()
        rig.ax.text = String(repeating: "enough accessibility text here. ", count: 12)  // 384 characters
        rig.ocr.text = "text from the screen image"
        await rig.tick()
        #expect(rig.ocr.calls == 0)
        #expect(snapshots(try rig.observed()).first?.textSource == .ax)

        rig.workspace.snapshot = FocusSnapshot(bundleID: "com.apple.Preview", appName: "Preview", windowTitle: "scan.pdf", url: nil)
        rig.ax.text = "short"
        await rig.tick(3)
        #expect(rig.ocr.calls == 1)
        let last = snapshots(try rig.observed()).last
        #expect(last?.textSource == .ocr)
        #expect(last?.text == "text from the screen image")
        // At most one OCR per window per 30 seconds.
        await rig.tick(3)
        #expect(rig.ocr.calls == 1)
    }

    @Test("MASK: the AX walk stops at 1,500 nodes, depth 12 or 150 ms")
    func accessibilityWalkIsBounded() {
        // 5,000 nodes under one root: stops at 1,500.
        let wide = FakeNode(text: "root")
        wide.kids = (0..<5000).map { FakeNode(text: "n\($0)") }
        var clock = 0.0
        let byNodes = AXWalker.walk(root: wide, limits: .standard, now: { clock })
        #expect(byNodes.visitedNodes == 1500)
        #expect(byNodes.stop == .nodes)

        // A chain 50 deep: stops at depth 12.
        let top = FakeNode(text: "d0")
        var tail = top
        for i in 1..<50 {
            let next = FakeNode(text: "d\(i)")
            tail.kids = [next]
            tail = next
        }
        let byDepth = AXWalker.walk(root: top, limits: .standard, now: { clock })
        #expect(byDepth.deepest == 12)
        #expect(byDepth.stop == .depth)
        #expect(!byDepth.text.contains("d13"))

        // Each node costs 10 ms on a scripted clock: 150 ms ends the walk long before 1,500 nodes.
        clock = 0
        let slow = FakeNode(text: "root")
        slow.kids = (0..<500).map { FakeNode(text: "s\($0)") }
        let byTime = AXWalker.walk(root: slow, limits: .standard, now: { clock += 0.010; return clock })
        #expect(byTime.stop == .time)
        #expect(byTime.visitedNodes <= 16)

        // Secure text fields are skipped, their children too.
        let form = FakeNode(text: "Sign in")
        let secret = FakeNode(text: "hunter2", isSecure: true)
        secret.kids = [FakeNode(text: "child of secret")]
        form.kids = [secret, FakeNode(text: "Continue")]
        let walked = AXWalker.walk(root: form, limits: .standard, now: { 0 })
        #expect(walked.text.contains("Continue"))
        #expect(!walked.text.contains("hunter2") && !walked.text.contains("child of secret"))
        #expect(walked.stop == .complete)
    }
}
