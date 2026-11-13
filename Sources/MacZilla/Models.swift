import SwiftUI
import AppKit
import MacZillaCore

enum PanelSide { case left, right }

enum RemoteConnectionStatus { case connected, disconnected }

@MainActor @Observable
final class PanelModel {
    var provider: any FileProvider
    var path: String
    var items: [FileItem] = []
    var selection: Set<FileItem.ID> = []
    var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)]
    var showHidden = false { didSet { Task { await reload() } } }
    var error: String?
    var isLoading = false
    var remoteConnectionStatus: RemoteConnectionStatus?
    var connectionIssue: String?
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var watchedPath: String?

    private func updateWatcher() {
        guard provider.id == "local" else { watcher = nil; watchedPath = nil; return }
        guard watchedPath != path else { return }
        watchedPath = path
        watcher = DirectoryWatcher(path: path) { [weak self] in
            Task { @MainActor in await self?.reload() }
        }
    }

    init(provider: any FileProvider) {
        self.provider = provider
        self.path = provider.homePath
    }

    func monitorConnection() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            let current = provider
            guard current.id != "local" else {
                remoteConnectionStatus = nil
                connectionIssue = nil
                continue
            }
            let wasDisconnected = remoteConnectionStatus == .disconnected
            do {
                try await current.checkConnection()
                guard provider.id == current.id else { continue }
                remoteConnectionStatus = .connected
                connectionIssue = nil
                if wasDisconnected { await reload() }
            } catch {
                guard provider.id == current.id else { continue }
                remoteConnectionStatus = .disconnected
                connectionIssue = error.localizedDescription
            }
        }
    }

    var visibleItems: [FileItem] {
        let filtered = showHidden ? items : items.filter { !$0.isHidden }
        let sorted = filtered.sorted(using: sortOrder)
        // Katalogi zawsze na górze
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    /// Wirtualny wiersz „..” (katalog nadrzędny); nie należy do `items`, więc nie bierze udziału w operacjach na plikach.
    var parentItem: FileItem? {
        let parent = PathUtil.parent(path)
        guard parent != path, !path.isEmpty else { return nil }
        return FileItem(name: "..", path: parent, kind: .directory)
    }

    var tableItems: [FileItem] { (parentItem.map { [$0] } ?? []) + visibleItems }

    func tableItem(id: FileItem.ID) -> FileItem? { tableItems.first { $0.id == id } }

    var selectedItems: [FileItem] { items.filter { selection.contains($0.id) } }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await provider.list(path)
            error = nil
            selection = selection.filter { id in items.contains { $0.id == id } }
            updateWatcher()
        } catch {
            items = []
            self.error = error.localizedDescription
        }
    }

    func navigate(to newPath: String, recordHistory: Bool = true) async {
        let old = path
        if recordHistory, newPath != old { backStack.append(old); forwardStack.removeAll() }
        path = newPath
        selection = []
        await reload()
        if error != nil, recordHistory, newPath != old {
            path = old
            backStack.removeLast()
            let msg = error
            await reload()
            error = msg
        }
    }

    func open(_ item: FileItem) async {
        if item.isDirectory { await navigate(to: item.path) }
        else if provider.id == "local" { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
    }

    func goUp() async { await navigate(to: PathUtil.parent(path)) }

    func connect(_ newProvider: any FileProvider) async throws {
        try await newProvider.connect()
        let old = provider
        provider = newProvider
        remoteConnectionStatus = newProvider.id == "local" ? nil : .connected
        connectionIssue = nil
        backStack.removeAll(); forwardStack.removeAll()
        watchedPath = nil; watcher = nil
        path = newProvider.homePath
        selection = []
        await reload()
        if old.id != newProvider.id { await old.disconnect() }
    }

    func useLocal() async {
        let old = provider
        guard old.id != "local" else { return }
        provider = LocalProvider()
        remoteConnectionStatus = nil
        connectionIssue = nil
        backStack.removeAll(); forwardStack.removeAll()
        path = provider.homePath
        selection = []
        await reload()
        await old.disconnect()
    }

    func goBack() async {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(path)
        await navigate(to: prev, recordHistory: false)
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        await navigate(to: next, recordHistory: false)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    var quick = QuickSearch()
    var quickText = ""

    func typeAhead(_ text: String) {
        quick.append(text)
        let list = visibleItems
        let current = list.firstIndex { selection.contains($0.id) } ?? -1
        // Ta sama litera powtórzona: przejdź do kolejnego dopasowania.
        let start = quick.buffer.count == 1 ? current + 1 : max(current, 0)
        if let i = quick.match(in: list.map(\.name), from: start) { selection = [list[i].id] }
        quickText = quick.buffer
        let snapshot = quick.buffer
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if quick.buffer == snapshot, !quick.isActive(now: Date()) { quickText = ""; quick.reset() }
        }
    }

    func cancelQuickSearch() { quick.reset(); quickText = "" }

    func select(matching pattern: String, add: Bool) {
        let ids = Set(visibleItems.filter { QuickSearch.glob(pattern, matches: $0.name) }.map(\.id))
        selection = add ? selection.union(ids) : selection.subtracting(ids)
    }
}

