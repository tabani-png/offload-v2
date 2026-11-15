import Foundation
import Testing

@testable import OffloadContracts
@testable import OffloadStore
@testable import OffloadUploader

extension M302 {
    @Test("EGRESS: a request to any host other than the configured API host is refused")
    func otherHostsAreRefused() async throws {
        let server = FakeServer()
        let guardrail = EgressGuard(apiBase: URL(string: "https://api.offload.example")!)
        let transport = GuardedTransport(inner: server, guard: guardrail)
        let refused = [
            "https://evil.example/v1/ingest/batches",
            "https://api.offload.example.evil.example/v1/ingest/batches",
            "https://api.offload.example@evil.example/v1/ingest/batches",
            "https://api.offload.example:8443/v1/ingest/batches",
            "http://api.offload.example/v1/ingest/batches",
            "ftp://api.offload.example/x",
        ]
        for text in refused {
            let url = try #require(URL(string: text))
            await #expect(throws: EgressError.self) {
                _ = try await transport.send(HTTPRequest(url: url, method: "POST", headers: [:], body: Data()))
            }
        }
        #expect(server.requests.isEmpty)
        let ok = try #require(URL(string: "https://api.offload.example/v1/ingest/batches"))
        let r = try await transport.send(HTTPRequest(url: ok, method: "POST", headers: [:], body: Data("{}".utf8)))
        #expect(r.status == 200 || r.status == 404 || r.status == 409 || r.status < 600)
        #expect(server.requests.count == 1)
        // The dev stack on loopback is a configurable destination too, and only that one.
        let dev = EgressGuard(apiBase: URL(string: "http://127.0.0.1:8787")!)
        #expect(throws: Never.self) { try dev.check(url: URL(string: "http://127.0.0.1:8787/v1/ingest/config")!) }
        #expect(throws: EgressError.self) { try dev.check(url: URL(string: "http://127.0.0.1:9999/v1/ingest/config")!) }
    }

    @Test("EGRESS: a detector hit at send time stops the batch and nothing leaves")
    func detectorHitFailsClosed() async throws {
        let rig = UploadRig()
        try rig.addFocus(title: "Clean row")
        // A client bug: an unmasked address reached the day file.
        try rig.addFocus(title: "Reply to bob@client.example today")
        try rig.addFocus(title: "Another clean row")
        let uploader = rig.makeUploader()
        let report = await uploader.flush()
        #expect(report.sentBatches == 0 && report.sentObjects == 0)
        #expect(report.blocked == 1)
        #expect(report.failed)
        #expect(rig.server.requests.isEmpty, "nothing leaves while a detector fires")
        #expect(await uploader.counters.blocked == 1)
        // Each detector of the device rules runs again; a pseudonym passes, a name-free value passes.
        #expect(LeakScan.scan("Reply to <person:h_0123456789abcdef> about <doc:h_0123456789abcdef>") == nil)
        #expect(LeakScan.scan("call 416-555-0199") == "phone")
        #expect(LeakScan.scan("card 4111 1111 1111 1111") == "card")
        #expect(LeakScan.scan("see https://x.example/a/b?c=1") == "url")
        #expect(LeakScan.scan("key sk-ant-api03-AbCdEfGhIjKlMnOpQrStUv") == "key")
        #expect(LeakScan.scan("DE89 3704 0044 0532 0130 00") == "iban")
        // The offending object is set aside and counted; the next flush sends the clean ones.
        rig.time.advance(by: 301)
        let again = await uploader.flush()
        #expect(again.sentObjects == 2 && again.blocked == 0)
        let text = String(decoding: rig.server.batchRequests.first?.body ?? Data(), as: UTF8.self)
        #expect(!text.contains("bob@client.example"))
        #expect(await uploader.counters.blocked == 1)
    }

    @Test("EGRESS: every sent batch appears in the local egress ledger with the exact bytes")
    func ledgerHoldsExactBytes() async throws {
        let rig = UploadRig()
        try rig.addFocus(title: "ledger one")
        try rig.addFocus(title: "ledger two")
        _ = await rig.makeUploader().flush()
        rig.time.advance(by: 301)
        try rig.addFocus(title: "ledger three")
        _ = await rig.makeUploader().flush()

        let sent = rig.server.batchRequests
        #expect(sent.count == 2)
        let day = rig.home.days.day(of: rig.time.now)
        let records = try rig.ledger.read(day: day)
        #expect(records.count == 2)
        for (record, request) in zip(records, sent) {
            #expect(record.body == request.body)
            #expect(record.bytes == request.body?.count)
            #expect(record.destination == "api.offload.example")
            #expect(record.kind == "observation_batch")
            #expect(record.detectors["email"] == 0 && record.detectors["card"] == 0)
        }
        #expect(records.map { $0.objectCount } == [2, 1])
        // Sealed on disk, one file per day, kept 7 days.
        let file = try Data(contentsOf: rig.home.layout.egressFile(day))
        #expect(file.range(of: Data("ledger one".utf8)) == nil)
        let retention = Retention(layout: rig.home.layout, days: rig.home.days)
        #expect(try retention.purge(now: rig.time.now.addingTimeInterval(7 * 86_400)).isEmpty)
        #expect(try rig.ledger.read(day: day).count == 2)
        let purged = try retention.purge(now: rig.time.now.addingTimeInterval(8 * 86_400))
        #expect(purged.contains { $0.domain == "egress" && $0.day == day })
        #expect(retention.storedDays(domain: .egress).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.home.layout.egressFile(day).path))
    }

    @Test("STORE: the pseudonym key wraps under the recovery code and unwraps only with it")
    func recoveryWrapRoundTrips() throws {
        // RFC 7914 section 12, first vector: scrypt("", "", N=16, r=1, p=1, dkLen=64).
        let dk = try Scrypt.derive(password: Data(), salt: Data(), n: 16, r: 1, p: 1, length: 64)
        #expect(dk.map { String(format: "%02x", $0) }.joined() ==
            "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")
        let key = PseudonymKey(data: Data((0..<32).map { UInt8($0) }))
        let code = RecoveryCode.generate()
        #expect(code.count >= 24 && code.contains("-"))
        let cost = Scrypt.Cost(n: 1 << 10, r: 8, p: 1)
        let wrapped = try KeyWrap.wrap(key, recoveryCode: code, cost: cost)
        #expect(wrapped.range(of: Data(key.data)) == nil)
        let back = try KeyWrap.unwrap(wrapped, recoveryCode: code)
        #expect(back.data == key.data)
        #expect(throws: (any Error).self) { try KeyWrap.unwrap(wrapped, recoveryCode: RecoveryCode.generate()) }
        // The upload body for PUT /v1/devices/{id}/pseudonym-key-wrap, from the first device.
        let body = try KeyWrap.putBody(for: wrapped)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["method"] as? String == "recovery_code")
        #expect(json?["wrapped_by_device_id"] is NSNull || json?["wrapped_by_device_id"] == nil)
        #expect(json?["wrapped_key"] as? String == json?["recovery_wrap"] as? String)
        #expect(Set(json?.keys.map { $0 } ?? []).isSubset(of: ["wrapped_key", "wrapped_by_device_id", "method", "recovery_wrap"]))
        // The key itself lives in the Keychain item, this device only.
        let secrets = MemorySecretStore()
        let keeper = PseudonymKeyStore(secrets: secrets)
        let made = try keeper.loadOrCreate()
        #expect(try keeper.loadOrCreate().data == made.data)
        #expect(made.data.count == 32)
    }
}
