import Foundation
import Testing
@testable import MacZillaCore

@Suite struct RemoteEditorTests {
    private final class Box: @unchecked Sendable {
        let lock = NSLock(); var uploads: [String] = []; var errors = 0
        func add(_ s: String) { lock.withLock { uploads.append(s) } }
    }

    @Test func downloadEditUploadCycle() async throws {
        let root = NSTemporaryDirectory() + "mzedit-\(UUID().uuidString)"
        let remoteDir = root + "/remote", cache = root + "/cache"
        try FileManager.default.createDirectory(atPath: remoteDir, withIntermediateDirectories: true)
        try "v1".write(toFile: remoteDir + "/notes.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let provider = LocalProvider()
        let box = Box()
        let editor = RemoteEditor(cacheRoot: URL(fileURLWithPath: cache), interval: .milliseconds(50),
                                  onChange: { s in
            box.add(try String(contentsOf: s.localURL, encoding: .utf8))
            try await Transfer.copy(from: LocalProvider(), s.localURL.path, to: s.provider,
                                    PathUtil.parent(s.remotePath), policy: .overwrite)
        })
        let session = try await editor.download(provider, remoteDir + "/notes.txt")
        #expect(session.name == "notes.txt")
        #expect(try String(contentsOf: session.localURL, encoding: .utf8) == "v1")
        await editor.watch(session)
        #expect(await editor.existingSession(provider: provider, path: remoteDir + "/notes.txt") != nil)

        await editor.poll()
        #expect(box.uploads.isEmpty)

        try "v2 dłuższe".write(to: session.localURL, atomically: true, encoding: .utf8)
        await editor.poll()            // wykrycie zmiany
        #expect(box.uploads.isEmpty)
        await editor.poll()            // stabilna – wysyłka
        #expect(box.uploads == ["v2 dłuższe"])
        #expect(try String(contentsOfFile: remoteDir + "/notes.txt", encoding: .utf8) == "v2 dłuższe")
        await editor.poll()
        #expect(box.uploads.count == 1)

        await editor.stopAll()
        #expect(!FileManager.default.fileExists(atPath: session.localURL.path))
    }

    @Test func directoryCannotBeDownloaded() async throws {
        let editor = RemoteEditor(cacheRoot: URL(fileURLWithPath: NSTemporaryDirectory() + "mzedit-x"), onChange: { _ in })
        await #expect(throws: FileProviderError.self) { _ = try await editor.download(LocalProvider(), NSTemporaryDirectory()) }
    }
}