@MainActor @Observable
final class AppState {
    let left = PanelModel(provider: LocalProvider())
    let right = PanelModel(provider: LocalProvider())
    var active: PanelSide = .left
    var alert: String?
    var busy = false
    var showNewFolder = false
    let siteStore = SiteStore()
    let keychain = KeychainStore()

    let settings = AppSettings.shared

    @ObservationIgnored lazy var remoteEditor = RemoteEditor(
        onChange: { [queue, settings] session in
            guard await settings.autoUpload else { return }
            await queue.enqueue(title: Loc.tr("Zapis na serwer: %@", session.name)) { progress in
                try await Transfer.copy(from: LocalProvider(), session.localURL.path, to: session.provider,
                                        PathUtil.parent(session.remotePath), policy: .overwrite, progress: progress)
            }
        })

    func applySettings() async {
        settings.applyAppearance()
        await queue.setMaxConcurrent(settings.maxConcurrent)
        await BandwidthLimiter.shared.setLimit(Int64(settings.bandwidthKBps) * 1024)
    }

    /// Dwuklik / Enter: katalog → wejście, plik lokalny → aplikacja systemowa, plik zdalny → edycja.
    func open(_ item: FileItem, in panel: PanelModel) async {
        if item.isDirectory { await panel.open(item) }
        else if panel.provider.id == "local" { await panel.open(item) }
        else { await edit(item, in: panel) }
    }

    /// Pobiera plik zdalny do cache (z paskiem zajętości) i zwraca ścieżkę lokalną.
    private func localCopy(of item: FileItem, in panel: PanelModel, watch: Bool) async -> URL? {
        if panel.provider.id == "local" { return URL(fileURLWithPath: item.path) }
        if let s = await remoteEditor.existingSession(provider: panel.provider, path: item.path) { return s.localURL }
        busy = true
        defer { busy = false }
        do {
            let session = try await remoteEditor.download(panel.provider, item.path)
            if watch { await remoteEditor.watch(session) }
            return session.localURL
        } catch {
            alert = error.localizedDescription
            return nil
        }
    }

    func edit() async {
        guard let item = activePanel.selectedItems.first, !item.isDirectory else { return }
        await edit(item, in: activePanel)
    }

    func edit(_ item: FileItem, in panel: PanelModel) async {
        guard !item.isDirectory, let url = await localCopy(of: item, in: panel, watch: true) else { return }
        settings.openInEditor(url)
    }

