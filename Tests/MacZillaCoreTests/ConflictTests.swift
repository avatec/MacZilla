import Foundation
import Testing
@testable import MacZillaCore

@Suite struct ConflictTests {
    private func setup() throws -> (LocalProvider, String) {
        let root = NSTemporaryDirectory() + "mzc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/dst", withIntermediateDirectories: true)
        try "new".write(toFile: root + "/src/a.txt", atomically: true, encoding: .utf8)
        try "old".write(toFile: root + "/dst/a.txt", atomically: true, encoding: .utf8)
        return (LocalProvider(), root)
    }

    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    @Test func uniquePathAddsCounterBeforeExtension() async throws {
        let (p, root) = try setup()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(await Transfer.uniquePath(p, dir: root + "/dst", name: "a.txt") == root + "/dst/a 2.txt")
        #expect(await Transfer.uniquePath(p, dir: root + "/dst", name: "b.txt") == root + "/dst/b.txt")
    }

    @Test func copyRenameKeepsBoth() async throws {
        let (p, root) = try setup()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await Transfer.copy(from: p, root + "/src/a.txt", to: p, root + "/dst", policy: .rename)
        #expect(text(root + "/dst/a.txt") == "old")
        #expect(text(root + "/dst/a 2.txt") == "new")
    }

    @Test func copySkipAndOverwrite() async throws {
        let (p, root) = try setup()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await Transfer.copy(from: p, root + "/src/a.txt", to: p, root + "/dst", policy: .skip)
        #expect(text(root + "/dst/a.txt") == "old")
        try await Transfer.copy(from: p, root + "/src/a.txt", to: p, root + "/dst", policy: .overwrite)
        #expect(text(root + "/dst/a.txt") == "new")
    }

    @Test func moveSameProviderHonorsPolicy() async throws {
        let (p, root) = try setup()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await Transfer.move(from: p, root + "/src/a.txt", to: p, root + "/dst", policy: .skip)
        #expect(text(root + "/src/a.txt") == "new")
        await #expect(throws: FileProviderError.self) {
            try await Transfer.move(from: p, root + "/src/a.txt", to: p, root + "/dst", policy: .fail)
        }
        try await Transfer.move(from: p, root + "/src/a.txt", to: p, root + "/dst", policy: .rename)
        #expect(text(root + "/dst/a 2.txt") == "new")
        #expect(text(root + "/src/a.txt") == nil)
    }

    @Test func copyDirectoryRenameCreatesNewFolder() async throws {
        let (p, root) = try setup()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/src/d", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/dst/d", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/src/d/f.txt", atomically: true, encoding: .utf8)
        try await Transfer.copy(from: p, root + "/src/d", to: p, root + "/dst", policy: .rename)
        #expect(text(root + "/dst/d 2/f.txt") == "x")
    }
}
