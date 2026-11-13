import Foundation
import Testing
@testable import MacZillaCore

@Suite struct SiteTests {
    @Test func storeRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "mzsites-\(UUID().uuidString)/sites.json")
        let store = SiteStore(url: url)
        #expect(store.load().isEmpty)
        let s = SiteProfile(name: "Test", proto: .sftp, host: "example.com", username: "me", startPath: "/srv")
        #expect(s.port == 22)
        try store.save([s])
        #expect(store.load() == [s])
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func keychainRoundTrip() throws {
        let kc = KeychainStore(service: "pl.avatec.maczilla.test-\(UUID().uuidString)")
        let id = UUID()
        #expect(kc.password(for: id) == nil)
        try kc.setPassword("sekret", for: id)
        #expect(kc.password(for: id) == "sekret")
        try kc.setPassword("inne", for: id)
        #expect(kc.password(for: id) == "inne")
        kc.deletePassword(for: id)
        #expect(kc.password(for: id) == nil)
    }
}
