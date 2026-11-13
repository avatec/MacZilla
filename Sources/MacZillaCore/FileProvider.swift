import Foundation

public enum FileKind: String, Sendable, Codable {
    case file, directory, symlink, other
}

public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let kind: FileKind
    public let size: Int64?
    public let modified: Date?
    public let permissions: UInt16?
    public let isHidden: Bool

    public var isDirectory: Bool { kind == .directory }

    public init(name: String, path: String, kind: FileKind, size: Int64? = nil,
                modified: Date? = nil, permissions: UInt16? = nil, isHidden: Bool = false) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.isHidden = isHidden
    }
}

public struct ProviderCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let resume = ProviderCapabilities(rawValue: 1 << 0)
    public static let symlinks = ProviderCapabilities(rawValue: 1 << 1)
    public static let permissions = ProviderCapabilities(rawValue: 1 << 2)
    public static let serverSideCopy = ProviderCapabilities(rawValue: 1 << 3)
    public static let trash = ProviderCapabilities(rawValue: 1 << 4)
}

public struct WriteOptions: Sendable {
    public var overwrite: Bool
    public var offset: Int64
    public init(overwrite: Bool = false, offset: Int64 = 0) {
        self.overwrite = overwrite
        self.offset = offset
    }
}

public enum FileProviderError: Error, Equatable, LocalizedError {
    case notFound(String)
    case alreadyExists(String)
    case notConnected
    case unsupported(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let p): return "Nie znaleziono: \(p)"
        case .alreadyExists(let p): return "Już istnieje: \(p)"
        case .notConnected: return "Brak połączenia"
        case .unsupported(let s): return "Nieobsługiwane: \(s)"
        case .io(let s): return s
        }
    }
}

/// Wspólny kontrakt dla źródeł plików (lokalne, FTP, SFTP, wtyczki chmurowe).
public protocol FileProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    var homePath: String { get }

    func connect() async throws
    func disconnect() async
    func checkConnection() async throws

    func list(_ path: String) async throws -> [FileItem]
    func stat(_ path: String) async throws -> FileItem
    func read(_ path: String, offset: Int64) -> AsyncThrowingStream<Data, Error>
    func write(_ path: String, from data: AsyncThrowingStream<Data, Error>, options: WriteOptions) async throws
    func makeDirectory(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    func delete(_ path: String) async throws
    func setPermissions(_ path: String, mode: UInt16) async throws
}

public extension FileProvider {
    /// Domyślna sonda połączenia dla providerów bez własnego, lżejszego mechanizmu.
    func checkConnection() async throws { _ = try await stat(homePath) }

    func setPermissions(_ path: String, mode: UInt16) async throws {
        throw FileProviderError.unsupported("Zmiana uprawnień")
    }
}

public enum PathUtil {
    public static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : (base.hasSuffix("/") ? base + name : base + "/" + name)
    }

    public static func parent(_ path: String) -> String {
        if path == "/" || path.isEmpty { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let idx = trimmed.lastIndex(of: "/") else { return "/" }
        return idx == trimmed.startIndex ? "/" : String(trimmed[..<idx])
    }

    public static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }
}
