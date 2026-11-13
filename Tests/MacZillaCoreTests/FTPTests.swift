import Foundation
import Testing
@testable import MacZillaCore

@Suite struct FTPParserTests {
    @Test func parsesMLSD() {
        let f = FTPParser.mlsd("type=file;size=12;modify=20240102030405;UNIX.mode=0644; my file.txt", parent: "/a")
        #expect(f?.name == "my file.txt")
        #expect(f?.path == "/a/my file.txt")
        #expect(f?.size == 12)
        #expect(f?.permissions == 0o644)
        #expect(f?.modified == Date(timeIntervalSince1970: 1704164645))
        #expect(FTPParser.mlsd("type=cdir; .", parent: "/") == nil)
        #expect(FTPParser.mlsd("type=dir; sub", parent: "/")?.isDirectory == true)
    }

    @Test func parsesUnixList() {
        let f = FTPParser.unixList("-rw-r--r--   1 user group     1234 Jan  1 12:00 some name.txt", parent: "/")
        #expect(f?.name == "some name.txt")
        #expect(f?.size == 1234)
        #expect(f?.permissions == 0o644)
        #expect(FTPParser.unixList("drwxr-xr-x 2 u g 4096 Jan 1 2020 d", parent: "/")?.isDirectory == true)
        #expect(FTPParser.unixList("total 12", parent: "/") == nil)
    }

    @Test func parsesPasv() {
        #expect(FTPParser.pasvPort("Entering Passive Mode (127,0,0,1,195,80).") == 195 * 256 + 80)
        #expect(FTPParser.epsvPort("Entering Extended Passive Mode (|||6446|)") == 6446)
    }
}

/// Test integracyjny – wymaga serwera FTP; uruchamiany gdy ustawiono MZ_FTP_PORT (patrz scripts/ftp-test.sh).
@Suite struct FTPIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MZ_FTP_PORT"] != nil))
    func roundTrip() async throws {
        let port = Int(ProcessInfo.processInfo.environment["MZ_FTP_PORT"]!)!
        let ftp = FTPProvider(config: FTPConfig(host: "127.0.0.1", port: port, username: "user", password: "pass"))
        try await ftp.connect()
        let local = LocalProvider()
        let tmp = NSTemporaryDirectory() + "mzftp-\(UUID().uuidString)"
        try await local.makeDirectory(tmp + "/in/sub")
        try Data((0..<300_000).map { UInt8($0 % 251) }).write(to: URL(fileURLWithPath: tmp + "/in/sub/big.bin"))
        try "x".write(toFile: tmp + "/in/a b.txt", atomically: true, encoding: .utf8)

        let dir = "/mz-\(UUID().uuidString.prefix(8))"
        try await ftp.makeDirectory(dir)
        try await Transfer.copy(from: local, tmp + "/in", to: ftp, dir)
        #expect(try await ftp.list(dir + "/in").map(\.name).sorted() == ["a b.txt", "sub"])
        #expect(try await ftp.stat(dir + "/in/sub/big.bin").size == 300_000)

        try await local.makeDirectory(tmp + "/out")
        try await Transfer.copy(from: ftp, dir + "/in", to: local, tmp + "/out")
        let a = try Data(contentsOf: URL(fileURLWithPath: tmp + "/in/sub/big.bin"))
        let b = try Data(contentsOf: URL(fileURLWithPath: tmp + "/out/in/sub/big.bin"))
        #expect(a == b)

        try await ftp.rename(dir + "/in/a b.txt", to: dir + "/in/c.txt")
        try await ftp.delete(dir)
        await #expect(throws: FileProviderError.self) { _ = try await ftp.stat(dir) }
        try await local.delete(tmp)
        await ftp.disconnect()
    }
}
