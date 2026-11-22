import CryptoKit
import Foundation
import Testing

@testable import OffloadContracts
@testable import OffloadMasker
@testable import OffloadStore
@testable import OffloadUploader

extension M302 {
    static func run(_ launch: String, _ args: [String], cwd: URL) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [launch] + args
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("UPLOAD: generated Swift types are fresh")
    func generatedTypesAreFresh() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("offload-gen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let ran = try Self.run("bun", ["packages/contracts/scripts/gen-swift.ts", "--out", out.path], cwd: Repo.root)
        #expect(ran.status == 0, "gen-swift.ts failed: \(ran.out)")
        let committed = Repo.macSources.appendingPathComponent("OffloadContracts/Generated", isDirectory: true)
        let fresh = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        let have = try FileManager.default.contentsOfDirectory(atPath: committed.path).filter { $0.hasSuffix(".swift") }.sorted()
        #expect(!fresh.isEmpty)
        #expect(fresh == have, "generated file set differs")
        for name in fresh {
            let a = try Data(contentsOf: out.appendingPathComponent(name))
            let b = try Data(contentsOf: committed.appendingPathComponent(name))
            #expect(a == b, "\(name) is stale: run bun packages/contracts/scripts/gen-swift.ts")
        }
        // One generated type per schema the Mac sends or receives.
        let all = try fresh.map { try String(contentsOf: out.appendingPathComponent($0), encoding: .utf8) }.joined()
        for type in ["enum Observation", "enum IngestEnvelope", "struct IngestReceipt", "struct ErrorEnvelope", "struct ReviewEvent", "struct NoticeAck", "struct KeyframeMeta", "struct StepResult", "struct Figure"] {
            #expect(all.contains("public \(type)"), "missing \(type)")
        }
    }

