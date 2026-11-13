import Foundation
import Testing
@testable import MacZillaCore

/// Wymaga serwera SSH – uruchamiany przez scripts/sftp-test.sh (MZ_SFTP_PORT, MZ_SFTP_KEY).
@Suite struct SFTPIntegrationTests {
    @Test func authModeValidation() async {
        let noPw = SFTPProvider(config: SFTPConfig(host: "127.0.0.1", username: "u", authMode: .password))
        await #expect(throws: FileProviderError.self) { try await noPw.connect() }
        let noKey = SFTPProvider(config: SFTPConfig(host: "127.0.0.1", username: "u", authMode: .key))
        await #expect(throws: FileProviderError.self) { try await noKey.connect() }
        #expect(SiteProfile(proto: .sftp).authMode == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MZ_SFTP_PORT"] != nil))
    func keyAndPasswordModes() async throws {
        let env = ProcessInfo.processInfo.environment
        let opts = ["-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no"]
        let port = Int(env["MZ_SFTP_PORT"]!)!
        let key = SFTPProvider(config: SFTPConfig(host: "127.0.0.1", port: port, username: NSUserName(),
                                                  identityFile: env["MZ_SFTP_KEY"], extraOptions: opts, authMode: .key))
        try await key.connect()
        #expect(key.homePath.hasPrefix("/"))
        // Tryb „hasło” z błędnym hasłem nie może się zalogować kluczem w tle.
        let pw = SFTPProvider(config: SFTPConfig(host: "127.0.0.1", port: port, username: NSUserName(),
                                                 password: "zle-haslo", extraOptions: opts, authMode: .password))
        await #expect(throws: (any Error).self) { try await pw.connect() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MZ_SFTP_PORT"] != nil))
    func roundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        let sftp = SFTPProvider(config: SFTPConfig(
            host: "127.0.0.1", port: Int(env["MZ_SFTP_PORT"]!)!, username: NSUserName(),
            identityFile: env["MZ_SFTP_KEY"],
            extraOptions: ["-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no"]))
        try await sftp.connect()
        #expect(sftp.homePath.hasPrefix("/"))

        let local = LocalProvider()
        let tmp = NSTemporaryDirectory() + "mzsftp-\(UUID().uuidString)"
        try await local.makeDirectory(tmp + "/in/sub")
        try Data((0..<500_000).map { UInt8($0 % 251) }).write(to: URL(fileURLWithPath: tmp + "/in/sub/big.bin"))
        try "x".write(toFile: tmp + "/in/a b.txt", atomically: true, encoding: .utf8)

        let remote = tmp + "-remote"
        try await sftp.makeDirectory(remote)
        await #expect(throws: FileProviderError.self) { try await sftp.makeDirectory(remote) }
        try await Transfer.copy(from: local, tmp + "/in", to: sftp, remote)
        #expect(try await sftp.list(remote + "/in").map(\.name).sorted() == ["a b.txt", "sub"])
        #expect(try await sftp.stat(remote + "/in/sub/big.bin").size == 500_000)
        #expect(try await sftp.stat(remote + "/in/sub").isDirectory)

        try await local.makeDirectory(tmp + "/out")
        try await Transfer.copy(from: sftp, remote + "/in", to: local, tmp + "/out")
        let a = try Data(contentsOf: URL(fileURLWithPath: tmp + "/in/sub/big.bin"))
        let b = try Data(contentsOf: URL(fileURLWithPath: tmp + "/out/in/sub/big.bin"))
        #expect(a == b)

        try await sftp.rename(remote + "/in/a b.txt", to: remote + "/in/c.txt")
        await #expect(throws: FileProviderError.notFound(remote + "/in/a b.txt")) {
            _ = try await sftp.stat(remote + "/in/a b.txt")
        }
        try await sftp.delete(remote)
        await #expect(throws: FileProviderError.self) { _ = try await sftp.stat(remote) }
        try await local.delete(tmp)
        await sftp.disconnect()
    }
}
