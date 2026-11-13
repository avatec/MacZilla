import Foundation
import Security

/// Identyfikator protokołu/wtyczki (np. "FTP", "SFTP", "WebDAV"); zapisywany w JSON jako zwykły string.
public struct SiteProtocol: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { self.rawValue = raw }

    public static let ftp = SiteProtocol("FTP")
    public static let ftps = SiteProtocol("FTPS")
    public static let sftp = SiteProtocol("SFTP")
    public static let webdav = SiteProtocol("WebDAV")

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var defaultPort: Int { ProviderRegistry.shared.plugin(for: self)?.defaultPort ?? 0 }
}

public struct SiteProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var proto: SiteProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var startPath: String
    public var identityFile: String?
    public var trustInvalidCertificate: Bool?
    /// Grupa w Menedżerze serwerów; zagnieżdżenia rozdzielane „/”, np. „Praca/Klienci”.
    public var folder: String?
    public var notes: String?
    /// Tryb logowania SSH/SFTP (`SFTPAuthMode.rawValue`); nil = automatycznie.
    public var authMode: String?

    public init(id: UUID = UUID(), name: String = "", proto: SiteProtocol = .ftp, host: String = "",
                port: Int? = nil, username: String = "", startPath: String = "", identityFile: String? = nil,
                trustInvalidCertificate: Bool? = nil, folder: String? = nil, notes: String? = nil,
                authMode: String? = nil) {
        self.id = id
        self.name = name
        self.proto = proto
        self.host = host
        self.port = port ?? proto.defaultPort
        self.username = username
        self.startPath = startPath
        self.identityFile = identityFile
        self.trustInvalidCertificate = trustInvalidCertificate
        self.folder = folder
        self.notes = notes
        self.authMode = authMode
    }

    public var title: String { name.isEmpty ? host : name }

    /// Skrócony opis do listy: `user@host`.
    public var subtitle: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }

    public var folderComponents: [String] {
        (folder ?? "").split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Zapis profili serwerów w JSON (bez haseł).
public final class SiteStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacZilla/sites.json")
    }

    public init(url: URL = SiteStore.defaultURL) { self.url = url }

    public func load() -> [SiteProfile] {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([SiteProfile].self, from: data)) ?? []
        }
    }

    public func save(_ sites: [SiteProfile]) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(sites).write(to: url, options: .atomic)
        }
    }
}

/// Hasła w Keychain: wszystkie w jednym wpisie (JSON), więc system pyta o dostęp najwyżej raz,
/// a odczyty są potem cache'owane w pamięci. Stare wpisy „jedno na profil” są migrowane leniwie – dopiero gdy dany serwer jest użyty.
public final class KeychainStore: @unchecked Sendable {
    public let service: String
    private let vaultAccount = "vault"
    private let lock = NSLock()
    private var cache: [String: String]?

    public init(service: String = "pl.avatec.maczilla.site") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func readItem(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private func vault() -> [String: String] {
        if let cache { return cache }
        var v: [String: String] = [:]
        if let d = readItem(vaultAccount), let dec = try? JSONDecoder().decode([String: String].self, from: d) { v = dec }
        cache = v
        return v
    }

    private func writeVault(_ v: [String: String]) throws {
        let data = try JSONEncoder().encode(v)
        SecItemDelete(query(vaultAccount) as CFDictionary)
        var q = query(vaultAccount)
        q[kSecValueData as String] = data
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw FileProviderError.io("Keychain: błąd \(status)") }
        cache = v
    }

    public func setPassword(_ password: String, for id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var v = vault()
        v[id.uuidString] = password
        try writeVault(v)
        SecItemDelete(query(id.uuidString) as CFDictionary)
    }

    public func password(for id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        let v = vault()
        if let p = v[id.uuidString] { return p }
        guard let d = readItem(id.uuidString) else { return nil }
        let p = String(decoding: d, as: UTF8.self)
        var nv = v
        nv[id.uuidString] = p
        if (try? writeVault(nv)) != nil { SecItemDelete(query(id.uuidString) as CFDictionary) } else { cache = nv }
        return p
    }

    public func deletePassword(for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        var v = vault()
        if v.removeValue(forKey: id.uuidString) != nil { try? writeVault(v) }
        SecItemDelete(query(id.uuidString) as CFDictionary)
    }
}
