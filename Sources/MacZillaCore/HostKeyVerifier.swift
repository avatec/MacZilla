import Foundation

public struct HostKey: Sendable, Equatable {
    public let type: String
    public let blob: String
    /// Pełna linia known_hosts (`host typ blob`).
    public let line: String
    public let fingerprint: String
}

public enum HostKeyStatus: Sendable, Equatable {
    case trusted
    case unknown(HostKey)
    /// Serwer przedstawił inny klucz niż zapisany – możliwy atak MITM.
    case changed(HostKey)
}

/// Weryfikacja klucza hosta SSH przed połączeniem, w oparciu o narzędzia systemowe
/// (`ssh-keyscan`, `ssh-keygen`) i standardowy plik known_hosts.
public struct HostKeyVerifier: Sendable {
    public let knownHostsFile: String

    public init(knownHostsFile: String = NSHomeDirectory() + "/.ssh/known_hosts") {
        self.knownHostsFile = knownHostsFile
    }

    private static let preferred = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
                                    "ecdsa-sha2-nistp521", "rsa-sha2-512", "ssh-rsa"]

    public func check(host: String, port: Int) async throws -> HostKeyStatus {
        guard !host.hasPrefix("-"), !host.isEmpty else { throw FileProviderError.io("Nieprawidłowy host") }
        let scanned = try await scan(host: host, port: port)
        guard !scanned.isEmpty else {
            throw FileProviderError.io("Nie udało się pobrać klucza hosta \(host) (serwer niedostępny lub nie jest serwerem SSH)")
        }
        let known = await knownKeys(host: host, port: port)
        if scanned.contains(where: { s in known.contains { $0.type == s.type && $0.blob == s.blob } }) {
            return .trusted
        }
        let best = scanned.min { rank($0.type) < rank($1.type) }!
        return known.isEmpty ? .unknown(best) : .changed(best)
    }

    /// Zapisuje klucz w known_hosts (zastępując stare wpisy tego hosta, gdy klucz się zmienił).
    public func trust(_ key: HostKey, host: String, port: Int, replacing: Bool = false) async throws {
        let dir = (knownHostsFile as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if replacing {
            _ = try? await Self.run("/usr/bin/ssh-keygen", ["-R", Self.name(host, port), "-f", knownHostsFile])
        }
        var existing = (try? String(contentsOfFile: knownHostsFile, encoding: .utf8)) ?? ""
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        try (existing + key.line + "\n").write(toFile: knownHostsFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsFile)
    }

    static func name(_ host: String, _ port: Int) -> String { port == 22 ? host : "[\(host)]:\(port)" }

    private func rank(_ type: String) -> Int { Self.preferred.firstIndex(of: type) ?? Self.preferred.count }

    private func scan(host: String, port: Int) async throws -> [HostKey] {
        let res = try await Self.run("/usr/bin/ssh-keyscan", ["-T", "8", "-p", String(port), "--", host])
        let out = res.stdout
        var keys: [HostKey] = []
        for raw in out.split(separator: "\n") where !raw.hasPrefix("#") {
            let f = raw.split(separator: " ")
            guard f.count >= 3 else { continue }
            let line = f.prefix(3).joined(separator: " ")
            let fp = await fingerprint(of: line)
            keys.append(HostKey(type: String(f[1]), blob: String(f[2]), line: line, fingerprint: fp))
        }
        return keys
    }

    private func fingerprint(of line: String) async -> String {
        guard let r = try? await Self.run("/usr/bin/ssh-keygen", ["-lf", "-"], input: line + "\n") else { return "?" }
        let f = r.stdout.split(separator: " ")
        return f.count >= 2 ? String(f[1]) : "?"
    }

    private func knownKeys(host: String, port: Int) async -> [(type: String, blob: String)] {
        guard FileManager.default.fileExists(atPath: knownHostsFile),
              let r = try? await Self.run("/usr/bin/ssh-keygen", ["-F", Self.name(host, port), "-f", knownHostsFile])
        else { return [] }
        return r.stdout.split(separator: "\n").compactMap { l in
            guard !l.hasPrefix("#") else { return nil }
            let f = l.split(separator: " ")
            return f.count >= 3 ? (String(f[1]), String(f[2])) : nil
        }
    }

    struct Output { let stdout: String; let status: Int32 }

    static func run(_ exe: String, _ args: [String], input: String? = nil) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let out = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = inp
                do {
                    try p.run()
                    if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
                    try? inp.fileHandleForWriting.close()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: Output(stdout: String(decoding: data, as: UTF8.self), status: p.terminationStatus))
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}
