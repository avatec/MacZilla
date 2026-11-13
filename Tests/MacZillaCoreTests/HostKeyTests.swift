import Foundation
import Testing
@testable import MacZillaCore

/// Wymaga serwera SSH – scripts/sftp-test.sh (MZ_SFTP_PORT, MZ_SFTP_KEY).
@Suite struct HostKeyTests {
    private static let enabled = ProcessInfo.processInfo.environment["MZ_SFTP_PORT"] != nil
    private var port: Int { Int(ProcessInfo.processInfo.environment["MZ_SFTP_PORT"] ?? "0") ?? 0 }

    @Test(.enabled(if: HostKeyTests.enabled))
    func unknownThenTrustedThenChanged() async throws {
        let file = NSTemporaryDirectory() + "mz-known-\(UUID().uuidString)/known_hosts"
        defer { try? FileManager.default.removeItem(atPath: (file as NSString).deletingLastPathComponent) }
        let v = HostKeyVerifier(knownHostsFile: file)

        guard case .unknown(let key) = try await v.check(host: "127.0.0.1", port: port) else {
            Issue.record("oczekiwano .unknown"); return
        }
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(key.line.hasPrefix("[127.0.0.1]:\(port) "))

        try await v.trust(key, host: "127.0.0.1", port: port)
        #expect(try await v.check(host: "127.0.0.1", port: port) == .trusted)

        // Podmieniony klucz w known_hosts = ostrzeżenie o zmianie.
        let bogus = "[127.0.0.1]:\(port) ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqetwNO1YpZuN8PcZ0Q2l9Gm9ymFOXeyVDjHcEEGb\n"
        try bogus.write(toFile: file, atomically: true, encoding: .utf8)
        guard case .changed(let newKey) = try await v.check(host: "127.0.0.1", port: port) else {
            Issue.record("oczekiwano .changed"); return
        }
        try await v.trust(newKey, host: "127.0.0.1", port: port, replacing: true)
        #expect(try await v.check(host: "127.0.0.1", port: port) == .trusted)
        let content = try String(contentsOfFile: file, encoding: .utf8)
        #expect(!content.contains("AAAAC3NzaC1lZDI1NTE5AAAAIOMqqetwNO1YpZuN8PcZ0Q2l9Gm9ymFOXeyVDjHcEEGb"))
    }

    @Test(.enabled(if: HostKeyTests.enabled))
    func strictModeRejectsUnknownHost() async throws {
        let env = ProcessInfo.processInfo.environment
        let file = NSTemporaryDirectory() + "mz-empty-\(UUID().uuidString)"
        try "".write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let sftp = SFTPProvider(config: SFTPConfig(
            host: "127.0.0.1", port: port, username: NSUserName(), identityFile: env["MZ_SFTP_KEY"],
            extraOptions: ["-o", "UserKnownHostsFile=\(file)"], strictHostKeys: true))
        await #expect(throws: (any Error).self) { try await sftp.connect() }
    }
}
