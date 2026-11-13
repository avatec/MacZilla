import Foundation

/// Sposób uwierzytelniania SSH/SFTP.
public enum SFTPAuthMode: String, Codable, CaseIterable, Sendable {
    /// Jak w Terminalu: ssh-agent i domyślne klucze, a jeśli podano hasło – także hasło.
    case auto
    /// Tylko hasło (bez kluczy).
    case password
    /// Tylko plik klucza (hasło = fraza klucza, jeśli podane).
    case key
    /// Tylko ssh-agent / domyślne klucze, bez pytania o hasło.
    case agent

    public var title: String {
        switch self {
        case .auto: return "Automatycznie"
        case .password: return "Hasło"
        case .key: return "Plik klucza"
        case .agent: return "ssh-agent"
        }
    }
}

public struct SFTPConfig: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var identityFile: String?
    public var extraOptions: [String]
    /// true: tylko znane hosty (po weryfikacji `HostKeyVerifier`); false: accept-new.
    public var strictHostKeys: Bool
    public var authMode: SFTPAuthMode

    public init(host: String, port: Int = 22, username: String, password: String = "",
                identityFile: String? = nil, extraOptions: [String] = [], strictHostKeys: Bool = false,
                authMode: SFTPAuthMode = .auto) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.identityFile = identityFile
        self.extraOptions = extraOptions
        self.strictHostKeys = strictHostKeys
        self.authMode = authMode
    }
}

/// SFTP przez systemowy klient `ssh` (klucze, ssh-agent, known_hosts, keepalive działają jak w Terminalu).
public final class SFTPProvider: FileProvider, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let capabilities: ProviderCapabilities = [.resume, .symlinks, .permissions]
    private let config: SFTPConfig
    private let lock = NSLock()
    private var conn: SFTPConnection?
    private var _home = "/"

    public var homePath: String { lock.withLock { _home } }

    public init(config: SFTPConfig) {
        self.config = config
        self.id = "sftp:\(config.username)@\(config.host):\(config.port)"
        self.displayName = "\(config.host) (SFTP)"
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (SFTPConnection) throws -> T) async throws -> T {
        let c = try lock.withLock { () throws -> SFTPConnection in
            guard let c = conn else { throw FileProviderError.notConnected }
            return c
        }
        return try await withCheckedThrowingContinuation { cont in
            c.queue.async { cont.resume(with: Result { try body(c) }) }
        }
    }

    public func connect() async throws {
        let c = try SFTPConnection(config: config)
        do {
            let home: String = try await withCheckedThrowingContinuation { cont in
                c.queue.async { cont.resume(with: Result { try c.handshake(); return try c.realpath(".") }) }
            }
            lock.withLock { conn = c; _home = home }
        } catch {
            c.shutdown()
            throw error
        }
    }

    public func disconnect() async {
        let c = lock.withLock { () -> SFTPConnection? in defer { conn = nil }; return conn }
        c?.shutdown()
    }

    public func checkConnection() async throws {
        _ = try await perform { try $0.realpath(".") }
    }

    public func setPermissions(_ path: String, mode: UInt16) async throws {
        try await perform { try $0.setPermissions(path, mode: mode) }
    }

    private func item(_ name: String, in dir: String, _ a: SFTPAttrs, conn c: SFTPConnection) -> FileItem {
        let path = PathUtil.join(dir, name)
        var kind = a.kind
        var attrs = a
        if kind == .symlink, let target = try? c.stat(path) {
            attrs = target
            kind = target.kind == .directory ? .directory : .symlink
        }
        return FileItem(
            name: name, path: path, kind: kind,
            size: kind == .directory ? nil : attrs.size,
            modified: attrs.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            permissions: attrs.mode.map { UInt16($0 & 0o7777) }, isHidden: name.hasPrefix("."))
    }

    public func list(_ path: String) async throws -> [FileItem] {
        try await perform { c in
            try c.listDir(path).map { self.item($0.0, in: path, $0.1, conn: c) }
        }
    }

    public func stat(_ path: String) async throws -> FileItem {
        try await perform { c in
            if path == "/" { return FileItem(name: "/", path: "/", kind: .directory) }
            let a = try (try? c.stat(path)) ?? c.stat(path, follow: false)
            return self.item(PathUtil.lastComponent(path), in: PathUtil.parent(path), a, conn: c)
        }
    }

    private final class ReadState: @unchecked Sendable {
        var handle: [UInt8]?
        var offset: Int64
        init(offset: Int64) { self.offset = offset }
    }

    public func read(_ path: String, offset: Int64) -> AsyncThrowingStream<Data, Error> {
        let state = ReadState(offset: offset)
        return AsyncThrowingStream(unfolding: { [self] in
            if Task.isCancelled { await closeRead(state); throw CancellationError() }
            do {
                if state.handle == nil { state.handle = try await perform { try $0.open(path, flags: 0x1) } }
                let h = state.handle!, off = state.offset
                guard let data = try await perform({ try $0.read(h, offset: off, path: path) }) else {
                    await closeRead(state)
                    return nil
                }
                state.offset += Int64(data.count)
                return data
            } catch {
                await closeRead(state)
                throw error
            }
        })
    }

    private func closeRead(_ s: ReadState) async {
        guard let h = s.handle else { return }
        s.handle = nil
        _ = try? await perform { $0.close(h) }
    }

    public func write(_ path: String, from data: AsyncThrowingStream<Data, Error>, options: WriteOptions) async throws {
        if !options.overwrite && options.offset == 0 {
            if (try? await stat(path)) != nil { throw FileProviderError.alreadyExists(path) }
        }
        var f: UInt32 = 0x2 | 0x8
        if options.offset == 0 { f |= 0x10 }
        let flags = f
        let h = try await perform { try $0.open(path, flags: flags) }
        var offset = options.offset
        do {
            for try await chunk in data {
                let off = offset
                try await perform { try $0.write(h, offset: off, data: chunk, path: path) }
                offset += Int64(chunk.count)
            }
        } catch {
            _ = try? await perform { $0.close(h) }
            throw error
        }
        _ = try await perform { $0.close(h) }
    }

    public func makeDirectory(_ path: String) async throws {
        if (try? await stat(path)) != nil { throw FileProviderError.alreadyExists(path) }
        try await perform { try $0.simple(14, path) { $0.u32(0) } }
    }

    public func rename(_ from: String, to: String) async throws {
        if (try? await stat(to)) != nil { throw FileProviderError.alreadyExists(to) }
        try await perform { try $0.rename(from, to: to) }
    }

    public func delete(_ path: String) async throws {
        let a = try await perform { try $0.stat(path, follow: false) }
        if a.kind == .directory {
            for child in try await list(path) { try await delete(child.path) }
            try await perform { try $0.simple(15, path) }
        } else {
            try await perform { try $0.simple(13, path) }
        }
    }
}
