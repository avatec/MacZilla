import Foundation

public enum ConflictPolicy: Sendable {
    case overwrite, overwriteIfNewer, skip, fail
    /// Zachowaj oba: cel dostaje nową nazwę „nazwa 2.ext”.
    case rename
}

/// Operacje między dowolnymi dwoma providerami (strumień read -> write).
public enum Transfer {
    /// Łączny rozmiar plików w drzewie (nil, gdy drzewo jest zbyt duże, by liczyć je z góry).
    public static func totalSize(of provider: any FileProvider, _ path: String, limit: Int = 5000) async -> Int64? {
        var budget = limit
        func walk(_ p: String) async -> Int64? {
            guard budget > 0, let item = try? await provider.stat(p) else { return nil }
            budget -= 1
            guard item.isDirectory else { return item.size ?? 0 }
            guard let children = try? await provider.list(p) else { return nil }
            var sum: Int64 = 0
            for c in children {
                if c.isDirectory { guard let s = await walk(c.path) else { return nil }; sum += s }
                else { budget -= 1; if budget <= 0 { return nil }; sum += c.size ?? 0 }
            }
            return sum
        }
        return await walk(path)
    }

    public static func exists(_ provider: any FileProvider, _ path: String) async -> Bool {
        do { _ = try await provider.stat(path); return true } catch { return false }
    }

    /// Pierwsza wolna nazwa w katalogu: „nazwa”, „nazwa 2”, „nazwa 3”… (rozszerzenie zachowane).
    public static func uniquePath(_ provider: any FileProvider, dir: String, name: String) async -> String {
        let first = PathUtil.join(dir, name)
        guard await exists(provider, first) else { return first }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = PathUtil.join(dir, ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !(await exists(provider, candidate)) { return candidate }
            n += 1
        }
    }

    public static func copy(
        from src: any FileProvider, _ srcPath: String,
        to dst: any FileProvider, _ dstDir: String,
        policy: ConflictPolicy = .fail,
        progress: (@Sendable (Int64) -> Void)? = nil,
        destinationSnapshot: [String: FileItem]? = nil
    ) async throws {
        let item = try await src.stat(srcPath)
        try await copy(item: item, from: src, to: dst, dstDir: dstDir, policy: policy,
                       destinationItems: destinationSnapshot, progress: progress)
    }

    private static func copy(
        item: FileItem,
        from src: any FileProvider,
        to dst: any FileProvider,
        dstDir: String,
        policy: ConflictPolicy,
        destinationItems: [String: FileItem]?,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        var target = PathUtil.join(dstDir, item.name)
        if item.isDirectory {
            let existing = destinationItems?[item.name]
            if policy == .rename, existing != nil {
                target = await uniquePath(dst, dir: dstDir, name: item.name)
            }
            var childItems: [String: FileItem]
            if let existing, existing.isDirectory, target == existing.path {
                childItems = Self.index(try await dst.list(target))
            } else {
                do {
                    try await dst.makeDirectory(target)
                    childItems = [:]
                } catch FileProviderError.alreadyExists {
                    childItems = Self.index(try await dst.list(target))
                }
            }
            for child in try await src.list(item.path) {
                try await copy(item: child, from: src, to: dst, dstDir: target, policy: policy,
                               destinationItems: childItems, progress: progress)
            }
            return
        }
        var destinationItem = destinationItems?[item.name]
        var exists = destinationItem != nil
        if destinationItems == nil, policy != .overwrite {
            do {
                destinationItem = try await dst.stat(target)
                exists = true
            } catch FileProviderError.notFound {
                exists = false
            }
        }
        if exists {
            switch policy {
            case .skip: return
            case .fail: throw FileProviderError.alreadyExists(target)
            case .overwrite: break
            case .overwriteIfNewer:
                // Brak którejkolwiek daty nie pozwala potwierdzić, że źródło jest nowsze.
                guard let sourceDate = item.modified,
                      let destinationDate = destinationItem?.modified,
                      sourceDate > destinationDate else { return }
            case .rename: target = await uniquePath(dst, dir: dstDir, name: item.name)
            }
        }
        let stream = src.read(item.path, offset: 0)
        let counted = AsyncThrowingStream<Data, Error> { cont in
            let t = Task {
                do {
                    for try await chunk in stream {
                        await BandwidthLimiter.shared.throttle(chunk.count)
                        progress?(Int64(chunk.count))
                        cont.yield(chunk)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
        try await dst.write(target, from: counted, options: WriteOptions(overwrite: true))
    }

    private static func index(_ items: [FileItem]) -> [String: FileItem] {
        Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static func move(
        from src: any FileProvider, _ srcPath: String,
        to dst: any FileProvider, _ dstDir: String,
        policy: ConflictPolicy = .fail,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        if src.id == dst.id {
            let name = PathUtil.lastComponent(srcPath)
            var target = PathUtil.join(dstDir, name)
            if target == srcPath { return }
            if await exists(dst, target) {
                switch policy {
                case .skip: return
                case .fail: throw FileProviderError.alreadyExists(target)
                case .overwrite: try await dst.delete(target)
                case .overwriteIfNewer:
                    let sourceItem = try await src.stat(srcPath)
                    let destinationItem = try await dst.stat(target)
                    guard let sourceDate = sourceItem.modified,
                          let destinationDate = destinationItem.modified,
                          sourceDate > destinationDate else { return }
                    try await dst.delete(target)
                case .rename: target = await uniquePath(dst, dir: dstDir, name: name)
                }
            }
            try await src.rename(srcPath, to: target)
        } else {
            if policy == .skip, await exists(dst, PathUtil.join(dstDir, PathUtil.lastComponent(srcPath))) { return }
            try await copy(from: src, srcPath, to: dst, dstDir, policy: policy, progress: progress)
            // Polityka .overwriteIfNewer może pominąć część plików, więc przeniesienie
            // nie może wtedy usuwać źródła.
            if policy != .overwriteIfNewer { try await src.delete(srcPath) }
        }
    }
}
