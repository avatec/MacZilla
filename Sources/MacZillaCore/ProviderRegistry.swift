import Foundation

/// Opis wtyczki-providera: jak wyświetlić ją w Site Managerze i jak zbudować `FileProvider` z profilu.
public struct ProviderPlugin: Sendable {
    public let id: SiteProtocol
    public let defaultPort: Int
    public let supportsKeyFile: Bool
    public let supportsCertificateTrust: Bool
    public let hostHint: String
    public let make: @Sendable (_ site: SiteProfile, _ password: String) throws -> any FileProvider

    public init(id: SiteProtocol, defaultPort: Int, supportsKeyFile: Bool = false,
                supportsCertificateTrust: Bool = false, hostHint: String = "",
                make: @escaping @Sendable (SiteProfile, String) throws -> any FileProvider) {
        self.id = id
        self.defaultPort = defaultPort
        self.supportsKeyFile = supportsKeyFile
        self.supportsCertificateTrust = supportsCertificateTrust
        self.hostHint = hostHint
        self.make = make
    }
}

/// Rejestr wtyczek. Wbudowane: FTP, SFTP, WebDAV; kolejne (np. chmury) rejestrują się przez `register`.
public final class ProviderRegistry: @unchecked Sendable {
    public static let shared = ProviderRegistry()

    private let lock = NSLock()
    private var plugins: [ProviderPlugin] = []

    init() {
        plugins = [
            ProviderPlugin(id: .ftp, defaultPort: 21) { s, pw in
                FTPProvider(config: FTPConfig(host: s.host, port: s.port, username: s.username, password: pw))
            },
            ProviderPlugin(id: .ftps, defaultPort: 21, supportsCertificateTrust: true,
                           hostHint: "port 990 = niejawny TLS") { s, pw in
                FTPProvider(config: FTPConfig(host: s.host, port: s.port, username: s.username, password: pw,
                                              security: s.port == 990 ? .implicit : .explicit,
                                              allowInvalidCertificate: s.trustInvalidCertificate ?? false))
            },
            ProviderPlugin(id: .sftp, defaultPort: 22, supportsKeyFile: true) { s, pw in
                SFTPProvider(config: SFTPConfig(host: s.host, port: s.port, username: s.username,
                                                password: pw, identityFile: s.identityFile, strictHostKeys: true,
                                                authMode: s.authMode.flatMap(SFTPAuthMode.init(rawValue:)) ?? .auto))
            },
            ProviderPlugin(id: .webdav, defaultPort: 443, hostHint: "host albo https://host/sciezka") { s, pw in
                try WebDAVProvider(config: try WebDAVConfig(site: s, password: pw))
            },
        ]
    }

    public var all: [ProviderPlugin] { lock.withLock { plugins } }

    public func plugin(for id: SiteProtocol) -> ProviderPlugin? {
        lock.withLock { plugins.first { $0.id == id } }
    }

    public func register(_ plugin: ProviderPlugin) {
        lock.withLock {
            plugins.removeAll { $0.id == plugin.id }
            plugins.append(plugin)
        }
    }

    public func makeProvider(for site: SiteProfile, password: String) throws -> any FileProvider {
        guard let p = plugin(for: site.proto) else {
            throw FileProviderError.unsupported("Brak wtyczki dla protokołu \(site.proto.rawValue)")
        }
        return try p.make(site, password)
    }
}
