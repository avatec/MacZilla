import Foundation

/// Plik pobrany z serwera na czas edycji/podglądu.
public struct RemoteEditSession: Sendable, Identifiable {
    public let id = UUID()
    public let provider: any FileProvider
    public let remotePath: String
    public let localURL: URL
    public var name: String { localURL.lastPathComponent }
}

/// Pobieranie plików zdalnych do lokalnego cache oraz automatyczny zapis zmian z powrotem na serwer.
public actor RemoteEditor {
    private struct Signature: Equatable { var mtime: Date; var size: Int64 }
    private struct Entry { var session: RemoteEditSession; var uploaded: Signature; var pending: Signature? }

    private var entries: [UUID: Entry] = [:]
    private var task: Task<Void, Never>?
    private let interval: Duration
    private let onChange: @Sendable (RemoteEditSession) async throws -> Void
    private let onError: @Sendable (RemoteEditSession, Error) async -> Void
    public nonisolated let cacheRoot: URL

    public init(cacheRoot: URL? = nil, interval: Duration = .seconds(1),
                onChange: @escaping @Sendable (RemoteEditSession) async throws -> Void,
                onError: @escaping @Sendable (RemoteEditSession, Error) async -> Void = { _, _ in }) {
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacZilla/remote", isDirectory: true)
        self.interval = interval
        self.onChange = onChange
        self.onError = onError
    }

    /// Pobiera plik do świeżego katalogu cache. Nazwa pliku jest zachowana (ważne dla rozszerzenia).
    public func download(_ provider: any FileProvider, _ path: String,
                         progress: (@Sendable (Int64) -> Void)? = nil) async throws -> RemoteEditSession {
        let item = try await provider.stat(path)
        guard !item.isDirectory else { throw FileProviderError.unsupported("katalog") }
        let dir = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await Transfer.copy(from: provider, path, to: LocalProvider(), dir.path, policy: .overwrite, progress: progress)
        return RemoteEditSession(provider: provider, remotePath: path,
                                 localURL: dir.appendingPathComponent(PathUtil.lastComponent(path)))
    }

    /// Rejestruje sesję do obserwacji; zmiany w pliku lokalnym są wysyłane na serwer.
    public func watch(_ session: RemoteEditSession) {
        if existingSession(provider: session.provider, path: session.remotePath) != nil {
            try? FileManager.default.removeItem(at: session.localURL.deletingLastPathComponent())
            return
        }
        guard let sig = Self.signature(session.localURL) else { return }
        entries[session.id] = Entry(session: session, uploaded: sig, pending: nil)
        if task == nil { task = Task { [weak self] in await self?.loop() } }
    }

    /// Istniejąca sesja dla danego pliku zdalnego (żeby nie pobierać drugi raz).
    public func existingSession(provider: any FileProvider, path: String) -> RemoteEditSession? {
        entries.values.first { $0.session.provider.id == provider.id && $0.session.remotePath == path }?.session
    }

    public var activeSessions: [RemoteEditSession] { entries.values.map(\.session) }

    public func stop(_ id: UUID) {
        if let e = entries.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: e.session.localURL.deletingLastPathComponent())
        }
        if entries.isEmpty { task?.cancel(); task = nil }
    }

    public func stopAll(removeFiles: Bool = true) {
        task?.cancel(); task = nil
        if removeFiles { for e in entries.values { try? FileManager.default.removeItem(at: e.session.localURL.deletingLastPathComponent()) } }
        entries.removeAll()
    }

    /// Jeden przebieg obserwacji (publiczny dla testów).
    public func poll() async {
        for (id, var e) in entries {
            guard let sig = Self.signature(e.session.localURL) else { continue }
            if sig == e.uploaded { e.pending = nil; entries[id] = e; continue }
            // Zmiana jest wysyłana dopiero, gdy plik był stabilny przez cały odstęp (edytor kończy zapis).
            if e.pending != sig { e.pending = sig; entries[id] = e; continue }
            do {
                try await onChange(e.session)
                e.uploaded = sig
            } catch {
                await onError(e.session, error)
                e.uploaded = sig
            }
            e.pending = nil
            entries[id] = e
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            await poll()
        }
    }

    private static func signature(_ url: URL) -> Signature? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date, let s = a[.size] as? NSNumber else { return nil }
        return Signature(mtime: m, size: s.int64Value)
    }
}
