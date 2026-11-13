import Foundation
import Testing
@testable import MacZillaCore

/// Wymaga serwera FTPS (explicit TLS) – scripts/ftps-test.sh (MZ_FTPS_PORT).
@Suite struct FTPSIntegrationTests {
    private var port: Int { Int(ProcessInfo.processInfo.environment["MZ_FTPS_PORT"] ?? "0") ?? 0 }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MZ_FTPS_PORT"] != nil))
    func rejectsUntrustedCertificateByDefault() async {
        let ftp = FTPProvider(config: FTPConfig(host: "127.0.0.1", port: port, username: "user", password: "pass",
                                                security: .explicit))
        await #expect(throws: FileProviderError.self) { try await ftp.connect() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MZ_FTPS_PORT"] != nil))
    func roundTripOverTLS() async throws {
        let ftp = FTPProvider(config: FTPConfig(host: "127.0.0.1", port: port, username: "user", password: "pass",
                                                security: .explicit, allowInvalidCertificate: true))
        try await ftp.connect()
        let local = LocalProvider()
        let tmp = NSTemporaryDirectory() + "mzftps-\(UUID().uuidString)"
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
        #expect(try Data(contentsOf: URL(fileURLWithPath: tmp + "/in/sub/big.bin"))
                == Data(contentsOf: URL(fileURLWithPath: tmp + "/out/in/sub/big.bin")))

        try await ftp.delete(dir)
        try await local.delete(tmp)
        await ftp.disconnect()
    }
}
