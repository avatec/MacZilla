import Foundation
import Testing
@testable import MacZillaCore

@Suite struct CoreTests {
    @Test func pathUtil() {
        #expect(PathUtil.parent("/a/b") == "/a")
        #expect(PathUtil.parent("/a") == "/")
        #expect(PathUtil.parent("/") == "/")
        #expect(PathUtil.join("/", "x") == "/x")
        #expect(PathUtil.join("/a", "x") == "/a/x")
        #expect(PathUtil.lastComponent("/a/b.txt") == "b.txt")
    }

    @Test func copyMoveDelete() async throws {
        let root = NSTemporaryDirectory() + "mz-\(UUID().uuidString)"
        let p = LocalProvider()
        try await p.makeDirectory(root + "/src/sub")
        try await p.makeDirectory(root + "/dst")
        try "hello".write(toFile: root + "/src/sub/a.txt", atomically: true, encoding: .utf8)

        try await Transfer.copy(from: p, root + "/src", to: p, root + "/dst")
        #expect(try String(contentsOfFile: root + "/dst/src/sub/a.txt", encoding: .utf8) == "hello")

        await #expect(throws: FileProviderError.self) {
            try await Transfer.copy(from: p, root + "/src", to: p, root + "/dst", policy: .fail)
            try await Transfer.copy(from: p, root + "/src/sub/a.txt", to: p, root + "/dst/src/sub", policy: .fail)
        }

        try await p.makeDirectory(root + "/out")
        try await Transfer.move(from: p, root + "/dst/src", to: p, root + "/out")
        let listed = try await p.list(root)
        #expect(Set(listed.map(\.name)) == ["src", "dst", "out"])
        #expect(try await p.list(root + "/dst").isEmpty)
        #expect(try await p.list(root + "/out").map(\.name) == ["src"])

        try await p.delete(root)
        await #expect(throws: FileProviderError.notFound(root)) { _ = try await p.stat(root) }
    }
}
