import Foundation

public struct LocalProvider: FileProvider {
    public let id = "local"
    public let displayName = "Ten Mac"
    public let capabilities: ProviderCapabilities = [.resume, .symlinks, .permissions, .trash]
    public var homePath: String { NSHomeDirectory() }

    public init() {}

    public func connect() async throws {}
    public func disconnect() async {}
    public func checkConnection() async throws {}

    public func list(_ path: String) async throws -> [FileItem] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: path) } catch {
            throw mapError(error, path)
        }
        return names.compactMap { try? item(at: PathUtil.join(path, $0)) }
    }

    public func stat(_ path: String) async throws -> FileItem {
        try item(at: path)
    }

    private func item(at path: String) throws -> FileItem {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: path) } catch {
            throw mapError(error, path)
        }
        var kind: FileKind
        switch attrs[.type] as? FileAttributeType {
        case .typeDirectory: kind = .directory
        case .typeRegular: kind = .file
        case .typeSymbolicLink:
            kind = .symlink
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                kind = .directory
            }
        default: kind = .other
        }
        let name = PathUtil.lastComponent(path)
        return FileItem(
            name: name, path: path, kind: kind,
            size: kind == .directory ? nil : (attrs[.size] as? NSNumber)?.int64Value,
            modified: attrs[.modificationDate] as? Date,
            permissions: (attrs[.posixPermissions] as? NSNumber)?.uint16Value,
            isHidden: name.hasPrefix(".")
        )
    }

    public func read(_ path: String, offset: Int64) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offset))
                    while !Task.isCancelled, let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapError(error, path))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func write(_ path: String, from data: AsyncThrowingStream<Data, Error>, options: WriteOptions) async throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path)
        if exists && !options.overwrite && options.offset == 0 { throw FileProviderError.alreadyExists(path) }
        if !exists {
            guard fm.createFile(atPath: path, contents: nil) else {
                throw FileProviderError.io("Nie można utworzyć \(path)")
            }
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        if options.offset == 0 { try handle.truncate(atOffset: 0) } else { try handle.seek(toOffset: UInt64(options.offset)) }
        for try await chunk in data { try handle.write(contentsOf: chunk) }
    }

    public func makeDirectory(_ path: String) async throws {
        if FileManager.default.fileExists(atPath: path) { throw FileProviderError.alreadyExists(path) }
        do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        catch { throw mapError(error, path) }
    }

    public func rename(_ from: String, to: String) async throws {
        if FileManager.default.fileExists(atPath: to) { throw FileProviderError.alreadyExists(to) }
        do { try FileManager.default.moveItem(atPath: from, toPath: to) } catch { throw mapError(error, from) }
    }

    public func delete(_ path: String) async throws {
        do { try FileManager.default.removeItem(atPath: path) } catch { throw mapError(error, path) }
    }

    public func setPermissions(_ path: String, mode: UInt16) async throws {
        do { try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path) }
        catch { throw mapError(error, path) }
    }
}

func mapError(_ error: Error, _ path: String) -> FileProviderError {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError {
        return .notFound(path)
    }
    return .io(error.localizedDescription)
}
