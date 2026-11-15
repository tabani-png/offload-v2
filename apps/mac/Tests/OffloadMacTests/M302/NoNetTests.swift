import Foundation
import Testing

extension M302 {
    /// The old banned list, verbatim (docs/MIGRATION.md section 2.4).
    static let bannedNetworkAPI = try! NSRegularExpression(
        pattern: #"URLSession|import Network|NSURLConnection|CFNetwork|NWConnection|CFStream|socket\(|URLRequest"#)

    static func swiftFiles(under dir: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let item = walker?.nextObject() as? URL { if item.pathExtension == "swift" { out.append(item) } }
        return out
    }

    static func hits(in dir: URL) throws -> [String] {
        var found: [String] = []
        for file in swiftFiles(under: dir) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            if bannedNetworkAPI.firstMatch(in: text, range: range) != nil { found.append(file.lastPathComponent) }
        }
        return found
    }

    @Test("NONET: observer sources contain no networking API")
    func observerHasNoNetworking() throws {
        let dir = Repo.macSources.appendingPathComponent("OffloadObserver")
        #expect(!Self.swiftFiles(under: dir).isEmpty)
        let found = try Self.hits(in: dir)
        #expect(found.isEmpty, "networking API in \(found)")
    }

    @Test("NONET: masker and store sources contain no networking API")
    func maskerAndStoreHaveNoNetworking() throws {
        for target in ["OffloadMasker", "OffloadStore"] {
            let dir = Repo.macSources.appendingPathComponent(target)
            #expect(!Self.swiftFiles(under: dir).isEmpty)
            let found = try Self.hits(in: dir)
            #expect(found.isEmpty, "networking API in \(found)")
        }
    }

    @Test("NONET: observer target does not link the uploader")
    func observerDoesNotLinkUploader() throws {
        let manifest = try String(contentsOf: Repo.root.appendingPathComponent("apps/mac/Package.swift"), encoding: .utf8)
        func dependencies(of target: String) -> String? {
            guard let start = manifest.range(of: "name: \"\(target)\"") else { return nil }
            let rest = manifest[start.upperBound...]
            guard let open = rest.range(of: "dependencies: ["), let close = rest[open.upperBound...].firstIndex(of: "]") else { return nil }
            return String(rest[open.upperBound..<close])
        }
        let observer = dependencies(of: "OffloadObserver")
        #expect(observer != nil)
        let deps = observer ?? ""
        #expect(!deps.contains("OffloadUploader"))
        #expect(deps.contains("OffloadStore") && deps.contains("OffloadMasker") && deps.contains("OffloadContracts"))
        #expect(!deps.contains("OffloadMac"))
    }
}