    func quickLook() {
        guard let item = activePanel.selectedItems.first, !item.isDirectory else { return }
        let panel = activePanel
        Task {
            guard let url = await localCopy(of: item, in: panel, watch: false) else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            p.arguments = ["-p", url.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    var activePanel: PanelModel { active == .left ? left : right }
    var otherPanel: PanelModel { active == .left ? right : left }

    let queue = TransferQueue(maxConcurrent: 2)
    var jobs: [TransferJob] = []
    private var started = false

    func start() async {
        guard !started else { return }
        Notifier.requestAuthorization()
        started = true
        left.showHidden = settings.showHiddenByDefault
        right.showHidden = settings.showHiddenByDefault
        await applySettings()
        try? FileManager.default.removeItem(at: remoteEditor.cacheRoot)
        let kc = keychain
        Task.detached { _ = kc.password(for: UUID()) } // jednorazowe wczytanie sejfu haseł na sesję
        right.path = NSHomeDirectory() + "/Downloads"
        await left.reload()
        await right.reload()
        var finishedSeen = Set<UUID>()
        for await snap in await queue.updates() {
            jobs = snap
            queuePaused = await queue.isPaused
            let active = snap.filter { !$0.state.isFinished }.count
            NSApp.dockTile.badgeLabel = active > 0 ? String(active) : nil
            var newlyFinished = false
            for job in snap where !job.state.isFinished { finishedSeen.remove(job.id) }
            for job in snap where job.state.isFinished && finishedSeen.insert(job.id).inserted {
                newlyFinished = true
                if case .failed(let msg) = job.state { alert = "\(job.title): \(msg)" }
            }
            if newlyFinished {
                await left.reload()
                await right.reload()
                if active == 0, settings.notifications { Notifier.transfersFinished(snap) }
            }
        }
    }

    var queuePaused = false
    func refreshQueueState() async { queuePaused = await queue.isPaused }

    func copySelected() async { await transfer(move: false) }
    func moveSelected() async { await transfer(move: true) }

    struct ConflictPrompt {
        let name: String
        let remaining: Int
        let allowsOverwriteIfNewer: Bool
        let resume: CheckedContinuation<ConflictAnswer, Never>
    }
    enum ConflictAnswer { case overwrite, overwriteIfNewer, skip, keepBoth, cancel }

    var conflict: ConflictPrompt?

    func answerConflict(_ answer: ConflictAnswer) {
        let c = conflict
        conflict = nil
        c?.resume.resume(returning: answer)
    }

    private func askConflict(name: String, remaining: Int, allowsOverwriteIfNewer: Bool) async -> ConflictAnswer {
        await withCheckedContinuation { cont in
            conflict = ConflictPrompt(name: name, remaining: remaining,
                                      allowsOverwriteIfNewer: allowsOverwriteIfNewer, resume: cont)
        }
    }

    private func transfer(move: Bool) async {
        guard conflict == nil else { return }
        conflictApplyToAll = false
        let src = activePanel.provider, dst = otherPanel.provider, dstPath = otherPanel.path
        let items = activePanel.selectedItems
        let allowsOverwriteIfNewer = !move && src.id == "local" && dst.id != "local"
        let destinationSnapshot: [String: FileItem]?
        if allowsOverwriteIfNewer, let listed = try? await dst.list(dstPath) {
            destinationSnapshot = Dictionary(listed.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            destinationSnapshot = nil
        }
        var allPolicy: ConflictPolicy?
        for (index, item) in items.enumerated() {
            let path = item.path
            var policy = ConflictPolicy.fail
            let destinationExists: Bool
            if let destinationSnapshot {
                destinationExists = destinationSnapshot[item.name] != nil
            } else {
                destinationExists = await Transfer.exists(dst, PathUtil.join(dstPath, item.name))
            }
            if destinationExists, !(src.id == dst.id && dstPath == PathUtil.parent(path)) {
                if let all = allPolicy {
                    policy = all
                } else {
                    let remaining = items.count - index - 1
                    switch await askConflict(name: item.name, remaining: remaining,
                                             allowsOverwriteIfNewer: allowsOverwriteIfNewer) {
                    case .cancel: return
                    case .overwrite: policy = .overwrite
                    case .overwriteIfNewer: policy = .overwriteIfNewer
                    case .skip: policy = .skip
                    case .keepBoth: policy = .rename
                    }
                    if remaining > 0, conflictApplyToAll { allPolicy = policy }
                }
            }
            if policy == .skip { continue }
            let chosen = policy
            await queue.enqueue(
                title: Loc.tr(move ? "Przenoszenie: %@" : "Kopiowanie: %@", item.name),
                estimate: { await Transfer.totalSize(of: src, path) }
            ) { progress in
                // Po nieudanej próbie w celu może leżeć część pliku – kolejna próba nadpisuje ją.
                let effective: ConflictPolicy = TransferContext.attempt > 0 &&
                    (chosen == .fail || chosen == .overwriteIfNewer) ? .overwrite : chosen
                if move {
                    try await Transfer.move(from: src, path, to: dst, dstPath, policy: effective, progress: progress)
                } else {
                    try await Transfer.copy(from: src, path, to: dst, dstPath, policy: effective,
                                            progress: progress, destinationSnapshot: destinationSnapshot)
                }
            }
        }
    }

    var conflictApplyToAll = false

    func deleteSelected() async {
        let panel = activePanel
        busy = true
        defer { busy = false }
        for item in panel.selectedItems {
            if panel.provider.id == "local" {
                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil) }
                catch { alert = error.localizedDescription; break }
            } else {
                do { try await panel.provider.delete(item.path) } catch { alert = error.localizedDescription; break }
            }
        }
        await panel.reload()
        if panel !== otherPanel { await otherPanel.reload() }
    }

    func makeDirectory(named name: String) async {
        let panel = activePanel
        do { try await panel.provider.makeDirectory(PathUtil.join(panel.path, name)) }
        catch { alert = error.localizedDescription }
        await panel.reload()
        if panel.provider.id == otherPanel.provider.id, panel.path == otherPanel.path { await otherPanel.reload() }
    }

    func rename(_ item: FileItem, to name: String) async {
        let panel = activePanel
        do { try await panel.provider.rename(item.path, to: PathUtil.join(PathUtil.parent(item.path), name)) }
        catch { alert = error.localizedDescription }
        await panel.reload()
    }
}
