import Foundation
import Testing
@testable import MacZillaCore

@Suite struct WebDAVTests {
    @Test func parsesMultistatus() throws {
        let xml = """
        <?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/dav/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
        <D:response><D:href>/dav/a%20b.txt</D:href><D:propstat><D:prop><D:resourcetype/>
        <D:getcontentlength>42</D:getcontentlength><D:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</D:getlastmodified></D:prop></D:propstat></D:response>
        </D:multistatus>
        """
        let e = try DAVParser.parse(Data(xml.utf8))
        #expect(e.count == 2)
        #expect(e[0].isDirectory)
        #expect(e[1].href == "/dav/a%20b.txt" && e[1].size == 42)
        #expect(e[1].modified == Date(timeIntervalSince1970: 1704164645))
    }

    @Test func registryBuildsProviders() throws {
        let reg = ProviderRegistry.shared
        #expect(Set(reg.all.map(\.id.rawValue)).isSuperset(of: ["FTP", "SFTP", "WebDAV"]))
        #expect(SiteProtocol.sftp.defaultPort == 22)
        let dav = SiteProfile(proto: .webdav, host: "example.com", port: 443, username: "u")
        #expect(try reg.makeProvider(for: dav, password: "p").displayName == "example.com (WebDAV)")
        let custom = SiteProfile(proto: SiteProtocol("Nieznany"), host: "x")
        #expect(throws: FileProviderError.self) { try reg.makeProvider(for: custom, password: "") }
        #expect(try JSONDecoder().decode(SiteProfile.self, from: JSONEncoder().encode(dav)) == dav)
    }

    @Test func registerCustomPlugin() throws {
        let id = SiteProtocol("Test-\(UUID().uuidString)")
        ProviderRegistry.shared.register(ProviderPlugin(id: id, defaultPort: 1) { _, _ in LocalProvider() })
        #expect(try ProviderRegistry.shared.makeProvider(for: SiteProfile(proto: id, host: "x"), password: "").id == "local")
    }

    /// Wymaga serwera WebDAV – scripts/webdav-test.sh (MZ_DAV_PORT).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MZ_DAV_PORT"] != nil))
    func roundTrip() async throws {
        let port = ProcessInfo.processInfo.environment["MZ_DAV_PORT"]!
        let dav = WebDAVProvider(config: WebDAVConfig(baseURL: URL(string: "http://127.0.0.1:\(port)/")!))
        try await dav.connect()
        let local = LocalProvider()
        let tmp = NSTemporaryDirectory() + "mzdav-\(UUID().uuidString)"
        try await local.makeDirectory(tmp + "/in/sub")
        try Data((0..<400_000).map { UInt8($0 % 251) }).write(to: URL(fileURLWithPath: tmp + "/in/sub/big.bin"))
        try "x".write(toFile: tmp + "/in/a b.txt", atomically: true, encoding: .utf8)

        let remote = "/mz-\(UUID().uuidString.prefix(8))"
        try await dav.makeDirectory(remote)
        await #expect(throws: FileProviderError.alreadyExists(remote)) { try await dav.makeDirectory(remote) }
        try await Transfer.copy(from: local, tmp + "/in", to: dav, remote)
        #expect(try await dav.list(remote + "/in").map(\.name).sorted() == ["a b.txt", "sub"])
        #expect(try await dav.stat(remote + "/in/sub/big.bin").size == 400_000)
        #expect(try await dav.stat(remote + "/in/sub").isDirectory)

        try await local.makeDirectory(tmp + "/out")
        try await Transfer.copy(from: dav, remote + "/in", to: local, tmp + "/out")
        #expect(try Data(contentsOf: URL(fileURLWithPath: tmp + "/in/sub/big.bin"))
                == Data(contentsOf: URL(fileURLWithPath: tmp + "/out/in/sub/big.bin")))

        try await dav.rename(remote + "/in/a b.txt", to: remote + "/in/c d.txt")
        #expect(try await dav.list(remote + "/in").map(\.name).sorted() == ["c d.txt", "sub"])
        await #expect(throws: FileProviderError.notFound(remote + "/in/a b.txt")) { _ = try await dav.stat(remote + "/in/a b.txt") }
        try await dav.delete(remote)
        await #expect(throws: FileProviderError.self) { _ = try await dav.stat(remote) }
        try await local.delete(tmp)
    }
}