    @Test("UPLOAD: generated types refuse unknown keys and out-of-range values")
    func generatedTypesAreClosed() throws {
        let good = #"{"id":"01JC0000000000000000000000","ts":"2026-11-14T16:01:12.000Z","kind":"focus","app_bundle_id":"a","app_name":"A"}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Observation.self, from: Data(good.replacingOccurrences(of: "\"kind\"", with: "\"extra\":1,\"kind\"").utf8)) }
        let ok = try JSONDecoder().decode(Observation.self, from: Data(good.utf8))
        #expect(ok.kind == "focus")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Observation.self, from: Data(good.replacingOccurrences(of: "01JC0000000000000000000000", with: "not-a-ulid").utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Observation.self, from: Data(good.replacingOccurrences(of: "\"kind\":\"focus\"", with: "\"kind\":\"keylog\"").utf8)) }
        let missing = #"{"id":"01JC0000000000000000000000","ts":"2026-11-14T16:01:12.000Z","kind":"focus","app_name":"A"}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Observation.self, from: Data(missing.utf8)) }
        let longTitle = good.replacingOccurrences(of: "\"app_name\":\"A\"", with: "\"app_name\":\"A\",\"title\":\"\(String(repeating: "x", count: 513))\"")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Observation.self, from: Data(longTitle.utf8)) }
    }

    @Test("UPLOAD: JCS matches the shared RFC 8785 vectors")
    func jcsMatchesVectors() throws {
        let dir = Repo.fixtures.appendingPathComponent("jcs", isDirectory: true)
        let names = ["arrays", "french", "structures", "unicode", "values", "weird"]
        for name in names {
            let input = try Data(contentsOf: dir.appendingPathComponent("\(name).input.json"))
            let expected = try Data(contentsOf: dir.appendingPathComponent("\(name).output.json"))
            let got = try JCS.canonicalize(json: input)
            #expect(got == expected, "\(name): \(String(decoding: got, as: UTF8.self))")
        }
        // ES6 number formatting at the edges.
        func jcs(_ s: String) throws -> String { String(decoding: try JCS.canonicalize(json: Data(s.utf8)), as: UTF8.self) }
        #expect(try jcs("[1e21,1e-7,0.000001,-0,100,1.5e300,123456789012345680000]") == "[1e+21,1e-7,0.000001,0,100,1.5e+300,123456789012345680000]")
        #expect(throws: (any Error).self) { try jcs("[1e999]") }
        #expect(try jcs(#"{"b":1,"a":{"d":true,"c":null}}"#) == #"{"a":{"c":null,"d":true},"b":1}"#)
    }

    @Test("UPLOAD: envelope bytes are JCS and the raw r‖s signature verifies with the public JWK")
    func envelopeIsSignedJCS() async throws {
        let rig = UploadRig()
        try rig.addFocus()
        try rig.addFocus(title: "Second")
        let report = await rig.makeUploader().flush()
        #expect(report.sentBatches == 1 && report.sentObjects == 2)
        let request = try #require(rig.server.batchRequests.first)
        let body = try #require(request.body)
        #expect(try JCS.canonicalize(json: body) == body)
        #expect(request.method == "POST")
        #expect(request.headers["Authorization"] == "Bearer tok")
        #expect(request.headers["Content-Type"] == "application/json")
        let header = try #require(request.headers["Offload-Signature"])
        #expect(header.hasPrefix("keyid=\(rig.config.deviceID), sig="))
        let sig = try #require(unb64url(String(header.dropFirst("keyid=\(rig.config.deviceID), sig=".count))))
        #expect(sig.count == 64)
        let jwk = rig.signer.publicJWK
        let x = try #require(unb64url(jwk.x)), y = try #require(unb64url(jwk.y))
        let key = try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
        #expect(key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig), for: body))
        #expect(!key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig), for: body + Data([32])))
        // The body decodes with the generated closed types and carries the device id and seq.
        let envelope = try JSONDecoder().decode(IngestEnvelope.self, from: body)
        guard case .observationBatch(let batch) = envelope else { Issue.record("not an observation batch"); return }
        #expect(batch.deviceId == rig.config.deviceID && batch.objects.count == 2 && batch.seq >= 1)
    }

    @Test("UPLOAD: offline queue flushes in seq order after reconnect")
    func offlineQueueFlushesInOrder() async throws {
        let rig = UploadRig()
        rig.server.online = false
        let first = rig.makeUploader()
        try rig.addFocus(title: "one")
        let a = await first.flush()
        #expect(a.sentBatches == 0 && a.failed)
        rig.time.advance(by: 301)
        try rig.addFocus(title: "two")
        _ = await first.flush()
        rig.time.advance(by: 301)
        try rig.addFocus(title: "three")
        _ = await first.flush()
        #expect(rig.server.requests.isEmpty)

        rig.server.online = true
        rig.time.advance(by: 6 * 3600 + 1)  // past the longest backoff
        let b = await first.flush()
        #expect(b.sentBatches == 3 && b.sentObjects == 3)
        let seqs = try rig.server.batchRequests.map { r -> Int in
            let json = try JSONSerialization.jsonObject(with: try #require(r.body)) as? [String: Any]
            return json?["seq"] as? Int ?? -1
        }
        #expect(seqs.count == 3)
        #expect(seqs == seqs.sorted() && Set(seqs).count == 3)
        // Nothing left: a further flush sends nothing.
        let c = await first.flush()
        #expect(c.sentBatches == 0)
    }

    @Test("UPLOAD: kill after send before receipt, restart resends identical bytes and seq")
    func restartResendsIdenticalBytes() async throws {
        let rig = UploadRig()
        try rig.addFocus(title: "keep me")
        rig.server.dropNextResponse = true
        let before = rig.makeUploader()
        let a = await before.flush()
        #expect(a.sentBatches == 0)
        #expect(rig.server.batchRequests.count == 1)
        // "Kill": a new uploader over the same files, a little later.
        rig.time.advance(by: 301)
        let after = rig.makeUploader()
        let b = await after.flush()
        #expect(b.sentBatches == 1 && b.sentObjects == 1)
        let sent = rig.server.batchRequests
        #expect(sent.count == 2)
        #expect(sent[0].body == sent[1].body)
        #expect(sent[0].headers["Offload-Signature"] != nil)
        let body = try #require(sent[1].body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let first = try JSONSerialization.jsonObject(with: try #require(sent[0].body)) as? [String: Any]
        #expect(json?["seq"] as? Int == first?["seq"] as? Int)
        // The pending bytes were on disk before the first send, sealed.
        let state = try Data(contentsOf: rig.home.layout.uploadStateFile)
        #expect(state.range(of: Data("keep me".utf8)) == nil)
    }

    @Test("UPLOAD: a 409 seq_replay with identical bytes re-reads the receipt and does not lose objects")
    func seqReplayReReadsReceipt() async throws {
        let rig = UploadRig()
        for i in 0..<3 { try rig.addFocus(title: "row \(i)") }
        rig.server.replayConflicts = 1
        let report = await rig.makeUploader().flush()
        #expect(report.sentBatches == 1 && report.sentObjects == 3 && !report.failed)
        let sent = rig.server.batchRequests
        #expect(sent.count == 2)
        #expect(sent[0].body == sent[1].body)
        let day = rig.home.days.day(of: rig.time.now)
        let ledger = try rig.ledger.read(day: day)
        #expect(ledger.count == 1 && ledger.first?.objectCount == 3)

        // A conflict that persists means the bytes differ from what the server holds (a client bug):
        // the objects are re-batched under a new seq, counted, and still arrive.
        let rig2 = UploadRig()
        for i in 0..<2 { try rig2.addFocus(title: "other \(i)") }
        rig2.server.replayConflicts = 2
        let uploader = rig2.makeUploader()
        let r2 = await uploader.flush()
        #expect(r2.sentObjects == 2 && !r2.failed)
        let seqs = try rig2.server.batchRequests.map { r -> Int in
            (try JSONSerialization.jsonObject(with: try #require(r.body)) as? [String: Any])?["seq"] as? Int ?? -1
        }
        #expect(seqs.count == 3)
        if seqs.count == 3 {
            #expect(seqs[0] == seqs[1])
            #expect(seqs[2] > seqs[1])
        }
        #expect(await uploader.counters.rebatched == 1)
    }

    @Test("UPLOAD: objects older than 7 days are dropped and counted")
    func oldObjectsAreDropped() async throws {
        let rig = UploadRig()
        try rig.addFocus(title: "ancient", secondsAgo: 8 * 86_400)
        try rig.addFocus(title: "older", secondsAgo: 9 * 86_400)
        try rig.addFocus(title: "fresh")
        let uploader = rig.makeUploader()
        let report = await uploader.flush()
        #expect(report.sentObjects == 1 && report.droppedOld == 2)
        #expect(await uploader.counters.droppedOld == 2)
        let body = try #require(rig.server.batchRequests.first?.body)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("fresh") && !text.contains("ancient") && !text.contains("older"))
        // The counter survives a restart.
        #expect(await rig.makeUploader().counters.droppedOld == 2)
    }

    @Test("UPLOAD: PKCE S256 challenge matches the RFC 7636 vector and the loopback redirect is checked")
    func pkceMatchesRFC() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(forVerifier: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let made = PKCE.generate()
        #expect(made.verifier.count >= 43 && made.verifier.count <= 128)
        #expect(PKCE.challenge(forVerifier: made.verifier) == made.challenge)
        let url = try #require(EnrollmentURLs.authorize(apiBase: URL(string: "https://api.offload.example")!, challenge: made.challenge, port: 49321, state: "st"))
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.path == "/v1/devices/authorize")
        let q = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["code_challenge_method"] == "S256" && q["code_challenge"] == made.challenge && q["state"] == "st")
        #expect(q["redirect_uri"] == "http://127.0.0.1:49321/callback")
        // The callback parser accepts only the right state and a code.
        #expect(EnrollmentURLs.parseCallback("/callback?code=abc&state=st", expectedState: "st") == "abc")
        #expect(EnrollmentURLs.parseCallback("/callback?code=abc&state=other", expectedState: "st") == nil)
        #expect(EnrollmentURLs.parseCallback("/elsewhere?code=abc&state=st", expectedState: "st") == nil)
    }

    @Test("UPLOAD: the loopback listener hands back the code only for the right state")
    func loopbackListenerChecksState() async throws {
        let listener = LoopbackListener(expectedState: "good-state")
        let port = try await listener.start()
        defer { listener.stop() }
        #expect(port >= 1024)
        func get(_ target: String) async throws -> Int {
            let (_, response) = try await URLSession.shared.data(from: try #require(URL(string: "http://127.0.0.1:\(port)\(target)")))
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        }
        // A request with the wrong state is answered 400 and never becomes the code.
        #expect(try await get("/callback?code=evil&state=other") == 400)
        #expect(try await get("/callback?code=real-code&state=good-state") == 200)
        #expect(try await listener.waitForCode(timeout: 5) == "real-code")
    }
}
