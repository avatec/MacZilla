import Foundation

public final class FTPProvider: FileProvider, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let capabilities: ProviderCapabilities = [.resume, .permissions]
    private let config: FTPConfig
    private let lock = NSLock()
    private var control: FTPSession?
    private var uploadControl: FTPSession?
    private let uploadGate = FTPWriteGate()
    private var _home = "/"

    public var homePath: String { lock.withLock { _home } }

    public init(config: FTPConfig) {
        self.config = config
        let tls = config.security == .none ? "" : "+tls"
        self.id = "ftp\(tls):\(config.username)@\(config.host):\(config.port)"
        self.displayName = "\(config.host) (\(config.security == .none ? "FTP" : "FTPS"))"
    }

    private func session() throws -> FTPSession {
        try lock.withLock {
            guard let c = control else { throw FileProviderError.notConnected }
            return c
        }
    }

    public func connect() async throws {
        let s = FTPSession(config: config)
        try await s.open()
        let home = await s.home
        lock.withLock { control = s; _home = home }
    }

    public func disconnect() async {
        let sessions = lock.withLock { () -> (FTPSession?, FTPSession?) in
            defer { control = nil; uploadControl = nil }
            return (control, uploadControl)
        }
        await sessions.0?.quit()
        if sessions.1 !== sessions.0 { await sessions.1?.quit() }
    }

    public func checkConnection() async throws { try await session().checkConnection() }

    public func setPermissions(_ path: String, mode: UInt16) async throws {
        try await session().setPermissions(path, mode: mode)
    }

    public func list(_ path: String) async throws -> [FileItem] {
        try await session().list(path)
    }

    public func stat(_ path: String) async throws -> FileItem {
        if path == "/" { return FileItem(name: "/", path: "/", kind: .directory) }
        let parent = PathUtil.parent(path), name = PathUtil.lastComponent(path)
        guard let item = try await list(parent).first(where: { $0.name == name }) else {
            throw FileProviderError.notFound(path)
        }
        return item
    }

    // Każdy transfer używa własnego połączenia, więc nie blokuje przeglądania ani innych transferów.
    public func read(_ path: String, offset: Int64) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let s = FTPSession(config: config)
                do {
                    try await s.open()
                    try await s.retrieve(path, offset: offset) { continuation.yield($0) }
                    await s.quit()
                    continuation.finish()
                } catch {
                    await s.quit()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func write(_ path: String, from data: AsyncThrowingStream<Data, Error>, options: WriteOptions) async throws {
        await uploadGate.acquire()
        var s: FTPSession?
        do {
            if let cached = lock.withLock({ uploadControl }) {
                s = cached
            } else {
                let connected = FTPSession(config: config)
                try await connected.open()
                lock.withLock { uploadControl = connected }
                s = connected
            }
            try await s!.store(path, from: data, offset: options.offset)
            await uploadGate.release()
        } catch {
            if let s {
                await s.quit()
                lock.withLock { if uploadControl === s { uploadControl = nil } }
            }
            await uploadGate.release()
            throw error
        }
    }

    public func makeDirectory(_ path: String) async throws {
        do { try await session().simple("MKD \(path)", path: path) }
        catch FileProviderError.alreadyExists(let p) { throw FileProviderError.alreadyExists(p) }
        catch {
            // Wiele serwerów odpowiada 550 zarówno przy istniejącym katalogu, jak i braku uprawnień.
            if let existing = try? await stat(path), existing.isDirectory { throw FileProviderError.alreadyExists(path) }
            throw error
        }
    }

    public func rename(_ from: String, to: String) async throws {
        try await session().rename(from, to: to)
    }

    public func delete(_ path: String) async throws {
        let item = try await stat(path)
        if item.isDirectory {
            for child in try await list(path) { try await delete(child.path) }
            try await session().simple("RMD \(path)", path: path)
        } else {
            try await session().simple("DELE \(path)", path: path)
        }
    }
}

/// Jeden kanał FTP może obsługiwać tylko jedną komendę STOR naraz.
private actor FTPWriteGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}
